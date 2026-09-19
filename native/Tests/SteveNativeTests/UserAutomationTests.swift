import XCTest
@testable import SteveNative

final class UserAutomationTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-09-19T12:00:00Z") }
    private func provenance(_ id: String = UUID().uuidString, statement: String = "Please remember this preference or schedule this task.", explicit: Bool = true) -> ExplicitUserProvenance {
        .init(source: .pairedMessage, sourceID: id, statement: statement, explicitlyRequested: explicit, recordedAt: now)
    }
    private func setup() throws -> (SteveUserAutomationStore, URL, ScheduleAuthorization) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("automation.sqlite3")
        let store = try SteveUserAutomationStore(databaseURL: url)
        let boundary = try ScheduleAuthorization(chatGUID: "paired-chat", senderHandle: "User@example.test", workspace: root.path, permission: ":workspace-write")
        return (store, url, boundary)
    }
    private func create(_ store: SteveUserAutomationStore, _ authorization: ScheduleAuthorization, rule: UserScheduleRule? = nil, kind: UserScheduleKind = .task, requestID: String = UUID().uuidString) async throws -> UserSchedule {
        try await store.createSchedule(requestID: requestID, name: "Daily summary", prompt: "Summarize the workspace changes.", kind: kind, rule: rule ?? .interval(seconds: 600, firstRun: now), timeZone: "America/New_York", authorization: authorization, provenance: provenance(requestID), now: now)
    }

    func testExplicitPreferencesPersistUpdateAndForgetTheirValues() async throws {
        let (store, url, _) = try setup()
        let first = try await store.savePreference(key: "Response Style", value: "Use concise paragraphs.", provenance: provenance("save"), now: now)
        XCTAssertEqual(first.key, "response style")
        let reopened = try SteveUserAutomationStore(databaseURL: url)
        let saved = try await reopened.preference(key: "response style")
        XCTAssertEqual(saved, first)
        let update = try await reopened.savePreference(key: first.key, value: "Use detailed explanations.", provenance: provenance("update"), now: now.addingTimeInterval(1))
        XCTAssertEqual(update.createdAt, first.createdAt); XCTAssertEqual(update.provenance.sourceID, "update")
        let forgotten = try await reopened.forgetPreference(key: first.key, provenance: provenance("forget", statement: "Forget my response style preference."))
        let remaining = try await store.preferences()
        XCTAssertTrue(forgotten); XCTAssertTrue(remaining.isEmpty)
    }

    func testInferredPreferencesAndCredentialsAreRejectedWithoutPersistence() async throws {
        let (store, _, _) = try setup()
        do { _ = try await store.savePreference(key: "language", value: "English", provenance: provenance(explicit: false)); XCTFail("Inferred preference accepted") } catch {}
        for (key, value, statement) in [
            ("password", "hunter2", "Remember my password."),
            ("note", ["sk", "proj", "abcdefghijklmnopqrstuvwxyz"].joined(separator: "-"), "Remember this note."),
            ("note", "My password is hunter2", "Remember this note."),
            ("note", "123456", "Remember this code."),
            ("style", "Concise", "My api_key=x; remember concise answers.")
        ] {
            do { _ = try await store.savePreference(key: key, value: value, provenance: provenance(statement: statement)); XCTFail("Credential accepted") } catch {}
        }
        let values = try await store.preferences(); XCTAssertTrue(values.isEmpty)
    }

    func testCreationRequestIsIdempotentAndConflictingReuseIsRejected() async throws {
        let (store, _, authorization) = try setup()
        let first = try await create(store, authorization, requestID: "same-user-message")
        let second = try await create(store, authorization, requestID: "same-user-message")
        XCTAssertEqual(first, second)
        do { _ = try await create(store, authorization, kind: .reminder, requestID: "same-user-message"); XCTFail("Conflicting create request accepted") } catch {}
        let all = try await store.schedules(); XCTAssertEqual(all.count, 1)
    }

    func testDSTSpringGapUsesFirstValidTimeAndFallOverlapOnlyRunsOnce() throws {
        let spring = UserScheduleRule.calendar(hour: 2, minute: 30, weekdays: [])
        let next = try spring.firstOccurrence(now: date("2026-03-07T12:00:00Z"), timeZone: "America/New_York")
        XCTAssertEqual(next, date("2026-03-08T07:00:00Z"))
        let fall = UserScheduleRule.calendar(hour: 1, minute: 30, weekdays: [])
        let first = try fall.firstOccurrence(now: date("2026-10-31T12:00:00Z"), timeZone: "America/New_York")
        XCTAssertEqual(first, date("2026-11-01T05:30:00Z"))
        let duringSecondHour = try fall.coalescedOccurrence(next: first, now: date("2026-11-01T06:15:00Z"), timeZone: "America/New_York")
        XCTAssertEqual(duringSecondHour.due, first)
        XCTAssertEqual(duringSecondHour.next, date("2026-11-02T06:30:00Z"))
    }

    func testWeekdayRuleAndCalendarDowntimeCoalesce() throws {
        let rule = UserScheduleRule.calendar(hour: 9, minute: 0, weekdays: [1, 2, 3, 4, 5])
        let next = try rule.firstOccurrence(now: date("2026-09-18T22:00:00Z"), timeZone: "America/New_York")
        XCTAssertEqual(next, date("2026-09-21T13:00:00Z"))
        let missed = try rule.coalescedOccurrence(next: next, now: date("2026-10-02T14:00:00Z"), timeZone: "America/New_York")
        XCTAssertEqual(missed.due, date("2026-10-02T13:00:00Z"))
        XCTAssertEqual(missed.next, date("2026-10-05T13:00:00Z"))
        XCTAssertThrowsError(try rule.validate(timeZone: "Imaginary/Timezone"))
    }

    func testIntervalCoalescesRestartWithoutBacklogAndEnqueueIsNotSuccess() async throws {
        let (store, url, authorization) = try setup()
        let schedule = try await create(store, authorization)
        let reopened = try SteveUserAutomationStore(databaseURL: url)
        let later = now.addingTimeInterval(6030)
        let claimed = try await reopened.claimDue(now: later, authorization: authorization, dispatchEpoch: "new-process")
        XCTAssertEqual(claimed.count, 1); XCTAssertEqual(claimed[0].scheduledAt, now.addingTimeInterval(6000))
        let updated = try await reopened.schedule(id: schedule.id)
        XCTAssertEqual(updated?.nextRunAt, now.addingTimeInterval(6600))
        do { try await reopened.recordOutcome(id: claimed[0].id, state: .succeeded, detail: "Only claimed", now: later); XCTFail("Claim was marked successful") } catch {}
        try await reopened.markEnqueued(id: claimed[0].id, downstreamID: "inbox:" + claimed[0].id)
        try await reopened.markEnqueued(id: claimed[0].id, downstreamID: "inbox:" + claimed[0].id)
        let enqueued = try await reopened.run(id: claimed[0].id)
        XCTAssertEqual(enqueued?.state, .enqueued); XCTAssertNil(enqueued?.finishedAt)
        let overlapping = try await reopened.claimDue(now: later.addingTimeInterval(1000), authorization: authorization, dispatchEpoch: "new-process")
        XCTAssertTrue(overlapping.isEmpty)
        try await reopened.recordOutcome(id: claimed[0].id, state: .succeeded, detail: "Gateway verified task completed", now: later)
        try await reopened.recordOutcome(id: claimed[0].id, state: .succeeded, detail: "Duplicate completion", now: later)
        let future = try await reopened.claimDue(now: later.addingTimeInterval(1000), authorization: authorization, dispatchEpoch: "new-process")
        XCTAssertEqual(future.count, 1)
    }

    func testConcurrentConnectionsCannotClaimSameOccurrenceTwice() async throws {
        let (store, url, authorization) = try setup()
        _ = try await create(store, authorization)
        let other = try SteveUserAutomationStore(databaseURL: url)
        async let left = store.claimDue(now: now, authorization: authorization, dispatchEpoch: "epoch")
        async let right = other.claimDue(now: now, authorization: authorization, dispatchEpoch: "epoch")
        let results = try await (left, right)
        XCTAssertEqual(results.0.count + results.1.count, 1)
    }

    func testAmbiguousClaimAfterCrashIsHeldAndNeverReplayed() async throws {
        let (store, url, authorization) = try setup()
        let schedule = try await create(store, authorization)
        let claimed = try await store.claimDue(now: now, authorization: authorization, dispatchEpoch: "old")
        let reopened = try SteveUserAutomationStore(databaseURL: url)
        try await reopened.recoverInterruptedClaims(now: now.addingTimeInterval(1))
        let old = try await reopened.run(id: claimed[0].id)
        XCTAssertEqual(old?.state, .uncertain)
        let afterRestart = try await reopened.claimDue(now: now.addingTimeInterval(6000), authorization: authorization, dispatchEpoch: "new")
        XCTAssertTrue(afterRestart.isEmpty)
        try await reopened.resolveUncertainRun(id: claimed[0].id, state: .cancelled, provenance: provenance("resolve", statement: "The interrupted action did not complete; cancel that run."))
        let next = try await reopened.claimDue(now: now.addingTimeInterval(6000), authorization: authorization, dispatchEpoch: "new")
        XCTAssertEqual(next.count, 1); XCTAssertNotEqual(next[0].scheduledAt, claimed[0].scheduledAt)
        let history = try await reopened.runs(scheduleID: schedule.id); XCTAssertEqual(history.count, 2)
    }

    func testBoundaryChangeBlocksScheduleAndStaleEpochCannotValidateClaim() async throws {
        let (store, _, authorization) = try setup()
        let schedule = try await create(store, authorization)
        let other = try ScheduleAuthorization(chatGUID: "different-chat", senderHandle: authorization.senderHandle, workspace: authorization.workspace, permission: authorization.permission)
        let none = try await store.claimDue(now: now, authorization: other, dispatchEpoch: "new")
        let blocked = try await store.schedule(id: schedule.id)
        XCTAssertTrue(none.isEmpty); XCTAssertEqual(blocked?.state, .blocked)
        do { try await store.setSchedulePaused(id: schedule.id, paused: false, provenance: provenance()); XCTFail("Blocked schedule resumed without reauthorization") } catch {}
        _ = try await store.updateSchedule(id: schedule.id, name: schedule.name, prompt: schedule.prompt, kind: schedule.kind, rule: schedule.rule, timeZone: schedule.timeZone, authorization: other, provenance: provenance("reauthorize"), now: now)
        let claimed = try await store.claimDue(now: now, authorization: other, dispatchEpoch: "new")
        let stale = try await store.validateClaim(id: claimed[0].id, authorization: other, dispatchEpoch: "old")
        let current = try await store.validateClaim(id: claimed[0].id, authorization: other, dispatchEpoch: "new")
        XCTAssertFalse(stale); XCTAssertTrue(current)
        try await store.setSchedulePaused(id: schedule.id, paused: true, provenance: provenance("pause"), now: now)
        let paused = try await store.validateClaim(id: claimed[0].id, authorization: other, dispatchEpoch: "new")
        XCTAssertFalse(paused)
    }

    func testCancelPreservesHistoryAndPreventsFurtherDispatch() async throws {
        let (store, _, authorization) = try setup()
        let schedule = try await create(store, authorization)
        let claimed = try await store.claimDue(now: now, authorization: authorization, dispatchEpoch: "epoch")
        try await store.cancelSchedule(id: schedule.id, provenance: provenance("cancel"), now: now)
        let valid = try await store.validateClaim(id: claimed[0].id, authorization: authorization, dispatchEpoch: "epoch")
        let cancelled = try await store.schedule(id: schedule.id), history = try await store.runs(scheduleID: schedule.id)
        XCTAssertFalse(valid); XCTAssertEqual(cancelled?.state, .cancelled)
        XCTAssertEqual(cancelled?.lastChangeProvenance?.sourceID, "cancel"); XCTAssertEqual(history.count, 1)
        let future = try await store.claimDue(now: now.addingTimeInterval(6000), authorization: authorization, dispatchEpoch: "epoch")
        XCTAssertTrue(future.isEmpty)
    }

    func testOnceReminderExhaustionDoesNotClaimDeliverySuccess() async throws {
        let (store, _, authorization) = try setup()
        let schedule = try await create(store, authorization, rule: .once(at: now), kind: .reminder)
        let runs = try await store.claimDue(now: now.addingTimeInterval(1000), authorization: authorization, dispatchEpoch: "epoch")
        let once = try await store.schedule(id: schedule.id)
        XCTAssertEqual(runs.count, 1); XCTAssertEqual(runs[0].kind, .reminder); XCTAssertEqual(runs[0].state, .claimed)
        XCTAssertEqual(once?.state, .exhausted)
        let again = try await store.claimDue(now: now.addingTimeInterval(2000), authorization: authorization, dispatchEpoch: "epoch")
        XCTAssertTrue(again.isEmpty)
    }
}
