import Foundation
import XCTest
@testable import SteveNative

final class WorkspaceMemoryFollowUpTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Steve-follow-up-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func provenance(_ id: String = UUID().uuidString, statement: String = "Track this plan and remember my concise style.") -> ExplicitUserProvenance {
        .init(source: .pairedMessage, sourceID: id, statement: statement, explicitlyRequested: true, recordedAt: date("2026-09-20T12:00:00Z"))
    }
    private func authorization(_ root: URL) throws -> ScheduleAuthorization {
        try .init(chatGUID: "paired", senderHandle: "user@example.test", workspace: root.path, permission: ":workspace-write")
    }
    private func store(_ root: URL) async throws -> SteveUserAutomationStore {
        let url = root.appendingPathComponent("store.sqlite3")
        let core = try SteveStore(databaseURL: url)
        try await core.saveGatewayEpoch("epoch")
        return try SteveUserAutomationStore(databaseURL: url)
    }
    private func activePlan(end: String = "2026-10-01T09:00:00-04:00", next: String? = "2026-09-20T09:00:00-04:00") -> WorkerPlanUpdate {
        .init(summary: "Check one verified change each day.", state: .active, userQuote: "Track this plan", endsAt: end, nextCheckAt: next)
    }
    private func git(_ arguments: [String], in root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testFollowUpClaimsSevenDailyChecksWithFakeClock() async throws {
        let root = try directory(), store = try await store(root), boundary = try authorization(root)
        let start = date("2026-09-20T13:00:00Z")
        try await store.savePlan(taskID: "plan", update: activePlan(), authorization: boundary, provenance: provenance(statement: "Track this plan"), timeZone: "America/New_York", now: start.addingTimeInterval(-3_600), expectedEpoch: "epoch")
        for day in 0..<7 {
            let now = start.addingTimeInterval(Double(day) * 86_400)
            let runs = try await store.claimDue(now: now, authorization: boundary, dispatchEpoch: "epoch")
            XCTAssertEqual(runs.count, 1, "day \(day + 1)")
            let run = try XCTUnwrap(runs.first, "missing day \(day + 1) follow-up")
            XCTAssertEqual(run.followUp?.taskID, "plan")
            try await store.markEnqueued(id: run.id, downstreamID: "inbox:\(day)")
            try await store.recordOutcome(id: run.id, state: .succeeded, detail: "Verified daily check", now: now)
        }
    }

    func testInvalidProposedChecksUseDailyFallbackBeforePlanExpiry() async throws {
        let now = date("2026-09-20T12:15:00-04:00")
        let end = "2026-09-22T12:45:00-04:00"
        let fallback = date("2026-09-21T09:00:00-04:00")
        for proposed in [end, "2026-09-22T13:00:00-04:00", "2026-09-20T12:15:00-04:00", "2026-09-20T12:00:00-04:00"] {
            let root = try directory(), store = try await store(root), boundary = try authorization(root)
            var update = activePlan(end: end, next: proposed)
            update.startsAt = "2026-09-22T12:15:00-04:00"
            try await store.savePlan(taskID: "plan", update: update, authorization: boundary, provenance: provenance(), timeZone: "America/New_York", now: now, expectedEpoch: "epoch")
            let schedules = try await store.schedules()
            XCTAssertEqual(schedules.count, 1, proposed)
            XCTAssertEqual(schedules.first?.nextRunAt, fallback, proposed)
            let runs = try await store.claimDue(now: fallback, authorization: boundary, dispatchEpoch: "epoch")
            XCTAssertEqual(runs.count, 1, proposed)
            XCTAssertEqual(runs.first?.scheduledAt, fallback, proposed)
        }
    }

    func testValidProposedCheckIsPreservedBeforePlanExpiry() async throws {
        let root = try directory(), store = try await store(root), boundary = try authorization(root)
        let next = "2026-09-22T12:30:00-04:00", end = "2026-09-22T12:45:00-04:00"
        try await store.savePlan(taskID: "plan", update: activePlan(end: end, next: next), authorization: boundary, provenance: provenance(), timeZone: "America/New_York", now: date("2026-09-20T12:15:00-04:00"), expectedEpoch: "epoch")
        let schedules = try await store.schedules()
        XCTAssertEqual(schedules.first?.nextRunAt, date(next))
        let runs = try await store.claimDue(now: date(next), authorization: boundary, dispatchEpoch: "epoch")
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.scheduledAt, date(next))
        let exhausted = try await store.schedule(id: XCTUnwrap(schedules.first).id)
        XCTAssertNil(exhausted?.nextRunAt)
        XCTAssertEqual(exhausted?.state, .exhausted)
        let expiredRuns = try await store.claimDue(now: date(end), authorization: boundary, dispatchEpoch: "epoch")
        XCTAssertTrue(expiredRuns.isEmpty)
    }

    func testDailyFallbackCannotReachOrExceedPlanExpiry() async throws {
        for end in ["2026-09-20T12:45:00-04:00", "2026-09-21T09:00:00-04:00"] {
            let root = try directory(), store = try await store(root), boundary = try authorization(root)
            try await store.savePlan(taskID: "plan", update: activePlan(end: end, next: end), authorization: boundary, provenance: provenance(), timeZone: "America/New_York", now: date("2026-09-20T12:15:00-04:00"), expectedEpoch: "epoch")
            let schedules = try await store.schedules(), plans = try await store.plans(authorization: boundary)
            XCTAssertTrue(schedules.isEmpty, end)
            XCTAssertNil(plans.first?.scheduleID, end)
            let runs = try await store.claimDue(now: date(end), authorization: boundary, dispatchEpoch: "epoch")
            XCTAssertTrue(runs.isEmpty, end)
        }
    }

    func testQuietHoursDSTAndVerifiedDeadlinePolicy() {
        let expiration = date("2026-11-10T12:00:00Z")
        let policy = FollowUpPolicy(taskID: "plan", expiresAt: expiration, verifiedDeadline: nil)
        XCTAssertEqual(policy.deferredUntil(now: date("2026-11-01T04:30:00Z"), timeZone: "America/New_York"), date("2026-11-01T13:00:00Z"))
        let urgent = FollowUpPolicy(taskID: "plan", expiresAt: expiration, verifiedDeadline: date("2026-11-01T12:00:00Z"))
        XCTAssertNil(urgent.deferredUntil(now: date("2026-11-01T04:30:00Z"), timeZone: "America/New_York"))
    }

    func testExplicitReminderIsNotDeferredByFollowUpQuietHours() async throws {
        let root = try directory(), store = try await store(root), boundary = try authorization(root)
        let at = date("2026-09-21T03:00:00Z") // 11 PM EDT.
        _ = try await store.createSchedule(requestID: "reminder", name: "Explicit reminder", prompt: "Remind me now.", kind: .reminder, rule: .once(at: at), timeZone: "America/New_York", authorization: boundary, provenance: provenance(statement: "Remind me now."), now: at.addingTimeInterval(-60))
        let claimed = try await store.claimDue(now: at, authorization: boundary, dispatchEpoch: "epoch")
        XCTAssertEqual(claimed.count, 1)
    }

    func testPlanCancellationExpirationAndUncertaintyStayFailClosed() async throws {
        let root = try directory(), store = try await store(root), boundary = try authorization(root)
        let start = date("2026-09-20T13:00:00Z")
        try await store.savePlan(taskID: "cancel", update: activePlan(), authorization: boundary, provenance: provenance("start", statement: "Track this plan"), timeZone: "America/New_York", now: start, expectedEpoch: "epoch")
        try await store.cancelPlan(taskID: "cancel", provenance: provenance("cancel", statement: "Cancel this plan."), now: start, expectedEpoch: "epoch")
        try await store.savePlan(taskID: "cancel", update: activePlan(next: "2026-10-01T09:00:00-04:00"), authorization: boundary, provenance: provenance("start", statement: "Track this plan"), timeZone: "America/New_York", now: start.addingTimeInterval(1), expectedEpoch: "epoch")
        let cancelledPlans = try await store.plans(authorization: boundary), cancelledSchedules = try await store.schedules()
        XCTAssertEqual(cancelledPlans.first?.update.state, .cancelled)
        XCTAssertEqual(cancelledPlans.first?.provenance.sourceID, "cancel")
        XCTAssertEqual(cancelledSchedules.count, 1)
        XCTAssertEqual(cancelledSchedules.first?.state, .cancelled)
        let cancelledRuns = try await store.claimDue(now: start.addingTimeInterval(86_400), authorization: boundary, dispatchEpoch: "epoch")
        XCTAssertTrue(cancelledRuns.isEmpty)

        try await store.savePlan(taskID: "expire", update: activePlan(end: "2026-09-20T10:00:00-04:00"), authorization: boundary, provenance: provenance("expire", statement: "Track this plan"), timeZone: "America/New_York", now: start, expectedEpoch: "epoch")
        let expiredRuns = try await store.claimDue(now: date("2026-09-20T14:00:00Z"), authorization: boundary, dispatchEpoch: "epoch")
        XCTAssertTrue(expiredRuns.isEmpty)

        try await store.savePlan(taskID: "uncertain", update: activePlan(), authorization: boundary, provenance: provenance("uncertain", statement: "Track this plan"), timeZone: "America/New_York", now: start.addingTimeInterval(-3_600), expectedEpoch: "epoch")
        let initialRuns = try await store.claimDue(now: start, authorization: boundary, dispatchEpoch: "old")
        let run = try XCTUnwrap(initialRuns.first)
        try await store.recoverInterruptedClaims(now: start.addingTimeInterval(1))
        let recoveredRun = try await store.run(id: run.id)
        XCTAssertEqual(recoveredRun?.state, .uncertain)
        let blockedRuns = try await store.claimDue(now: start.addingTimeInterval(86_400), authorization: boundary, dispatchEpoch: "new")
        XCTAssertTrue(blockedRuns.isEmpty)
    }

    func testPreferenceAndPlanProjectionSurviveRestartAndForget() async throws {
        let root = try directory(), url = root.appendingPathComponent("store.sqlite3"), boundary = try authorization(root), now = date("2026-09-20T13:00:00Z")
        let store = try await store(root)
        _ = try await store.savePreference(key: "response style", value: "Concise", provenance: provenance("preference"), now: now)
        try await store.savePlan(taskID: "plan", update: activePlan(), authorization: boundary, provenance: provenance("plan", statement: "Track this plan"), timeZone: "America/New_York", now: now, expectedEpoch: "epoch")
        try await store.projectMemory(workspace: root.path, authorization: boundary)
        var memory = try String(contentsOf: root.appendingPathComponent(SteveWorkspaceMemory.filename), encoding: .utf8)
        XCTAssertTrue(memory.contains("response style: Concise")); XCTAssertTrue(memory.contains("Check one verified change each day"))

        let reopened = try SteveUserAutomationStore(databaseURL: url)
        let forgotten = try await reopened.forgetPreference(key: "response style", provenance: provenance("forget", statement: "Forget response style."))
        XCTAssertTrue(forgotten)
        try await reopened.projectMemory(workspace: root.path, authorization: boundary)
        memory = try String(contentsOf: root.appendingPathComponent(SteveWorkspaceMemory.filename), encoding: .utf8)
        XCTAssertFalse(memory.contains("response style: Concise")); XCTAssertTrue(memory.contains("Check one verified change each day"))
    }

    func testProjectionRejectsTrackedFileAndSymlink() async throws {
        let root = try directory(), boundary = try authorization(root), store = try await store(root)
        let memory = root.appendingPathComponent(SteveWorkspaceMemory.filename)
        try await store.projectMemory(workspace: root.path, authorization: boundary)
        try git(["init", "-q"], in: root); try git(["add", SteveWorkspaceMemory.filename], in: root)
        do {
            try await store.projectMemory(workspace: root.path, authorization: boundary)
            XCTFail("Expected a tracked memory file to be rejected")
        } catch {}
        try FileManager.default.removeItem(at: root.appendingPathComponent(".git"))
        try FileManager.default.removeItem(at: memory)
        try FileManager.default.createSymbolicLink(at: memory, withDestinationURL: root.appendingPathComponent("missing"))
        do {
            try await store.projectMemory(workspace: root.path, authorization: boundary)
            XCTFail("Expected a dangling symbolic-link memory file to be rejected")
        } catch {}
    }

    func testProjectionRejectsWorkspaceOutsideAuthorization() async throws {
        let authorizedRoot = try directory()
        let otherRoot = try directory()
        let boundary = try authorization(authorizedRoot)
        let store = try await store(authorizedRoot)
        do {
            try await store.projectMemory(workspace: otherRoot.path, authorization: boundary)
            XCTFail("Expected a workspace outside the authorization boundary to be rejected")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: otherRoot.appendingPathComponent(SteveWorkspaceMemory.filename).path))
    }
}
