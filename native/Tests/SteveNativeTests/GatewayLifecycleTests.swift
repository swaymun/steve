import XCTest
import SQLite
import PDFKit
@testable import SteveNative

private final class FixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date = Date()) { self.value = value }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(seconds) }
}
private actor FixturePhoneAccess {
    var count = 0
    var boundary: PhoneAccessBoundary?
    func issue(for gateway: GatewayCoordinator) async throws -> URL { boundary = try await gateway.phoneAccessBoundary(); return issue() }
    func issue() -> URL { count += 1; return URL(string: "https://fixture.example/#pair=private-phone-fixture")! }
}
private actor FixtureMessages: GatewayMessages {
    var sent: [String] = []
    var attachmentCaptions: [String] = []
    var startedSends = 0
    var watchCount = 0
    var watchCursors: [Int64?] = []
    var watchedMessages: [SteveInboundMessage] = []
    func replay(_ messages: [SteveInboundMessage]) { watchedMessages = messages }
    var failWatch = false
    var failSend = false
    var holdSending = false
    var holdWatching = false
    private var watchWaiter: CheckedContinuation<Void, Never>?
    func holdWatcher() { holdWatching = true }
    func releaseWatcher() { holdWatching = false; watchWaiter?.resume(); watchWaiter = nil }
    func holdDelivery() { holdSending = true }
    func releaseDelivery() { holdSending = false }
    func currentRowID() -> Int64 { 0 }
    func watchMessages(sinceRowID: Int64?) async throws -> AsyncThrowingStream<SteveInboundMessage, Error> {
        watchCount += 1
        watchCursors.append(sinceRowID)
        if holdWatching { await withCheckedContinuation { watchWaiter = $0 } }
        try Task.checkCancellation()
        if failWatch { throw RPCError(message: "fixture offline") }
        let unread = watchedMessages.filter { ($0.rowID ?? 0) > (sinceRowID ?? 0) }
        return AsyncThrowingStream { continuation in
            for message in unread { continuation.yield(message) }
        }
    }
    func configure(failWatch: Bool = false, failSend: Bool = false) { self.failWatch = failWatch; self.failSend = failSend }
    func sendText(chatGUID: String, recipient: String, text: String, replyTo: String?) async throws {
        startedSends += 1
        while holdSending { try await Task.sleep(for: .milliseconds(5)) }
        sent.append(text)
        if failSend { throw RPCError(message: "fixture ambiguous send") }
    }
    func sendAttachment(chatGUID: String, recipient: String, path: String, caption: String, replyTo: String?) throws { sent.append(path); attachmentCaptions.append(caption) }
}
private actor FixtureCodex: GatewayCodexClient {
    var approvalHandler: CodexApprovalHandler?
    func setApprovalHandler(_ handler: CodexApprovalHandler?) { approvalHandler = handler }
    var inputs: [String] = []
    var startTiers: [String] = []
    var resumeTiers: [String] = []
    var resumedThreadIDs: [String] = []
    var turnTiers: [SteveServiceTier] = []
    var threadInstructions: [(role: String, text: String)] = []
    var turns = 0
    var activeTurns = 0
    var stops = 0
    var holdWorker = false
    var approvalMode: String?
    var activeApprovalBinding: (String, String)?
    func requestConcurrentOrdinaryApproval() async -> CodexApprovalDecision? {
        guard let (threadID, turnID) = activeApprovalBinding, let approvalHandler else { return nil }
        return await approvalHandler(.init(requestID: "concurrent-native", method: "mcpServer/elicitation/request", threadID: threadID, turnID: turnID, message: "Allow app", origin: nil, connector: nil, tool: nil, expiresAt: Date().addingTimeInterval(10), mode: "form", nativeAppName: "TextEdit"))
    }
    var connectionSetup: CodexConnectionSetup?
    func askConnectionSetup() { approvalMode = "url"; connectionSetup = .init(connectorName: "Google Calendar", url: URL(string: "https://chatgpt.com/plugins?token=secret")!) }
    var nativeAppName: String?
    func askNativeApproval(name: String = "TextEdit", mismatch: Bool = false) { approvalMode = "form"; nativeAppName = name; mismatchApproval = mismatch }
    var emptyBrowserForm = false
    func askBrowserApproval() { approvalMode = "form"; emptyBrowserForm = true }
    var approvalDuration: TimeInterval = 10
    var mismatchApproval = false
    var approvalOrigin = "https://example.test/auth?token=secret"
    func setApprovalOrigin(_ value: String) { approvalOrigin = value }
    var approvalDecision: CodexApprovalDecision?
    func askApproval(mode: String = "url", duration: TimeInterval = 10, mismatch: Bool = false) { approvalMode = mode; approvalDuration = duration; mismatchApproval = mismatch }
    var workerResumeError: String?
    func failWorkerResume(_ message: String) { workerResumeError = message }
    var results: [String]
    init(_ results: [String]) { self.results = results }
    func appendResults(_ values: [String]) { results.append(contentsOf: values) }
    func hold() { holdWorker = true }
    func releaseWorker() { holdWorker = false }
    func stop() { stops += 1 }
    func startThread(cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool, serviceTier: SteveServiceTier) -> String { let role = isRelay ? "relay" : "worker"; startTiers.append(role + ":" + serviceTier.rawValue); threadInstructions.append((role, developerInstructions)); return UUID().uuidString }
    func resumeThread(threadID: String, cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool, serviceTier: SteveServiceTier) throws {
        let role = isRelay ? "relay" : "worker"; resumeTiers.append(role + ":" + serviceTier.rawValue); resumedThreadIDs.append(threadID); threadInstructions.append((role, developerInstructions))
        if !isRelay, let workerResumeError { throw RPCError(message: workerResumeError) }
    }
    func compactThread(threadID: String) {}
    func interruptTurn(threadID: String, turnID: String) {}
    func runTurn(threadID: String, text: String, attachmentPaths: [String], workspace: String?, model: String, effort: String, serviceTier: SteveServiceTier, onTurnStarted: @escaping @Sendable (String) async -> Void) async throws -> CodexTurnResult {
        turnTiers.append(serviceTier)
        inputs.append(text)
        turns += 1
        activeTurns += 1
        defer { activeTurns -= 1 }
        let turnID = UUID().uuidString
        await onTurnStarted(turnID)
        if let mode = approvalMode, turns == 2, let approvalHandler {
            activeApprovalBinding = (threadID, turnID)
            let request = CodexApprovalRequest(requestID: "rpc-approval", method: "mcpServer/elicitation/request", threadID: mismatchApproval ? "other-thread" : threadID, turnID: turnID, message: "Allow fixture action? https://example.test/auth?token=secret", origin: approvalOrigin, connector: "fixture", tool: "read_record", expiresAt: Date().addingTimeInterval(approvalDuration), mode: mode, isEmptyBrowserOriginForm: emptyBrowserForm, nativeAppName: nativeAppName, connectionSetup: connectionSetup)
            approvalDecision = await approvalHandler(request)
        }
        while holdWorker && turns == 2 { try await Task.sleep(for: .milliseconds(5)) }
        return CodexTurnResult(text: results.isEmpty ? "invalid" : results.removeFirst(), attachmentPaths: [])
    }
}
final class GatewayLifecycleTests: XCTestCase {
    private let relay = #"{"schemaVersion":1,"kind":"relay_request","action":"execute","mode":"computer","taskTitle":"Fixture task","workerPrompt":"Do the fixture action"}"#
    private let worker = #"{"schemaVersion":1,"kind":"worker_result","status":"completed","summary":"Done","artifacts":[]}"#
    private func inbound(_ id: String = UUID().uuidString, text: String = "Do a task") -> SteveInboundMessage {
        .init(guid: id, chatGuid: "chat", senderHandle: "user@example.test", text: text, isFromMe: false, isGroup: false, attachmentPaths: [], replyToGuid: nil, rowID: 42)
    }
    private func setup(_ replies: [String], takeoverLifetime: TimeInterval = 600, acknowledgementDelay: Duration = .seconds(10), withAutomation: Bool = false, clock: FixtureClock? = nil) async throws -> (SteveStore, GatewayCoordinator, FixtureMessages, FixtureCodex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = try SteveStore(databaseURL: root.appendingPathComponent("test.sqlite"))
        var settings = Settings(displayName: "Fixture", model: "fixture", effort: "low", workspaceRoot: root.path)
        settings.permissionProfile = "workspace-write"
        try await store.saveSettings(settings)
        try await store.saveTrustedConversation(.init(chatGuid: "chat", senderHandle: "user@example.test"))
        let messages = FixtureMessages(), codex = FixtureCodex(replies)
        let automation = withAutomation ? try SteveUserAutomationStore(databaseURL: store.databaseURL) : nil
        let gateway = GatewayCoordinator(store: store, messages: messages, codex: codex, debounce: .milliseconds(5), retryDelay: .milliseconds(10), takeoverLifetime: takeoverLifetime, acknowledgementDelay: acknowledgementDelay, automation: automation, clockNow: { clock?.now() ?? Date() })
        addTeardownBlock { await gateway.stop() }
        return (store, gateway, messages, codex)
    }
    private func eventually(_ condition: @escaping () async throws -> Bool) async throws {
        for _ in 0..<150 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Condition did not become true")
    }
    func testIntakeWriteFailureReconnectsBeforeCheckpointCanSkipTheMessage() async throws {
        let (store, gateway, messages, codex) = try await setup([])
        try await store.savePaused(true)
        let database = try Connection(store.databaseURL.path)
        try database.execute("""
            CREATE TRIGGER fail_fixture_intake BEFORE INSERT ON queue
            WHEN NEW.id = 'inbound:retry-after-write-error'
            BEGIN SELECT RAISE(ABORT, 'fixture write unavailable'); END;
            """)
        let first = inbound("retry-after-write-error")
        let later = SteveInboundMessage(guid: "other-conversation", chatGuid: "unpaired", senderHandle: "other@example.test", text: "Ignore", isFromMe: false, isGroup: false, attachmentPaths: [], replyToGuid: nil, rowID: 43)
        await messages.replay([first, later])
        await gateway.start()
        try await eventually { await messages.watchCount >= 2 }
        let cursorBeforeRecovery = try await store.messageCursor()
        XCTAssertEqual(cursorBeforeRecovery, 0, "A later chat must not checkpoint past an unsaved paired message")
        try database.execute("DROP TRIGGER fail_fixture_intake")
        try await eventually { try await store.messageCursor() == 43 }
        let inbox = try await store.pendingInbox()
        let cursors = await messages.watchCursors
        let turns = await codex.turns
        XCTAssertEqual(inbox.map(\.guid), [first.guid])
        XCTAssertTrue(cursors.allSatisfy { $0 == 0 })
        XCTAssertEqual(turns, 0)
    }
    func testServiceTierReachesBothThreadsAndEveryTurnIncludingResume() async throws {
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done"],"attachments":[]}"#
        let (store, gateway, _, codex) = try await setup([relay, worker, plan, relay, worker, plan])
        var settings = try await store.getSettings()!
        settings.serviceTier = .fast
        try await store.saveSettings(settings)
        await gateway.start(); await gateway.receive(inbound("fast-tier"))
        try await eventually { try await store.queueState("inbound:fast-tier") == "completed" }
        await gateway.beginBoundaryChange()
        settings.serviceTier = .standard
        try await store.saveSettings(settings)
        await gateway.endBoundaryChange()
        await gateway.receive(inbound("standard-tier"))
        try await eventually { try await store.queueState("inbound:standard-tier") == "completed" }
        let starts = await codex.startTiers, resumes = await codex.resumeTiers, turns = await codex.turnTiers
        XCTAssertEqual(starts, ["relay:standard", "worker:fast", "worker:standard"])
        XCTAssertEqual(Set(resumes), ["relay:standard"])
        XCTAssertFalse(resumes.contains(where: { $0.hasPrefix("worker:") }))
        XCTAssertEqual(turns, [.standard, .fast, .standard, .standard, .standard, .standard])
    }
    func testRuntimeCapabilitiesReachBothTurnsAndQuoteExactExecutable() async throws {
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done"],"attachments":[]}"#
        let (_, gateway, messages, codex) = try await setup([relay, worker, plan])
        await gateway.start(); await gateway.receive(inbound("capability-task"))
        try await eventually { await messages.sent.count > 0 }
        let instructions = await codex.threadInstructions
        let workerInstructions = try XCTUnwrap(instructions.first(where: { $0.role == "worker" })?.text)
        XCTAssertTrue(workerInstructions.contains(Bundle.main.executableURL!.path))
        XCTAssertTrue(workerInstructions.contains("video start --demonstration"))
        XCTAssertTrue(workerInstructions.contains("scan home folders"))
        var context = StevePromptContext(workspace: "/tmp", permissionProfile: "read-only", model: "fixture", effort: "low")
        context.executablePath = "/Applications/Steve's App.app/Contents/MacOS/Steve"
        XCTAssertTrue(StevePrompt.runtimeCapabilities(context).contains("'\"'\"'"))
    }
    func testRelayPreferenceControlPersistsActualUserProvenanceWithoutWorker() async throws {
        let control = #"{"schemaVersion":1,"kind":"relay_request","action":"control","control":{"operation":"preference_set","userQuote":"Remember concise answers","key":"style","value":"Concise"}}"#
        let (store, gateway, messages, codex) = try await setup([control], withAutomation: true)
        await gateway.start(); await gateway.receive(inbound("human-preference", text: "Remember concise answers"))
        try await eventually { await messages.sent.count > 0 }
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let preference = try await automation.preference(key: "style")
        XCTAssertEqual(preference?.value, "Concise")
        XCTAssertEqual(preference?.provenance.sourceID, "human-preference")
        let turns = await codex.turns; XCTAssertEqual(turns, 1)
    }
    func testFailedApprovalPromptCancelsWithoutSavedDenial() async throws {
        let (_, gateway, messages, codex) = try await setup([relay, worker])
        await messages.configure(failSend: true); await codex.askApproval()
        await gateway.start(); await gateway.receive(inbound("unsent-approval"))
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision
        XCTAssertEqual(decision, .cancel)
    }
    private func dueSchedule(_ store: SteveStore, kind: UserScheduleKind, now: Date = Date()) async throws -> (SteveUserAutomationStore, UserSchedule, Date) {
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let settings = try await store.getSettings()!
        let boundary = try ScheduleAuthorization(chatGUID: "chat", senderHandle: "user@example.test", workspace: settings.workspaceRoot!, permission: "workspace-write")
        let item = try await automation.createSchedule(requestID: UUID().uuidString, name: "Fixture", prompt: "Read fixture status", kind: kind, rule: .once(at: now.addingTimeInterval(60)), timeZone: "UTC", authorization: boundary, provenance: .init(source: .pairedMessage, sourceID: "schedule-request", statement: "Schedule reading fixture status in one minute", explicitlyRequested: true, recordedAt: now), now: now)
        return (automation, item, now.addingTimeInterval(61))
    }
    func testScheduledReminderUsesDurableDeliveryWithoutWorkerAndWaitsForSent() async throws {
        let clock = FixtureClock()
        let (store, gateway, messages, codex) = try await setup([], withAutomation: true, clock: clock)
        await gateway.start(); await messages.holdDelivery()
        let (automation, item, _) = try await dueSchedule(store, kind: .reminder, now: clock.now())
        clock.advance(61)
        try await eventually {
            try await gateway.pollSchedules(now: clock.now())
            return try await automation.runs(scheduleID: item.id).first?.state == .enqueued
        }
        let before = try await automation.runs(scheduleID: item.id).first!
        XCTAssertEqual(before.state, .enqueued)
        await messages.releaseDelivery()
        try await eventually { try await store.queueState("inbound:" + before.downstreamID!) == "completed" }
        try await eventually {
            try await gateway.pollSchedules(now: clock.now())
            return try await automation.run(id: before.id)?.state == .succeeded
        }
        let after = try await automation.run(id: before.id), turns = await codex.turns
        XCTAssertEqual(after?.state, .succeeded); XCTAssertEqual(turns, 0)
        let sent = await messages.sent; XCTAssertTrue(sent.joined().contains("Reminder:"))
    }
    func testScheduledCompletedWorkerWithUncertainDeliveryDoesNotSucceed() async throws {
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done"],"attachments":[]}"#
        let clock = FixtureClock()
        let (store, gateway, messages, _) = try await setup([relay, worker, plan], withAutomation: true, clock: clock)
        await gateway.start(); await messages.configure(failSend: true)
        let (automation, item, _) = try await dueSchedule(store, kind: .task, now: clock.now())
        clock.advance(61)
        // The automatic scheduler can already own a poll when a manual tick
        // arrives. Overlapping ticks intentionally coalesce. Drive the shared
        // clock until reconciliation finishes, not just one tick's return.
        try await eventually {
            try await gateway.pollSchedules(now: clock.now())
            return try await automation.runs(scheduleID: item.id).first?.state == .uncertain
        }
        let run = try await automation.runs(scheduleID: item.id).first!
        XCTAssertEqual(run.executionOutcome, .succeeded)
        XCTAssertEqual(run.state, .uncertain)
        let inboxState = try await store.queueState("inbound:" + run.downstreamID!)
        XCTAssertEqual(inboxState, "uncertain")
        clock.advance(600)
        try await gateway.pollSchedules(now: clock.now())
        let all = try await automation.runs(scheduleID: item.id); XCTAssertEqual(all.count, 1)
    }
    func testPausedSchedulerDoesNotClaimUntilExplicitResume() async throws {
        let clock = FixtureClock()
        let (store, gateway, messages, _) = try await setup([], withAutomation: true, clock: clock)
        await gateway.start(); try await gateway.setPaused(true)
        let (automation, item, _) = try await dueSchedule(store, kind: .reminder, now: clock.now())
        clock.advance(61)
        try await gateway.pollSchedules(now: clock.now())
        let before = try await automation.runs(scheduleID: item.id); XCTAssertTrue(before.isEmpty)
        try await gateway.setPaused(false)
        try await eventually {
            try await gateway.pollSchedules(now: clock.now())
            return await messages.sent.count > 0
        }
        let after = try await automation.runs(scheduleID: item.id); XCTAssertEqual(after.count, 1)
    }
    func testSettingsChangeRevokesSchedulesEvenIfSameBoundaryIsRestored() async throws {
        let (store, gateway, messages, _) = try await setup([], withAutomation: true)
        await gateway.start()
        let (automation, item, due) = try await dueSchedule(store, kind: .reminder)
        await gateway.beginBoundaryChange(); await gateway.endBoundaryChange()
        try await gateway.pollSchedules(now: due)
        let saved = try await automation.schedule(id: item.id), runs = try await automation.runs(scheduleID: item.id)
        XCTAssertEqual(saved?.state, .blocked); XCTAssertTrue(runs.isEmpty)
        let sent = await messages.sent; XCTAssertTrue(sent.isEmpty)
    }
    func testScheduledAdmissionAtomicallyPersistsInboxAndAcknowledgmentAcrossRestart() async throws {
        let (store, gateway, _, _) = try await setup([], withAutomation: true)
        await gateway.start()
        let (automation, _, due) = try await dueSchedule(store, kind: .reminder)
        let settings = try await store.getSettings()!
        let boundary = try ScheduleAuthorization(chatGUID: "chat", senderHandle: "user@example.test", workspace: settings.workspaceRoot!, permission: "workspace-write")
        let epoch = try await store.gatewayEpoch()!
        let run = try await automation.claimDue(now: due, authorization: boundary, dispatchEpoch: epoch).first!
        let inserted = try await store.acceptScheduledRun(id: run.id, expectedEpoch: epoch)
        XCTAssertTrue(inserted)
        let reopened = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        try await reopened.recoverInterruptedClaims()
        let saved = try await reopened.run(id: run.id)!
        XCTAssertEqual(saved.state, .enqueued)
        let state = try await store.queueState("inbound:" + saved.downstreamID!)
        XCTAssertEqual(state, "pending")
        let claims = try await reopened.claimDue(now: due, authorization: boundary, dispatchEpoch: epoch)
        XCTAssertTrue(claims.isEmpty)
    }
    private var phoneControl: String {
        #"{"schemaVersion":1,"kind":"relay_request","action":"control","control":{"operation":"phone_access","userQuote":"Let me log in from my phone"}}"#
    }
    func testPhoneAccessSecretOnlyReachesSerialMessagesTransport() async throws {
        let (store, gateway, messages, codex) = try await setup([phoneControl])
        let phone = FixturePhoneAccess()
        await gateway.setPhoneAccessHandler { await phone.issue() }
        await gateway.start(); await gateway.receive(inbound("phone-request", text: "Let me log in from my phone"))
        try await eventually { try await store.queueState("inbound:phone-request") == "completed" }
        let sent = await messages.sent, inputs = await codex.inputs, turns = await codex.turns
        XCTAssertEqual(turns, 1); XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("#pair=private-phone-fixture"))
        XCTAssertFalse(inputs.joined().contains("private-phone-fixture"))
        let queued = try await store.pendingOutbox(); XCTAssertTrue(queued.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(at: store.databaseURL.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        for file in files where file.lastPathComponent.hasPrefix("test.sqlite") {
            XCTAssertNil(try Data(contentsOf: file).range(of: Data("private-phone-fixture".utf8)))
        }
        let paused = await gateway.isPaused(); XCTAssertFalse(paused, "Link issuance must not grant control or pause work")
    }
    func testExpiredPrivatePhoneLinkCannotOvertakeSerialSenderOrReplay() async throws {
        let clock = FixtureClock()
        let (store, gateway, messages, _) = try await setup([phoneControl], clock: clock)
        let phone = FixturePhoneAccess()
        await gateway.setPhoneAccessHandler { await phone.issue() }
        await messages.holdDelivery(); await gateway.start()
        await gateway.receive(inbound("held-status", text: "status"))
        try await eventually { await messages.startedSends == 1 }
        await gateway.receive(inbound("expiring-phone", text: "Let me log in from my phone"))
        try await eventually { await phone.count == 1 }
        let before = await messages.sent; XCTAssertTrue(before.isEmpty)
        clock.advance(121); await messages.releaseDelivery()
        try await eventually { try await store.queueState("inbound:expiring-phone") == "cancelled" }
        let after = await messages.sent; XCTAssertFalse(after.joined().contains("private-phone-fixture"))
        await gateway.stop(); await gateway.start()
        let count = await phone.count; XCTAssertEqual(count, 1)
    }
    func testQueuedPrivatePhoneLinkRechecksExactPairingBeforeDelivery() async throws {
        let (store, gateway, messages, _) = try await setup([phoneControl])
        let phone = FixturePhoneAccess()
        await gateway.setPhoneAccessHandler { await phone.issue() }
        await messages.holdDelivery(); await gateway.start()
        await gateway.receive(inbound("held-pair-status", text: "status"))
        try await eventually { await messages.startedSends == 1 }
        await gateway.receive(inbound("old-pair-phone", text: "Let me log in from my phone"))
        try await eventually { await phone.count == 1 }
        try await store.saveTrustedConversation(.init(chatGuid: "other-chat", senderHandle: "other@example.test"))
        await messages.releaseDelivery()
        try await eventually { try await store.queueState("inbound:old-pair-phone") == "cancelled" }
        let sent = await messages.sent; XCTAssertFalse(sent.joined().contains("private-phone-fixture"))
    }
    func testAmbiguousPrivatePhoneSendIsNeverRetriedOrPersisted() async throws {
        let (store, gateway, messages, _) = try await setup([phoneControl])
        let phone = FixturePhoneAccess()
        await gateway.setPhoneAccessHandler { await phone.issue() }
        await messages.configure(failSend: true); await gateway.start()
        await gateway.receive(inbound("ambiguous-phone", text: "Let me log in from my phone"))
        try await eventually { try await store.queueState("inbound:ambiguous-phone") == "uncertain" }
        await gateway.stop(); await gateway.start()
        let sent = await messages.sent, count = await phone.count
        XCTAssertEqual(sent.count, 1); XCTAssertEqual(count, 1)
        let outbox = try await store.pendingOutbox(); XCTAssertTrue(outbox.isEmpty)
    }
    func testInboxPayloadAndCursorSurviveReopenWithoutDuplicates() async throws {
        let (store, _, _, _) = try await setup([])
        let message = inbound("durable")
        let accepted = try await store.acceptInbound(message)
        let duplicate = try await store.acceptInbound(message)
        let settings = try await store.getSettings()!
        let reopened = try SteveStore(databaseURL: URL(fileURLWithPath: settings.workspaceRoot!).appendingPathComponent("test.sqlite"))
        let pending = try await reopened.pendingInbox(), cursor = try await reopened.messageCursor()
        XCTAssertTrue(accepted); XCTAssertFalse(duplicate); XCTAssertEqual(pending, [message]); XCTAssertEqual(cursor, 42)
        _ = try await store.claimInbox([message.guid])
        try await store.recoverInterruptedWork()
        let state = try await store.queueState("inbound:durable")
        XCTAssertEqual(state, "uncertain")
        let remaining = try await store.pendingInbox(); XCTAssertTrue(remaining.isEmpty)
    }
    func testSendingCrashHoldsLaterPartsAndNeverBlindRetries() async throws {
        let (store, _, _, _) = try await setup([])
        let message = inbound("delivery")
        _ = try await store.acceptInbound(message); _ = try await store.claimInbox([message.guid])
        let first = SteveStore.OutboundPart(id: "one", chatGuid: "chat", recipient: message.senderHandle, replyTo: message.guid, inboxGUIDs: [message.guid], text: "one", attachmentPath: nil, workspace: nil, permission: nil)
        let second = SteveStore.OutboundPart(id: "two", chatGuid: "chat", recipient: message.senderHandle, replyTo: message.guid, inboxGUIDs: [message.guid], text: "two", attachmentPath: nil, workspace: nil, permission: nil)
        try await store.stageDelivery([first, second], inboxGUIDs: [message.guid])
        _ = try await store.beginSending(first.id)
        try await store.recoverInterruptedWork()
        let pending = try await store.pendingOutbox(), state = try await store.queueState(first.id)
        XCTAssertTrue(pending.isEmpty); XCTAssertEqual(state, "uncertain")
    }
    func testFlattenedControlGetsOneCorrectionWithOriginalProvenance() async throws {
        let quote = "Remember concise answers"
        let flat = #"{"schemaVersion":1,"kind":"relay_request","action":"control","operation":"preference_set","userQuote":"Remember concise answers","key":"style","value":"Concise"}"#
        let fixed = #"{"schemaVersion":1,"kind":"relay_request","action":"control","control":{"operation":"preference_set","userQuote":"Remember concise answers","key":"style","value":"Concise"}}"#
        let (store, gateway, _, codex) = try await setup([flat, fixed], withAutomation: true)
        await gateway.start(); await gateway.receive(inbound("repair", text: quote))
        try await eventually { try await store.agentSession(for: "chat")?.executionState == "idle" }
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let preference = try await automation.preference(key: "style")
        XCTAssertEqual(preference?.provenance.sourceID, "repair")
        XCTAssertEqual(preference?.value, "Concise")
        let inputs = await codex.inputs
        XCTAssertEqual(inputs.count, 2)
        XCTAssertTrue(inputs[1].hasPrefix("USER_REQUEST_FORMAT_CORRECTION:"))
        XCTAssertTrue(inputs[1].contains("USER_REQUEST:\n" + quote))
    }
    func testMissingNewTaskRoutingFieldsGetsOneCorrectionInsteadOfDefaults() async throws {
        let missing = #"{"schemaVersion":1,"kind":"relay_request","action":"execute","workerPrompt":"Do the fixture action"}"#
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done"],"attachments":[]}"#
        let (store, gateway, messages, codex) = try await setup([missing, relay, worker, plan])
        await gateway.start(); await gateway.receive(inbound("missing-routing"))
        try await eventually { try await store.queueState("inbound:missing-routing") == "completed" }
        let inputs = await codex.inputs
        let tasks = try await store.operatorTasks(chatGuid: "chat")
        XCTAssertEqual(inputs.count, 4)
        XCTAssertTrue(inputs[1].hasPrefix("USER_REQUEST_FORMAT_CORRECTION:"))
        XCTAssertEqual(inputs.filter { $0.hasPrefix("USER_REQUEST_FORMAT_CORRECTION:") }.count, 1)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.title, "Fixture task")
        XCTAssertEqual(tasks.first?.mode, .computer)
        let sent = await messages.sent
        XCTAssertEqual(sent, ["Done"])
    }
    func testOldRelayContractStartsOneReplacementAndRetainsLegacyWorkerWithoutReplay() async throws {
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done"],"attachments":[]}"#
        let (store, gateway, messages, codex) = try await setup([relay, worker, plan])
        let storedSettings = try await store.getSettings()
        let settings = try XCTUnwrap(storedSettings)
        let original = SteveStore.AgentSession(chatGuid: "chat", threadID: "legacy-worker", relayThreadID: "legacy-relay", relayPromptVersion: "relay-v12-old",
            workspacePath: try XCTUnwrap(settings.workspaceRoot), permissionProfile: "workspace-write", model: settings.model, effort: settings.effort,
            lastMessageGuid: "legacy-message", executionState: "idle", updatedAt: Date())
        try await store.saveAgentSession(original)

        await gateway.start(); await gateway.receive(inbound("contract-upgrade"))
        try await eventually { try await store.queueState("inbound:contract-upgrade") == "completed" }
        let starts = await codex.startTiers
        let resumes = await codex.resumeTiers
        let resumedThreadIDs = await codex.resumedThreadIDs
        let tasks = try await store.operatorTasks(chatGuid: "chat")
        let storedSession = try await store.agentSession(for: "chat")
        let session = try XCTUnwrap(storedSession)
        XCTAssertEqual(starts.filter { $0.hasPrefix("relay:") }.count, 1)
        XCTAssertEqual(starts.filter { $0.hasPrefix("worker:") }.count, 1)
        XCTAssertFalse(resumedThreadIDs.contains("legacy-relay"), "The stale relay contract must never resume")
        XCTAssertFalse(resumedThreadIDs.contains("legacy-worker"), "Migrating a legacy worker must not replay it")
        XCTAssertEqual(resumes.filter { $0.hasPrefix("relay:") }.count, 1, "The replacement relay may be resumed only for its delivery turn")
        XCTAssertEqual(tasks.filter { $0.threadID == "legacy-worker" }.count, 1)
        XCTAssertEqual(tasks.first(where: { $0.threadID == "legacy-worker" })?.state, .completed)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertNotEqual(session.relayThreadID, "legacy-relay")
        XCTAssertEqual(session.relayPromptVersion, StevePrompt.relayPromptVersion)
        let sent = await messages.sent
        XCTAssertEqual(sent, ["Done"])
    }
    func testControlRequestsReuseRelayWithoutStartingAnOperator() async throws {
        let control = #"{"schemaVersion":1,"kind":"relay_request","action":"control","control":{"operation":"schedule_list","userQuote":"List my schedules"}}"#
        let (store, gateway, messages, codex) = try await setup([control, control], withAutomation: true)
        await gateway.start(); await gateway.receive(inbound("first-control", text: "List my schedules"))
        try await eventually { try await store.queueState("inbound:first-control") == "completed" }
        let firstValue = try await store.agentSession(for: "chat")
        let first = try XCTUnwrap(firstValue)
        await codex.failWorkerResume("Codex App Server request failed (-32600): no rollout found")
        await gateway.receive(inbound("second-control", text: "List my schedules"))
        try await eventually { try await store.queueState("inbound:second-control") == "completed" }
        let secondValue = try await store.agentSession(for: "chat")
        let second = try XCTUnwrap(secondValue)
        let starts = await codex.startTiers, turns = await codex.turns, sent = await messages.sent
        XCTAssertTrue(first.threadID.isEmpty)
        XCTAssertTrue(second.threadID.isEmpty)
        XCTAssertEqual(first.relayThreadID, second.relayThreadID)
        XCTAssertEqual(starts.filter { $0.hasPrefix("worker:") }.count, 0)
        XCTAssertEqual(starts.filter { $0.hasPrefix("relay:") }.count, 1)
        XCTAssertEqual(turns, 2); XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(second.executionState, "idle")
    }
    func testUnknownWorkerResumeFailureDoesNotStartReplacementOrReplay() async throws {
        let taskID = "existing-task"
        let request = #"{"schemaVersion":1,"kind":"relay_request","action":"execute","workerPrompt":"Continue without replaying prior work","taskID":"existing-task"}"#
        let (store, gateway, _, codex) = try await setup([request])
        let settingsValue = try await store.getSettings()
        let settings = try XCTUnwrap(settingsValue)
        let original = SteveStore.AgentSession(chatGuid: "chat", threadID: "existing-worker", relayThreadID: "existing-relay", relayPromptVersion: StevePrompt.relayPromptVersion,
            workspacePath: try XCTUnwrap(settings.workspaceRoot), permissionProfile: "workspace-write", model: settings.model, effort: settings.effort,
            lastMessageGuid: "original-control", executionState: "idle", updatedAt: Date())
        try await store.saveAgentSession(original)
        await gateway.start()
        let storedEpoch = try await store.gatewayEpoch()
        let epoch = try XCTUnwrap(storedEpoch)
        let existing = OperatorTaskRecord(id: taskID, chatGuid: "chat", senderHandle: "user@example.test", workspace: try XCTUnwrap(settings.workspaceRoot), permission: "workspace-write", title: "Existing task", objective: "Earlier work", threadID: "existing-worker", mode: .computer, state: .completed, inbound: [], runID: "earlier-run", summary: "Earlier result")
        try await store.saveOperatorTask(existing, expectedEpoch: epoch)
        await codex.failWorkerResume("Codex App Server request failed (-32600)")
        await gateway.receive(inbound("unknown-resume", text: "List my schedules"))
        try await eventually { try await store.queueState("inbound:unknown-resume") == "failed" }
        let starts = await codex.startTiers, turns = await codex.turns, resumes = await codex.resumeTiers
        let retained = try await store.operatorTask(id: taskID)
        XCTAssertEqual(resumes, ["relay:standard", "worker:standard"])
        XCTAssertTrue(starts.isEmpty); XCTAssertEqual(turns, 1, "Only relay routing runs; the failed operator resume is never replayed")
        XCTAssertEqual(retained?.threadID, "existing-worker")
        XCTAssertNotEqual(retained?.runID, "earlier-run")
        XCTAssertEqual(retained?.summary, "The task could not be started.")
    }
    func testSuccessfulScheduleControlDeliversCreatedIdentifierAndSettlesSession() async throws {
        let quote = "Remind me every Friday at 4 pm America/Chicago to review tasks and tell me its identifier"
        let envelope: [String: Any] = ["schemaVersion": 1, "kind": "relay_request", "action": "control",
            "control": ["operation": "schedule_create", "userQuote": quote, "includeIdentifiers": true,
                "schedule": ["name": "Friday review", "prompt": "Review tasks", "kind": "reminder", "timing": "calendar", "timeZone": "America/Chicago", "hour": 16, "minute": 0, "weekdays": [5]]]]
        let reply = String(decoding: try JSONSerialization.data(withJSONObject: envelope), as: UTF8.self)
        let (store, gateway, messages, codex) = try await setup([reply], withAutomation: true)
        await gateway.start(); await gateway.receive(inbound("schedule-identifier", text: quote))
        try await eventually { try await store.queueState("inbound:schedule-identifier") == "completed" }
        try await eventually { try await store.agentSession(for: "chat")?.executionState == "idle" }
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let schedules = try await automation.schedules()
        XCTAssertEqual(schedules.count, 1)
        let schedule = try XCTUnwrap(schedules.first)
        let sent = await messages.sent, turns = await codex.turns
        XCTAssertTrue(sent.joined().contains("Identifier: " + schedule.id))
        let session = try await store.agentSession(for: "chat")
        XCTAssertEqual(session?.lastMessageGuid, "schedule-identifier")
        XCTAssertEqual(turns, 1, "Successful control must not run a worker or retry")
    }
    func testOrdinaryReminderConfirmationUsesLocalTimeWithoutAnIdentifier() async throws {
        let control = #"{"schemaVersion":1,"kind":"relay_request","action":"control","control":{"operation":"schedule_create","userQuote":"Remind me in two hours to stretch","schedule":{"name":"Stretch","prompt":"Time to stretch","kind":"reminder","timing":"once","timeZone":"America/New_York","at":"2099-01-05T14:30:00-05:00"}}}"#
        let (store, gateway, messages, _) = try await setup([control], withAutomation: true)
        await gateway.start(); await gateway.receive(inbound("ordinary-reminder", text: "Remind me in two hours to stretch"))
        try await eventually { try await store.queueState("inbound:ordinary-reminder") == "completed" }
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let schedules = try await automation.schedules()
        let schedule = try XCTUnwrap(schedules.first)
        let sent = await messages.sent.joined()
        XCTAssertTrue(sent.contains("Reminder set: Stretch"))
        XCTAssertTrue(sent.contains("2:30 PM (EST)"))
        XCTAssertFalse(sent.contains(schedule.id))
        XCTAssertFalse(sent.contains("2099-01-05T"))
    }
    func testFridayScheduleCorrectionPersistsOnceEvenWhenDeliveryIsUncertain() async throws {
        let quote = "Remind me every Friday at 4 pm America/Chicago to review tasks"
        let control: [String: Any] = ["operation": "schedule_create", "userQuote": quote,
            "schedule": ["name": "Friday review", "prompt": "Review tasks", "kind": "reminder", "timing": "calendar", "timeZone": "America/Chicago", "hour": 16, "minute": 0, "weekdays": [5]]]
        var flat = control
        flat.merge(["schemaVersion": 1, "kind": "relay_request", "action": "control"]) { _, new in new }
        let fixed: [String: Any] = ["schemaVersion": 1, "kind": "relay_request", "action": "control", "control": control]
        let replies = try [flat, fixed].map { String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self) }
        let (store, gateway, messages, codex) = try await setup(replies, withAutomation: true)
        await messages.configure(failSend: true)
        await gateway.start(); await gateway.receive(inbound("friday", text: quote))
        try await eventually { try await store.queueState("inbound:friday") == "uncertain" }
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let schedules = try await automation.schedules(), turns = await codex.turns
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(schedules.first?.rule, .calendar(hour: 16, minute: 0, weekdays: [5]))
        XCTAssertEqual(schedules.first?.timeZone, "America/Chicago")
        XCTAssertEqual(turns, 2)
        await gateway.stop(); await gateway.start()
        await gateway.receive(inbound("friday", text: quote))
        let afterRestart = try await automation.schedules(), turnsAfterRestart = await codex.turns
        XCTAssertEqual(afterRestart.count, 1); XCTAssertEqual(turnsAfterRestart, 2)
    }
    func testCorrectionFailureStopsAfterTwoTurnsAndMarksSessionFailed() async throws {
        let (store, gateway, messages, codex) = try await setup(["broken", "still broken"])
        await gateway.start(); await gateway.receive(inbound("repair-failed"))
        try await eventually { await messages.sent.contains { $0.contains("couldn't safely prepare") } }
        let state = try await store.agentSession(for: "chat")?.executionState
        let inbox = try await store.queueState("inbound:repair-failed")
        let turns = await codex.turns
        XCTAssertEqual(state, "failed"); XCTAssertEqual(inbox, "failed"); XCTAssertEqual(turns, 2)
        let sent = await messages.sent
        XCTAssertFalse(sent.joined().contains("AgentEnvelopeError"))
    }
    func testCorrectionCanRefuseWithoutExecutingWorker() async throws {
        let refusal = #"{"schemaVersion":1,"kind":"relay_request","action":"refuse","userMessage":"I cannot safely represent that request."}"#
        let (store, gateway, messages, codex) = try await setup(["broken", refusal])
        await gateway.start(); await gateway.receive(inbound("repair-refused"))
        try await eventually { try await store.queueState("inbound:repair-refused") == "completed" }
        let sent = await messages.sent, turns = await codex.turns
        let state = try await store.agentSession(for: "chat")?.executionState
        XCTAssertEqual(sent, ["I cannot safely represent that request."]); XCTAssertEqual(turns, 2); XCTAssertEqual(state, "idle")
    }
    func testCorrectedControlCannotInventCurrentUserProvenance() async throws {
        let fixed = #"{"schemaVersion":1,"kind":"relay_request","action":"control","control":{"operation":"preference_set","userQuote":"Remember concise answers","key":"style","value":"Concise"}}"#
        let (store, gateway, _, codex) = try await setup(["broken", fixed], withAutomation: true)
        await gateway.start(); await gateway.receive(inbound("invented-quote", text: "List my preferences"))
        try await eventually { try await store.agentSession(for: "chat")?.executionState == "failed" }
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let preferences = try await automation.preferences(), turns = await codex.turns
        XCTAssertTrue(preferences.isEmpty); XCTAssertEqual(turns, 2)
    }
    func testMalformedWorkerResultIsNotExecutedAgain() async throws {
        let (store, gateway, messages, codex) = try await setup([relay, "broken output"])
        await gateway.start(); await gateway.receive(inbound("bad"))
        try await eventually { try await store.queueState("inbound:bad") == "uncertain" }
        let turns = await codex.turns, sent = await messages.sent
        XCTAssertEqual(turns, 2); XCTAssertFalse(sent.contains("Success"))
        let tasks = try await store.operatorTasks(chatGuid: "chat")
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks.first?.state, .uncertain)
    }
    func testUnknownAttachmentRejectsWholeDeliveryBeforeText() async throws {
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Success"],"attachments":[{"artifactID":"missing"}]}"#
        let (store, gateway, messages, codex) = try await setup([relay, worker, plan])
        await gateway.start(); await gateway.receive(inbound("unknown"))
        try await eventually { try await store.queueState("inbound:unknown") == "uncertain" }
        let sent = await messages.sent, turns = await codex.turns
        XCTAssertFalse(sent.contains("Success")); XCTAssertEqual(turns, 3)
    }

    func testDeliveryFormatsBothMessageAndAttachmentCaption() async throws {
        let (store, gateway, messages, codex) = try await setup([])
        let settings = try await store.getSettings()
        let root = try XCTUnwrap(settings?.workspaceRoot)
        let file = URL(fileURLWithPath: root).appendingPathComponent("guide.pdf")
        try Data("fixture attachment".utf8).write(to: file)
        let result = WorkerResultEnvelope(schemaVersion: 1, kind: "worker_result", status: .completed,
            summary: "Saved guide", userQuestion: nil,
            artifacts: [.init(id: "guide", path: file.path, caption: "**Your guide**", mimeType: "application/pdf")])
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["**Ready.** See [source](https://example.com)."],"attachments":[{"artifactID":"guide","caption":"**Guide** with _steps_ and [source](https://example.com)."}]}"#
        try await codex.appendResults([relay, String(decoding: JSONEncoder().encode(result), as: UTF8.self), plan])
        await gateway.start(); await gateway.receive(inbound("readable-guide"))
        try await eventually { try await store.queueState("inbound:readable-guide") == "completed" }
        let sent = await messages.sent, captions = await messages.attachmentCaptions
        XCTAssertEqual(sent, ["Ready. See source (https://example.com).", file.path])
        XCTAssertEqual(captions, ["Guide with steps and source (https://example.com)."])
    }

    func testMarkdownDeliveryConvertsOnceUnlessExplicitlyRequested() async throws {
        for (outputExtension, request) in [("pdf", "Send me that guide."), ("md", "Send the guide as Markdown."), ("docx", "Send an editable Word document.")] {
            let wantsMarkdown = outputExtension == "md"
            let (store, gateway, messages, codex) = try await setup([])
            let root = store.databaseURL.deletingLastPathComponent()
            let md = root.appendingPathComponent("guide.md"), pdf = root.appendingPathComponent("guide." + outputExtension)
            try Data("# Guide\nVerified facts".utf8).write(to: md)
            let document = PDFDocument(), page = PDFPage()
            page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
            document.insert(page, at: 0)
            if !wantsMarkdown { XCTAssertTrue(document.write(to: pdf)) }
            func result(_ file: URL) throws -> String {
                String(decoding: try JSONEncoder().encode(WorkerResultEnvelope(schemaVersion: 1, kind: "worker_result", status: .completed, summary: "Verified guide", userQuestion: nil, artifacts: [.init(id: "guide", path: file.path, caption: nil, mimeType: nil)])), as: UTF8.self)
            }
            let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Ready."],"attachments":[{"artifactID":"guide"}]}"#
            try await codex.appendResults([relay, result(md)] + (wantsMarkdown ? [] : [result(pdf)]) + [plan])
            await gateway.start(); await gateway.receive(inbound("format", text: request))
            try await eventually { try await store.queueState("inbound:format") == "completed" }
            let sent = await messages.sent, inputs = await codex.inputs
            XCTAssertEqual(sent, ["Ready.", wantsMarkdown ? md.path : pdf.path])
            XCTAssertEqual(inputs.count, wantsMarkdown ? 3 : 4)
            if !wantsMarkdown { XCTAssertTrue(inputs[2].contains("Do not repeat external actions or do new research.")) }
        }
    }

    func testFailedFormatCorrectionDoesNotSendMarkdownOrLoop() async throws {
        for badExtension in ["md", "txt", "pdf", "missing"] {
            let (store, gateway, messages, codex) = try await setup([])
            let root = store.databaseURL.deletingLastPathComponent()
            let md = root.appendingPathComponent("guide.md"), bad = root.appendingPathComponent("bad." + badExtension)
            try Data("# Guide".utf8).write(to: md); try Data("Not a PDF".utf8).write(to: bad)
            func result(_ file: URL?) throws -> String {
                String(decoding: try JSONEncoder().encode(WorkerResultEnvelope(schemaVersion: 1, kind: "worker_result", status: .completed, summary: "Guide ready", userQuestion: nil, artifacts: file.map { [.init(id: "guide", path: $0.path, caption: nil, mimeType: nil)] } ?? [])), as: UTF8.self)
            }
            try await codex.appendResults([relay, result(md), result(badExtension == "missing" ? nil : bad)])
            await gateway.start(); await gateway.receive(inbound("format-failed", text: "Send me the guide."))
            try await eventually { try await store.queueState("inbound:format-failed") == "uncertain" }
            let sent = await messages.sent, turns = await codex.turns
            XCTAssertFalse(sent.contains(md.path)); XCTAssertFalse(sent.contains(bad.path)); XCTAssertEqual(turns, 3)
        }
    }

    func testMarkdownPendingComputerPromotionIsNotConvertedInBackground() async throws {
        let (store, gateway, messages, codex) = try await setup([])
        let root = store.databaseURL.deletingLastPathComponent(), md = root.appendingPathComponent("guide.md")
        try Data("# Guide".utf8).write(to: md)
        let pending = String(decoding: try JSONEncoder().encode(WorkerResultEnvelope(schemaVersion: 1, kind: "worker_result", status: .needsComputer, summary: "Need file tools to finish", userQuestion: nil, artifacts: [.init(id: "guide", path: md.path, caption: nil, mimeType: nil)])), as: UTF8.self)
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done."]}"#
        await codex.appendResults([relay.replacingOccurrences(of: "computer", with: "background"), pending, worker, plan])
        await gateway.start(); await gateway.receive(inbound("promote-format"))
        try await eventually { try await store.queueState("inbound:promote-format") == "completed" }
        let inputs = await codex.inputs, tasks = try await store.operatorTasks(), sent = await messages.sent
        XCTAssertEqual(inputs.count, 4); XCTAssertTrue(inputs[2].contains("Continue your same task"))
        XCTAssertEqual(tasks.first?.mode, .computer); XCTAssertFalse(sent.contains(md.path))
    }
    func testNativeCaptureRequiresExplicitSelectionAndCurrentTurnEvidence() async throws {
        let (store, gateway, _, _) = try await setup([])
        let root = store.databaseURL.deletingLastPathComponent()
        let first = root.appendingPathComponent("first.png"), last = root.appendingPathComponent("last.jpg")
        try Data([1]).write(to: first); try Data([2]).write(to: last)
        let selected = WorkerResultEnvelope(schemaVersion: 1, kind: "worker_result", status: .completed, summary: "Observed screenshot", userQuestion: nil,
            artifacts: [.init(id: "shot", path: AgentProtocol.lastNativeCapture, caption: "Final task state", mimeType: nil)])
        XCTAssertNoThrow(try selected.validate())
        let artifacts = try await gateway.verifiedArtifacts(from: selected, workspace: root.path, nativeCapturePaths: [first.path, last.path])
        XCTAssertEqual(artifacts.map(\.path), [last.resolvingSymlinksInPath().path])
        XCTAssertEqual(artifacts.first?.mimeType, "image/jpeg")
        let empty = WorkerResultEnvelope(schemaVersion: 1, kind: "worker_result", status: .completed, summary: "No image requested", userQuestion: nil, artifacts: [])
        let unselected = try await gateway.verifiedArtifacts(from: empty, workspace: root.path, nativeCapturePaths: [last.path])
        XCTAssertTrue(unselected.isEmpty)
        do {
            _ = try await gateway.verifiedArtifacts(from: selected, workspace: root.path)
            XCTFail("A missing current-turn capture must not select a workspace image")
        } catch {}
        let outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
        try Data([3]).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        do {
            _ = try await gateway.verifiedArtifacts(from: selected, workspace: root.path, nativeCapturePaths: [outside.path])
            XCTFail("Capture selection must preserve the workspace boundary")
        } catch {}
        let invalidReference = WorkerResultEnvelope(schemaVersion: 1, kind: "worker_result", status: .completed, summary: "Invalid", userQuestion: nil,
            artifacts: [.init(id: "shot", path: "steve-capture:other", caption: nil, mimeType: nil)])
        XCTAssertThrowsError(try invalidReference.validate())
    }
    func testPauseCancelsWorkerAndSharesPersistedState() async throws {
        let (store, gateway, messages, codex) = try await setup([relay, worker])
        await codex.hold(); await gateway.start(); await gateway.receive(inbound("held"))
        try await eventually { await codex.turns == 2 }
        await gateway.receive(inbound("stop", text: "pause"))
        let paused = await gateway.isPaused(), persisted = try await store.paused()
        XCTAssertTrue(paused); XCTAssertTrue(persisted)
        try await eventually { await messages.sent.count == 1 }
        let state = try await store.queueState("inbound:held"), turns = await codex.turns
        let uncertain = try await store.uncertainWorkCount()
        XCTAssertEqual(uncertain, 0)
        XCTAssertEqual(state, "interrupted"); XCTAssertEqual(turns, 2)
        await gateway.receive(inbound("resume", text: "resume"))
        let resumed = await gateway.isPaused(); XCTAssertFalse(resumed)
    }
    func testRevocationCancelsWorkerWithoutDelivery() async throws {
        let (store, gateway, messages, codex) = try await setup([relay, worker])
        await codex.hold(); await gateway.start(); await gateway.receive(inbound("revoke"))
        try await eventually { await codex.turns == 2 }
        await gateway.beginBoundaryChange(); try await store.saveTrustedConversation(nil); await gateway.endBoundaryChange()
        let state = try await store.queueState("inbound:revoke"), sent = await messages.sent
        XCTAssertEqual(state, "interrupted"); XCTAssertTrue(sent.isEmpty)
    }
    func testWatcherRetriesAndStopEndsRetryLoop() async throws {
        let (_, gateway, messages, _) = try await setup([])
        await messages.configure(failWatch: true); await gateway.start()
        try await eventually { await messages.watchCount >= 2 }
        let error = await gateway.transportError; XCTAssertEqual(error, "fixture offline")
        await gateway.stop(); let count = await messages.watchCount
        try await Task.sleep(for: .milliseconds(40))
        let after = await messages.watchCount; XCTAssertEqual(after, count)
    }
    func testStaleGenerationCannotStageOutput() async throws {
        let (store, _, _, _) = try await setup([])
        try await store.saveGatewayEpoch("old")
        try await store.invalidateWork(cancelQueued: true, epoch: "new")
        do { try await store.stageDelivery([], inboxGUIDs: [], expectedEpoch: "old"); XCTFail("Stale generation accepted") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    func testPendingOutboxRestartsWithoutExecutingWorker() async throws {
        let (store, gateway, messages, codex) = try await setup([])
        let message = inbound("restored")
        _ = try await store.acceptInbound(message); _ = try await store.claimInbox([message.guid])
        let part = SteveStore.OutboundPart(id: "restored-part", chatGuid: "chat", recipient: message.senderHandle, replyTo: message.guid, inboxGUIDs: [message.guid], text: "Saved result", attachmentPath: nil, workspace: nil, permission: nil)
        try await store.stageDelivery([part], inboxGUIDs: [message.guid])
        await gateway.start()
        try await eventually { try await store.queueState("restored-part") == "sent" }
        let turns = await codex.turns, sent = await messages.sent
        XCTAssertEqual(turns, 0); XCTAssertEqual(sent, ["Saved result"])
    }
    func testAmbiguousTransportFailureIsNotRetried() async throws {
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["First","Second"],"attachments":[]}"#
        let (store, gateway, messages, _) = try await setup([relay, worker, plan])
        await messages.configure(failSend: true); await gateway.start(); await gateway.receive(inbound("ambiguous"))
        try await eventually { try await store.uncertainWorkCount() > 0 }
        await gateway.receive(inbound("status-after", text: "status"))
        try await Task.sleep(for: .milliseconds(50))
        let sent = await messages.sent
        XCTAssertEqual(sent.filter { $0 == "First" }.count, 1)
        XCTAssertFalse(sent.contains("Second"))
    }
    func testDeliveryRecoveryNeverReexecutesWorker() async throws {
        let plan = #"{"schemaVersion":1,"kind":"delivery_plan","status":"failed","messages":[],"attachments":[],"recovery":{"action":"fresh","reason":"try again"}}"#
        let (store, gateway, messages, codex) = try await setup([relay, worker, plan])
        await gateway.start(); await gateway.receive(inbound("recovery"))
        try await eventually { try await store.queueState("inbound:recovery") == "uncertain" }
        let turns = await codex.turns, sent = await messages.sent
        XCTAssertEqual(turns, 3); XCTAssertFalse(sent.contains("Success"))
    }
    func testRemovedAttachmentQuarantinesEntirePlanBeforeText() async throws {
        let (store, gateway, messages, _) = try await setup([])
        let message = inbound("removed")
        let settings = try await store.getSettings()!
        _ = try await store.acceptInbound(message); _ = try await store.claimInbox([message.guid])
        let text = SteveStore.OutboundPart(id: "removed-text", chatGuid: "chat", recipient: message.senderHandle, replyTo: message.guid, inboxGUIDs: [message.guid], text: "Success", attachmentPath: nil, workspace: settings.workspaceRoot, permission: "workspace-write")
        let file = SteveStore.OutboundPart(id: "removed-file", chatGuid: "chat", recipient: message.senderHandle, replyTo: message.guid, inboxGUIDs: [message.guid], text: "", attachmentPath: settings.workspaceRoot! + "/missing.pdf", workspace: settings.workspaceRoot, permission: "workspace-write")
        try await store.stageDelivery([text, file], inboxGUIDs: [message.guid])
        await gateway.start()
        try await eventually { try await store.queueState("removed-text") == "failed" }
        await gateway.receive(inbound("next-status", text: "status"))
        try await eventually { await messages.sent.count == 2 }
        let sent = await messages.sent
        XCTAssertFalse(sent.contains("Success")); XCTAssertEqual(sent[1], "History: 1 earlier request failed.")
    }
    func testUncertainWorkerGetsOneDurableNoticeWithoutClearingUncertainty() async throws {
        let (store, gateway, messages, _) = try await setup([relay, "malformed"])
        await gateway.start(); await gateway.receive(inbound("notice"))
        try await eventually { try await store.operatorTasks(chatGuid: "chat").first?.state == .uncertain }
        let tasks = try await store.operatorTasks(chatGuid: "chat")
        let task = try XCTUnwrap(tasks.first)
        try await eventually { try await store.queueState("outcome:\(task.runID)") == "sent" }
        let state = try await store.queueState("inbound:notice"), sent = await messages.sent
        XCTAssertEqual(state, "uncertain"); XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(sent[0].contains("nothing was retried"))
    }
    func testStatusDeliversWhileWorkerIsSuspended() async throws {
        let (_, gateway, messages, codex) = try await setup([relay, worker])
        await codex.hold(); await gateway.start(); await gateway.receive(inbound("busy"))
        try await eventually { await codex.turns == 2 }
        await gateway.receive(inbound("status-during-work", text: "status"))
        try await eventually { await messages.sent.count == 1 }
        let sent = await messages.sent, turns = await codex.turns
        XCTAssertTrue(sent[0].contains("working")); XCTAssertEqual(turns, 2)
    }
    func testStatusSeparatesHistoricalFailuresWithoutChangingTheirRecords() async throws {
        let (store, gateway, messages, codex) = try await setup([])
        for index in 1...4 {
            let old = inbound("past-failure-\(index)")
            _ = try await store.acceptInbound(old)
            _ = try await store.claimInbox([old.guid])
            try await store.finishInbox([old.guid], state: "failed")
        }
        await gateway.start()
        try await eventually { await gateway.transportError == nil }
        await gateway.receive(inbound("current-status", text: "status"))
        try await eventually { await messages.sent.count == 2 }
        let sent = await messages.sent
        XCTAssertEqual(sent, ["Steve is ready. Nothing is waiting.", "History: 4 earlier requests failed."])
        let counts = try await store.workCounts(excludingGUID: "current-status")
        let turns = await codex.turns
        XCTAssertEqual(counts.failed, 4, "Status must preserve failure history, not erase or retry it")
        XCTAssertEqual(counts.pending, 0)
        XCTAssertEqual(turns, 0)
    }
    func testStatusKeepsUnconfirmedWorkVisibleAsNeedingAttention() async throws {
        let (store, gateway, messages, codex) = try await setup([])
        let uncertain = inbound("unconfirmed")
        _ = try await store.acceptInbound(uncertain)
        _ = try await store.claimInbox([uncertain.guid])
        try await store.finishInbox([uncertain.guid], state: "uncertain")
        await gateway.start()
        try await eventually { await gateway.transportError == nil }
        await gateway.receive(inbound("review-status", text: "status"))
        try await eventually { await messages.sent.count == 1 }
        let sent = await messages.sent
        XCTAssertTrue(sent[0].hasPrefix("Steve needs attention."))
        XCTAssertTrue(sent[0].contains("needs review"))
        XCTAssertFalse(sent[0].contains("Nothing is waiting."))
        let outcome = try await store.queueState("inbound:unconfirmed")
        let turns = await codex.turns
        XCTAssertEqual(outcome, "uncertain")
        XCTAssertEqual(turns, 0)
    }
    func testConnectionSetupRejectsApprovalAndKeepsURLLocalUntilExplicitHandoff() async throws {
        let (store, gateway, messages, codex) = try await setup([relay, worker])
        await codex.askConnectionSetup(); await codex.hold(); await gateway.start(); await gateway.receive(inbound("connect"))
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let pending = await gateway.pendingApproval()!
        XCTAssertTrue(pending.requiresConnectionSetup)
        let encoded = String(decoding: try JSONEncoder().encode(pending), as: UTF8.self)
        XCTAssertFalse(encoded.contains("token=secret")); XCTAssertFalse(encoded.contains("https://"))
        let sent = await messages.sent.joined()
        XCTAssertTrue(sent.contains("Connection setup required")); XCTAssertFalse(sent.contains("reconnected ")); XCTAssertFalse(sent.contains("dismiss ")); XCTAssertFalse(sent.contains("Reply approve")); XCTAssertFalse(sent.contains("token=secret"))
        await gateway.receive(inbound("yes-connect", text: "yes"))
        await gateway.receive(inbound("approve-connect", text: "approve " + pending.id))
        let decision = await codex.approvalDecision; XCTAssertNil(decision)
        do { try await gateway.resolveApproval(id: pending.id, decision: .accept); XCTFail("Accepted OAuth as permission") } catch {}
        try await gateway.openConnectionSetup(id: pending.id) { url in
            XCTAssertEqual(url.host, "chatgpt.com")
            return true
        }
        let active = await codex.activeTurns, isPaused = try await store.paused()
        XCTAssertEqual(active, 0); XCTAssertTrue(isPaused)
        try await eventually { await codex.approvalDecision == .cancel }
        do { try await gateway.openConnectionSetup(id: pending.id) { _ in XCTFail("Stale opener invoked"); return false }; XCTFail("Reused old URL") } catch {}
        await gateway.stop()
    }
    func testConnectionSetupPhoneTakeoverAndExistingPauseCancelWithoutVerification() async throws {
        let (_, gateway, _, codex) = try await setup([relay, worker])
        await codex.askConnectionSetup(); await gateway.start(); await gateway.receive(inbound("connect-phone"))
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let id = await gateway.pendingApproval()!.id
        _ = try await gateway.beginPhoneTakeover()
        let decision = await codex.approvalDecision; XCTAssertEqual(decision, .cancel)
        do { try await gateway.openConnectionSetup(id: id) { _ in XCTFail("Stale opener invoked"); return false }; XCTFail("URL survived takeover") } catch {}
        await gateway.stop()
        let (_, other, messages, otherCodex) = try await setup([relay, worker])
        await otherCodex.askConnectionSetup(); await other.start(); await other.receive(inbound("manual-connect"))
        try await eventually { await other.pendingApproval()?.promptDelivered == true }
        let otherID = await other.pendingApproval()!.id
        await other.receive(inbound("pause-connect", text: "/stop"))
        try await eventually { await otherCodex.approvalDecision == .cancel }
        try await eventually { await messages.sent.joined().contains("Steve is paused") }
        do { try await other.openConnectionSetup(id: otherID) { _ in XCTFail("Stale opener invoked"); return false }; XCTFail("URL survived pause") } catch {}
        await other.stop()
    }

    func testConnectionOpenerHoldsPauseUntilSynchronousOpenFinishes() async throws {
        let (store, gateway, _, codex) = try await setup([relay, worker])
        await codex.askConnectionSetup(); await gateway.start(); await gateway.receive(inbound("opening"))
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let id = await gateway.pendingApproval()!.id
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let resumeStarted = DispatchSemaphore(value: 0), resumed = DispatchSemaphore(value: 0)
        let opening = Task {
            try await gateway.openConnectionSetup(id: id) { _ in
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
                return true
            }
        }
        defer { release.signal() }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let resuming = Task {
            resumeStarted.signal()
            try await gateway.setPaused(false)
            resumed.signal()
        }
        XCTAssertEqual(resumeStarted.wait(timeout: .now() + 3), .success)
        XCTAssertEqual(resumed.wait(timeout: .now() + 0.05), .timedOut)
        let paused = try await store.paused(); XCTAssertTrue(paused)
        release.signal()
        try await opening.value; try await resuming.value
        let after = try await store.paused(); XCTAssertFalse(after)
        await gateway.stop()
    }
    func testQueuedConnectionOpenerIsCancelledByResumeOrRevocation() async throws {
        for revoke in [false, true] {
            let (store, gateway, _, codex) = try await setup([relay, worker])
            await codex.askConnectionSetup(); await gateway.start(); await gateway.receive(inbound("queued-opening"))
            try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
            let id = await gateway.pendingApproval()!.id
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let blocker = Task { @MainActor in
                entered.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
            defer { release.signal() }
            XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
            let opening = Task {
                try await gateway.openConnectionSetup(id: id) { _ in XCTFail("Invalidated opener ran"); return true }
            }
            try await eventually { (try? await store.paused()) == true }
            if revoke { await gateway.beginBoundaryChange() }
            else { try await gateway.setPaused(false) }
            release.signal(); await blocker.value
            do { try await opening.value; XCTFail("Invalidated handoff succeeded") } catch {}
            await gateway.stop()
        }
    }

    func testConnectionSetupDoesNotSwallowConcurrentOrdinaryApproval() async throws {
        let (_, gateway, messages, codex) = try await setup([relay, worker])
        await codex.askConnectionSetup(); await gateway.start(); await gateway.receive(inbound("concurrent-connect"))
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let other = Task { await codex.requestConcurrentOrdinaryApproval() }
        try await eventually { await messages.sent.contains(where: { $0.contains("Reply yes or no.") }) }
        await gateway.receive(inbound("concurrent-accept", text: "yes"))
        let decision = await other.value
        XCTAssertEqual(decision, .accept)
        let setupDecision = await codex.approvalDecision
        XCTAssertNil(setupDecision)
        await gateway.stop()
    }

    func testBoundApprovalPromptDeliversAndPairedYesResolvesOnce() async throws {
        let (_, gateway, messages, codex) = try await setup([relay, worker])
        await codex.askApproval(); await gateway.start(); await gateway.receive(inbound("approval-task"))
        try await eventually { await gateway.pendingApproval() != nil }
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let prompt = await messages.sent.joined()
        XCTAssertFalse(prompt.contains("token=secret")); XCTAssertTrue(prompt.contains("example.test"))
        XCTAssertTrue(prompt.contains("Reply yes or no."))
        XCTAssertFalse(prompt.contains("Reply approve "))
        let pending = await gateway.pendingApproval()!
        await gateway.receive(inbound("approval-yes", text: "yes"))
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision, remaining = await gateway.pendingApproval()
        XCTAssertEqual(decision, .accept); XCTAssertNil(remaining)
        do { try await gateway.resolveApproval(id: pending.id, decision: .accept); XCTFail("Approval resolved twice") } catch {}
    }
    func testFullAccessAutomaticallyAllowsOnlyRoutineAppAndWebsiteAccess() async throws {
        for native in [true, false] {
            let (store, gateway, messages, codex) = try await setup([relay, worker])
            var settings = try await store.getSettings()!
            settings.permissionProfile = ":danger-full-access"
            try await store.saveSettings(settings)
            if native { await codex.askNativeApproval() } else { await codex.askBrowserApproval() }
            await gateway.start(); await gateway.receive(inbound("routine-access"))
            try await eventually { await codex.approvalDecision != nil }
            let decision = await codex.approvalDecision, pending = await gateway.pendingApproval(), sent = await messages.sent
            XCTAssertEqual(decision, .accept)
            XCTAssertNil(pending)
            XCTAssertFalse(sent.joined().contains("Reply yes or no."))
        }
    }
    func testFullAccessStillRequiresHumanForURLAndAccountConnection() async throws {
        for connection in [true, false] {
            let (store, gateway, _, codex) = try await setup([relay, worker])
            var settings = try await store.getSettings()!
            settings.permissionProfile = "danger-full-access"
            try await store.saveSettings(settings)
            if connection { await codex.askConnectionSetup() } else { await codex.askApproval() }
            await gateway.start(); await gateway.receive(inbound("human-access"))
            try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
            let decision = await codex.approvalDecision
            XCTAssertNil(decision)
            await gateway.stop()
        }
    }
    func testFullAccessRejectsMismatchedRoutineRequest() async throws {
        let (store, gateway, _, codex) = try await setup([relay, worker])
        var settings = try await store.getSettings()!
        settings.permissionProfile = "danger-full-access"
        try await store.saveSettings(settings)
        await codex.askNativeApproval(mismatch: true)
        await gateway.start(); await gateway.receive(inbound("mismatched-full-access"))
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision
        XCTAssertEqual(decision, .cancel)
    }
    func testConcurrentApprovalsArePresentedOneAtATimeAndStaleYesCannotMoveOn() async throws {
        let (_, gateway, messages, codex) = try await setup([relay, worker])
        await codex.askApproval(); await codex.hold()
        await gateway.start(); await gateway.receive(inbound("parallel-access"))
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let first = await gateway.pendingApproval()!
        let second = Task { await codex.requestConcurrentOrdinaryApproval() }
        // The second request is queued but the first remains the only prompt.
        try await Task.sleep(for: .milliseconds(30))
        let before = await messages.sent.filter { $0.contains("Reply yes or no.") }
        XCTAssertEqual(before.count, 1)
        await gateway.receive(inbound("first-yes", text: "yes"))
        try await eventually {
            let pending = await gateway.pendingApproval()
            return pending?.id != first.id && pending?.promptDelivered == true
        }
        var stale = inbound("late-first-yes", text: "yes")
        stale.approvalID = first.id
        await gateway.receive(stale)
        let stillPending = await gateway.pendingApproval()
        XCTAssertNotNil(stillPending)
        await gateway.receive(inbound("second-no", text: "no"))
        let decision = await second.value
        XCTAssertEqual(decision, .decline)
        await gateway.stop()
    }
    func testNativeAppApprovalUsesSessionScopeAndWaitsForExplicitDecision() async throws {
        let (_, gateway, _, codex) = try await setup([relay, worker])
        await codex.askNativeApproval(); await gateway.start(); await gateway.receive(inbound("native-app-task"))
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let before = await codex.approvalDecision, pending = await gateway.pendingApproval()!
        XCTAssertNil(before); XCTAssertNil(pending.originHost)
        XCTAssertEqual(pending.message, "Can I use TextEdit for this task?")
        try await gateway.resolveApproval(id: pending.id, decision: .accept)
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision; XCTAssertEqual(decision, .accept)
    }
    func testNativeAppApprovalRevocationAndThreadMismatchCancel() async throws {
        let (_, gateway, _, codex) = try await setup([relay, worker])
        await codex.askNativeApproval(); await gateway.start(); await gateway.receive(inbound("native-app-revoke"))
        try await eventually { await gateway.pendingApproval() != nil }
        await gateway.beginBoundaryChange()
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision; XCTAssertEqual(decision, .cancel)
        let (_, other, _, otherCodex) = try await setup([relay, worker])
        await otherCodex.askNativeApproval(mismatch: true); await other.start(); await other.receive(inbound("native-app-mismatch"))
        try await eventually { await otherCodex.approvalDecision != nil }
        let mismatch = await otherCodex.approvalDecision; XCTAssertEqual(mismatch, .cancel)
        let pending = await other.pendingApproval(); XCTAssertNil(pending)
    }
    func testBrowserOriginFormWaitsForExplicitBoundDecision() async throws {
        let (_, gateway, _, codex) = try await setup([relay, worker])
        await codex.askBrowserApproval(); await gateway.start(); await gateway.receive(inbound("browser-origin-task"))
        try await eventually { await gateway.pendingApproval()?.promptDelivered == true }
        let before = await codex.approvalDecision
        XCTAssertNil(before)
        let pending = await gateway.pendingApproval()!
        try await gateway.resolveApproval(id: pending.id, decision: .accept)
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision
        XCTAssertEqual(decision, .accept)
    }
    func testCapturePermitClosesOnPauseTakeoverAndBoundaryChange() async throws {
        let (_, gateway, _, _) = try await setup([])
        await gateway.start()
        let video = try await gateway.authorizeVideo()
        XCTAssertTrue(gateway.capturePermit.allows(video.token, kind: .video))
        try await gateway.setPaused(true)
        XCTAssertFalse(gateway.capturePermit.allows(video.token, kind: .video))
        let phone = try await gateway.beginPhoneTakeover()
        XCTAssertTrue(gateway.capturePermit.allows(phone, kind: .phone))
        do { _ = try await gateway.authorizeVideo(); XCTFail("Video allowed during phone control") } catch {}
        await gateway.beginBoundaryChange()
        XCTAssertFalse(gateway.capturePermit.allows(phone, kind: .phone))
    }
    func testApprovalExpiresAndUnsupportedFormsAreCancelled() async throws {
        let (_, gateway, _, codex) = try await setup([relay, worker])
        await codex.askApproval(duration: 0.05); await gateway.start(); await gateway.receive(inbound("expiry-task"))
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision, pending = await gateway.pendingApproval()
        XCTAssertEqual(decision, .cancel); XCTAssertNil(pending)
        let (_, formGateway, _, formCodex) = try await setup([relay, worker])
        await formCodex.askApproval(mode: "form"); await formGateway.start(); await formGateway.receive(inbound("form-task"))
        try await eventually { await formCodex.approvalDecision != nil }
        let formDecision = await formCodex.approvalDecision, formPending = await formGateway.pendingApproval()
        XCTAssertEqual(formDecision, .cancel); XCTAssertNil(formPending)
    }
    func testApprovalRevocationCancelsContinuationAndMismatchedThreadCancels() async throws {
        let (store, gateway, _, codex) = try await setup([relay, worker])
        await codex.askApproval(); await gateway.start(); await gateway.receive(inbound("revoke-approval"))
        try await eventually { await gateway.pendingApproval() != nil }
        let approval = await gateway.pendingApproval()!
        await gateway.beginBoundaryChange(); try await store.saveTrustedConversation(nil); await gateway.endBoundaryChange()
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision
        XCTAssertEqual(decision, .cancel)
        do { try await gateway.resolveApproval(id: approval.id, decision: .accept); XCTFail("Revoked approval accepted") } catch {}
        let (_, mismatchGateway, _, mismatchCodex) = try await setup([relay, worker])
        await mismatchCodex.askApproval(mismatch: true); await mismatchGateway.start(); await mismatchGateway.receive(inbound("mismatch"))
        try await eventually { await mismatchCodex.approvalDecision != nil }
        let mismatchDecision = await mismatchCodex.approvalDecision
        XCTAssertEqual(mismatchDecision, .cancel)
    }
    func testStopCancelsApprovalBeforeWaitingForWatcherShutdown() async throws {
        let (_, gateway, messages, codex) = try await setup([relay, worker])
        await messages.holdWatcher()
        defer { Task { await messages.releaseWatcher() } }
        await codex.askApproval(); await gateway.start(); await gateway.receive(inbound("shutdown-approval"))
        try await eventually { await gateway.pendingApproval() != nil }
        let approval = await gateway.pendingApproval()!
        let stopping = Task { await gateway.stop() }
        try await eventually { await codex.approvalDecision != nil }
        let decision = await codex.approvalDecision
        XCTAssertEqual(decision, .cancel)
        do { try await gateway.resolveApproval(id: approval.id, decision: .accept); XCTFail("Shutdown accepted an approval") } catch {}
        await messages.releaseWatcher()
        await stopping.value
    }

    func testRestartDoesNotExecutePersistedApprovalReply() async throws {
        let (store, gateway, messages, codex) = try await setup([])
        var message = inbound("stale-yes", text: "yes")
        message.approvalID = "expired-id"
        _ = try await store.acceptInbound(message)
        await gateway.start()
        try await eventually { await messages.sent.count == 1 }
        let turns = await codex.turns, sent = await messages.sent
        XCTAssertEqual(turns, 0); XCTAssertTrue(sent[0].contains("expired"))
    }
    func testGracefulStopPreservesUnsentOutputButRevocationCancelsIt() async throws {
        let (store, _, _, _) = try await setup([])
        let message = inbound("graceful-stop")
        _ = try await store.acceptInbound(message); _ = try await store.claimInbox([message.guid])
        let part = SteveStore.OutboundPart(id: "unsent", chatGuid: "chat", recipient: message.senderHandle, replyTo: message.guid, inboxGUIDs: [message.guid], text: "Saved result", attachmentPath: nil, workspace: nil, permission: nil)
        try await store.stageDelivery([part], inboxGUIDs: [message.guid])
        try await store.invalidateWork(cancelQueued: false, epoch: "stopped")
        let stopped = try await store.pendingOutbox()
        XCTAssertEqual(stopped, [part])
        try await store.recoverInterruptedWork()
        let restarted = try await store.pendingOutbox()
        XCTAssertEqual(restarted, [part])
        try await store.invalidateWork(cancelQueued: true, epoch: "revoked")
        let revoked = try await store.pendingOutbox(), state = try await store.queueState("unsent")
        XCTAssertTrue(revoked.isEmpty); XCTAssertEqual(state, "cancelled")
    }
    func testBareYesCannotApprovePromptThatWasNotDelivered() async throws {
        let (_, gateway, messages, codex) = try await setup([relay, worker])
        await messages.holdDelivery(); await codex.askApproval(); await gateway.start(); await gateway.receive(inbound("unseen-approval"))
        try await eventually { await gateway.pendingApproval() != nil }
        await gateway.receive(inbound("unrelated-yes", text: "yes"))
        let before = await codex.approvalDecision
        XCTAssertNil(before)
        await messages.releaseDelivery()
        try await eventually { await messages.sent.contains { $0.contains("Reply yes or no.") } }
        let after = await codex.approvalDecision
        XCTAssertNil(after)
        let pending = await gateway.pendingApproval()!
        try await gateway.resolveApproval(id: pending.id, decision: .decline)
        try await eventually { await codex.approvalDecision != nil }
        let final = await codex.approvalDecision
        XCTAssertEqual(final, .decline)
    }
    func testFailedApprovalPromptDoesNotEnableBareYesAndInvalidOriginCancels() async throws {
        let (store, gateway, messages, codex) = try await setup([relay, worker])
        await messages.configure(failSend: true); await codex.askApproval(); await gateway.start(); await gateway.receive(inbound("failed-prompt"))
        try await eventually { try await store.uncertainWorkCount() > 0 }
        await gateway.receive(inbound("yes-after-failure", text: "yes"))
        let decision = await codex.approvalDecision
        XCTAssertEqual(decision, .cancel)
        await gateway.stop()
        let (_, invalidGateway, _, invalidCodex) = try await setup([relay, worker])
        await invalidCodex.askApproval(); await invalidCodex.setApprovalOrigin("javascript:alert(1)")
        await invalidGateway.start(); await invalidGateway.receive(inbound("invalid-origin"))
        try await eventually { await invalidCodex.approvalDecision != nil }
        let invalid = await invalidCodex.approvalDecision, pending = await invalidGateway.pendingApproval()
        XCTAssertEqual(invalid, .cancel); XCTAssertNil(pending)
    }
    func testPhoneLinkCannotClaimAfterBoundaryChanges() async throws {
        let (store, gateway, _, _) = try await setup([])
        await gateway.start()
        let first = try await gateway.phoneAccessBoundary()
        await gateway.beginBoundaryChange()
        await gateway.endBoundaryChange()
        do { _ = try await gateway.beginPhoneTakeover(expectedBoundary: first); XCTFail("Old link acquired a new epoch") } catch {}
        let pausedAfterOldLink = await gateway.isPaused()
        XCTAssertFalse(pausedAfterOldLink)

        let second = try await gateway.phoneAccessBoundary()
        var settings = try await store.getSettings()!
        settings.permissionProfile = "read-only"
        try await store.saveSettings(settings)
        do { _ = try await gateway.beginPhoneTakeover(expectedBoundary: second); XCTFail("Link ignored a changed permission") } catch {}
        let pausedAfterPermissionChange = await gateway.isPaused()
        XCTAssertFalse(pausedAfterPermissionChange)

        let current = try await gateway.phoneAccessBoundary()
        let lease = try await gateway.beginPhoneTakeover(expectedBoundary: current)
        let active = await gateway.phoneTakeoverIsActive(token: lease)
        XCTAssertTrue(active)
        try await gateway.endPhoneTakeover(token: lease, resume: true)
    }

    func testTakeoverDrainsWorkerAndBlocksResumeUntilExplicitFinish() async throws {
        let (store, gateway, messages, codex) = try await setup([relay, worker])
        await codex.hold(); await gateway.start(); await gateway.receive(inbound("takeover-task"))
        try await eventually { await codex.turns == 2 }
        let token = try await gateway.beginPhoneTakeover()
        let active = await gateway.phoneTakeoverIsActive(token: token), paused = await gateway.isPaused(), remaining = await codex.activeTurns
        XCTAssertTrue(active); XCTAssertTrue(paused); XCTAssertEqual(remaining, 0)
        do { try await gateway.setPaused(false); XCTFail("CLI resume bypassed takeover") } catch {}
        await gateway.receive(inbound("takeover-resume", text: "resume"))
        try await eventually { await messages.sent.contains { $0.contains("Finish phone control") } }
        let stillPaused = await gateway.isPaused(), state = try await store.queueState("inbound:takeover-task")
        XCTAssertTrue(stillPaused); XCTAssertEqual(state, "interrupted")
        try await gateway.endPhoneTakeover(token: token, resume: true)
        let after = await gateway.phoneTakeoverIsActive(token: token), resumed = await gateway.isPaused(), turns = await codex.turns
        XCTAssertFalse(after); XCTAssertFalse(resumed); XCTAssertEqual(turns, 2)
    }
    func testTakeoverStopRevokesTokenAndLeavesPaused() async throws {
        let (_, gateway, _, _) = try await setup([])
        await gateway.start(); let token = try await gateway.beginPhoneTakeover()
        await gateway.receive(inbound("takeover-stop", text: "stop"))
        let active = await gateway.phoneTakeoverIsActive(token: token), paused = await gateway.isPaused()
        XCTAssertFalse(active); XCTAssertTrue(paused)
        do { try await gateway.endPhoneTakeover(token: token, resume: true); XCTFail("Stale finish resumed") } catch {}
        let stillPaused = await gateway.isPaused(); XCTAssertTrue(stillPaused)
    }
    func testTakeoverDetectsPairingWorkspaceAndPermissionChanges() async throws {
        let (store, gateway, _, _) = try await setup([])
        await gateway.start(); let token = try await gateway.beginPhoneTakeover()
        var settings = try await store.getSettings()!
        settings.permissionProfile = "read-only"
        try await store.saveSettings(settings)
        let permissionActive = await gateway.phoneTakeoverIsActive(token: token)
        XCTAssertFalse(permissionActive)
        await gateway.beginBoundaryChange(); try await store.saveTrustedConversation(nil); await gateway.endBoundaryChange()
        let revoked = await gateway.phoneTakeoverIsActive(token: token), paused = await gateway.isPaused()
        XCTAssertFalse(revoked); XCTAssertTrue(paused)
    }
    func testTakeoverExpiryAndFinishWithoutResumePreservePause() async throws {
        let (store, gateway, _, _) = try await setup([], takeoverLifetime: 0.05)
        await gateway.start(); let token = try await gateway.beginPhoneTakeover()
        try await eventually { !(await gateway.phoneTakeoverIsActive(token: token)) }
        let paused = await gateway.isPaused(), persisted = try await store.paused()
        XCTAssertTrue(paused); XCTAssertTrue(persisted)
        let second = try await gateway.beginPhoneTakeover()
        try await gateway.endPhoneTakeover(token: second, resume: false)
        let after = await gateway.isPaused(); XCTAssertTrue(after)
        try await gateway.setPaused(false)
        let resumed = await gateway.isPaused(); XCTAssertFalse(resumed)
    }
    func testPhoneAccessSettingsRoundTripAndPortValidation() async throws {
        let (store, _, _, _) = try await setup([])
        try await store.savePhoneAccessOrigin("https://fixture.example.test")
        try await store.savePhoneAccessPort(8787)
        let origin = try await store.phoneAccessOrigin(), port = try await store.phoneAccessPort()
        XCTAssertEqual(origin, "https://fixture.example.test"); XCTAssertEqual(port, 8787)
        do { try await store.savePhoneAccessPort(65536); XCTFail("Invalid port accepted") } catch {}
        try await store.savePhoneAccessOrigin(nil); try await store.savePhoneAccessPort(nil)
        let clearedOrigin = try await store.phoneAccessOrigin(), clearedPort = try await store.phoneAccessPort()
        XCTAssertNil(clearedOrigin); XCTAssertNil(clearedPort)
    }
    func testAccountPrefixesAreNormalized() {
        XCTAssertEqual(MessagesService.normalizedAccountAddress("E:user@example.test"), "user@example.test")
        XCTAssertEqual(MessagesService.normalizedAccountAddress("E:"), "")
        XCTAssertEqual(MessagesService.normalizedAccountAddress("P:+15550000000"), "+15550000000")
    }
    func testSameMessageTimezonePreferenceAppliesToScheduleFallback() async throws {
        let route = #"{"schemaVersion":1,"kind":"relay_request","action":"control","memoryUpdates":[{"operation":"preference_set","key":"timezone","value":"America/Los_Angeles","userQuote":"I'm in Pacific time now"}],"control":{"operation":"schedule_create","userQuote":"remind me every day at 9","schedule":{"name":"Morning check","prompt":"Check in","kind":"reminder","timing":"calendar","hour":9,"minute":0}}}"#
        let (store, gateway, _, _) = try await setup([route], withAutomation: true)
        await gateway.start()
        await gateway.receive(inbound("timezone-schedule", text: "I'm in Pacific time now; remind me every day at 9"))
        try await eventually { try await store.queueState("inbound:timezone-schedule") == "completed" }
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let schedules = try await automation.schedules()
        XCTAssertEqual(schedules.count, 1)
        XCTAssertEqual(schedules.first?.timeZone, "America/Los_Angeles")
        XCTAssertEqual(schedules.first?.rule, .calendar(hour: 9, minute: 0, weekdays: []))
    }

    func testMixedPreferenceAndTaskPreservesExactUserMessage() async throws {
        let route = #"{"schemaVersion":1,"kind":"relay_request","action":"execute","taskTitle":"Dinner","mode":"background","workerPrompt":"Find dinner","memoryUpdates":[{"operation":"preference_set","key":"diet","value":"vegetarian","userQuote":"I'm vegetarian"}]}"#
        let delivery = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Two good options."]}"#
        let (store, gateway, messages, codex) = try await setup([route, worker, delivery], withAutomation: true)
        await gateway.start()
        await gateway.receive(inbound("mixed", text: "I'm vegetarian. Find dinner for Friday in Boston."))
        try await eventually { try await store.queueState("inbound:mixed") == "completed" }
        let input = await codex.inputs
        XCTAssertTrue(input[1].contains("I'm vegetarian. Find dinner for Friday in Boston."))
        XCTAssertTrue(input[1].contains("ORIGINAL_USER_MESSAGES_JSON"))
        XCTAssertTrue(input[1].contains("vegetarian"))
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let preferences = try await automation.preferences()
        XCTAssertEqual(preferences.first?.value, "vegetarian")
        let sent = await messages.sent
        XCTAssertTrue(sent.contains("Two good options."))
        let settings = try await store.getSettings()!
        XCTAssertTrue(try String(contentsOfFile: settings.workspaceRoot! + "/STEVE_MEMORY.md", encoding: .utf8).contains("vegetarian"))
    }

    func testAcknowledgementOnlyOnceAndNeverCompletesOriginalRequest() async throws {
        let (store, gateway, messages, codex) = try await setup([relay, worker], acknowledgementDelay: .milliseconds(25))
        await codex.hold(); await gateway.start(); await gateway.receive(inbound("slow"))
        try await eventually { await messages.sent.contains("I’m on it.") }
        try await Task.sleep(for: .milliseconds(100))
        let sent = await messages.sent
        XCTAssertEqual(sent.filter { $0 == "I’m on it." }.count, 1)
        let state = try await store.queueState("inbound:slow")
        XCTAssertEqual(state, "running")
        await gateway.stop()
    }

    func testPlanDeliveryUsesSavedScheduleRatherThanWorkerPromise() async throws {
        for (end, expected) in [("2026-09-22T12:45:00-04:00", "Next check: 2026-09-21T09:00:00-04:00"),
                                ("2026-09-20T16:00:00-04:00", "No future checks were scheduled")] {
            let clock = FixtureClock(ISO8601DateFormatter().date(from: "2026-09-20T15:00:00-04:00")!)
            let result = """
            {"schemaVersion":1,"kind":"worker_result","status":"completed","summary":"I'll report when it ends.","plan":{"summary":"Monitor lunch changes","state":"active","userQuote":"Watch lunch","endsAt":"\(end)","nextCheckAt":"\(end)"}}
            """
            let delivery = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Confirmed the actual follow-through status."]}"#
            let (store, gateway, _, codex) = try await setup([relay, result, delivery], withAutomation: true, clock: clock)
            var settings = try await store.getSettings()!
            settings.timezone = "America/New_York"
            try await store.saveSettings(settings)
            await gateway.start(); await gateway.receive(inbound("watch-lunch", text: "Watch lunch"))
            try await eventually { try await store.queueState("inbound:watch-lunch") == "completed" }
            let inputs = await codex.inputs
            XCTAssertTrue(inputs.last?.contains("FOLLOW_UP_STATUS (authoritative runtime state") == true)
            XCTAssertTrue(inputs.last?.contains(expected) == true)
            await gateway.stop()
        }
    }

    func testVerifiedLoginOffersBoundLinkAndPageCompletionContinuesSameTask() async throws {
        let blocked = #"{"schemaVersion":1,"kind":"worker_result","status":"blocked","summary":"Sign in to continue.","blocker":{"reason":"sign_in","userAction":"Sign in on the open page.","verification":"Check the account and cart after sign-in.","pageVerified":true}}"#
        let delivery = #"{"schemaVersion":1,"kind":"delivery_plan","status":"failed","messages":["Sign in to continue."]}"#
        let done = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Verified the account and continued."]}"#
        let (store, gateway, messages, codex) = try await setup([relay, blocked, delivery, worker, done])
        let phone = FixturePhoneAccess()
        await gateway.setPhoneAccessHandler { try await phone.issue(for: gateway) }
        await gateway.start(); await gateway.receive(inbound("login", text: "Open my cart."))
        try await eventually { await phone.count == 1 }
        let task = try await store.operatorTasks().first!
        let bound = await phone.boundary
        XCTAssertEqual(bound?.taskID, task.id); XCTAssertEqual(bound?.runID, task.runID)
        let token = try await gateway.beginPhoneTakeover(expectedBoundary: bound)
        let paused = await gateway.isPaused(); XCTAssertTrue(paused)
        try await gateway.endPhoneTakeover(token: token, resume: true)
        try await eventually { await messages.sent.contains("Verified the account and continued.") }
        let tasks = try await store.operatorTasks()
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(tasks.first?.id, task.id)
        let inputs = await codex.inputs
        XCTAssertTrue(inputs.contains { $0.contains("Check the account and cart after sign-in.") && $0.contains("Re-observe") })
        XCTAssertFalse(inputs.contains { $0.contains("private-phone-fixture") })
        let active = await gateway.phoneTakeoverIsActive(token: token); XCTAssertFalse(active)
    }

    func testUnverifiedLoginNeverOffersPhoneLink() async throws {
        let blocked = #"{"schemaVersion":1,"kind":"worker_result","status":"blocked","summary":"Login may be required.","blocker":{"reason":"sign_in","userAction":"Open the page on the Mac.","verification":"Observe the page.","pageVerified":false}}"#
        let delivery = #"{"schemaVersion":1,"kind":"delivery_plan","status":"failed","messages":["Open the page on the Mac."]}"#
        let (store, gateway, _, _) = try await setup([relay, blocked, delivery])
        let phone = FixturePhoneAccess(); await gateway.setPhoneAccessHandler { await phone.issue() }
        await gateway.start(); await gateway.receive(inbound("unverified"))
        try await eventually { try await store.operatorTasks().first?.state == .blocked }
        let count = await phone.count; XCTAssertEqual(count, 0)
    }

    func testOrdinarySignedInReplyReusesBlockedOwner() async throws {
        let blocked = #"{"schemaVersion":1,"kind":"worker_result","status":"blocked","summary":"Sign in.","blocker":{"reason":"sign_in","userAction":"Sign in on the Mac.","verification":"Inspect login state.","pageVerified":true}}"#
        let delivery = #"{"schemaVersion":1,"kind":"delivery_plan","status":"failed","messages":["Sign in on the Mac."]}"#
        let done = #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Continued."]}"#
        let (store, gateway, messages, _) = try await setup([relay, blocked, delivery, worker, done])
        await gateway.start(); await gateway.receive(inbound("login"))
        try await eventually { try await store.operatorTasks().first?.state == .blocked }
        let before = try await store.operatorTasks().first!.id
        await gateway.receive(inbound("signed-in", text: "I'm signed in"))
        try await eventually { await messages.sent.contains("Continued.") }
        let after = try await store.operatorTasks()
        XCTAssertEqual(after.count, 1); XCTAssertEqual(after.first?.id, before)
        XCTAssertEqual(after.first?.state, .completed)
    }

    func testProgressFilteringRejectsSecretsAndInternalContent() {
        for value in ["Still working", "TOKEN: sk-abcdefghijklmnopqrstuvwxyz", "Open HTTPS://example.test", "File /Users/example/private", "user@example.test replied", "thread id 123", "{\"summary\":\"ready\"}", "The code is 123456"] {
            if value == "The code is 123456" { continue } // Ordinary numbers are not categorically credentials.
            XCTAssertNil(ConversationProgress.safeMessage(value), value)
        }
        XCTAssertEqual(ConversationProgress.safeMessage("I found two options within your budget."), "I found two options within your budget.")
    }

    func testCancelledRunningFollowUpProducesNoNotificationOrUncertainFallback() async throws {
        let clock = FixtureClock(ISO8601DateFormatter().date(from: "2026-09-20T13:00:00Z")!)
        let result = #"{"schemaVersion":1,"kind":"worker_result","status":"completed","summary":"There is a change.","notifyUser":true}"#
        let (store, gateway, messages, codex) = try await setup([relay, result], withAutomation: true, clock: clock)
        await codex.hold(); await gateway.start()
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let settings = try await store.getSettings()!
        let boundary = try ScheduleAuthorization(chatGUID: "chat", senderHandle: "user@example.test", workspace: settings.workspaceRoot!, permission: "workspace-write")
        let epoch = try await store.gatewayEpoch()!
        let provenance = ExplicitUserProvenance(source: .pairedMessage, sourceID: "plan", statement: "Track my plan", explicitlyRequested: true, recordedAt: clock.now())
        let plan = WorkerPlanUpdate(summary: "One dated fixture plan", state: .active, userQuote: "Track my plan", endsAt: "2026-09-23T13:00:00Z", nextCheckAt: "2026-09-20T13:00:01Z")
        try await automation.savePlan(taskID: "parent", update: plan, authorization: boundary, provenance: provenance, timeZone: "America/New_York", now: clock.now(), expectedEpoch: epoch)
        clock.advance(1); try await gateway.pollSchedules(now: clock.now())
        try await eventually { await codex.turns == 2 }
        try await automation.cancelPlan(taskID: "parent", provenance: .init(source: .pairedMessage, sourceID: "cancel", statement: "Leave it with me", explicitlyRequested: true, recordedAt: clock.now()), now: clock.now(), expectedEpoch: epoch)
        await codex.releaseWorker()
        try await eventually { try await store.operatorTasks().first?.state == .cancelled }
        let sent = await messages.sent; XCTAssertTrue(sent.isEmpty)
        let runs = try await automation.schedules().first.map { $0.id }
        let outcomes = try await automation.runs(scheduleID: runs!)
        XCTAssertEqual(outcomes.first?.state, .cancelled)
    }

    func testDeferredDeliveryWakesAtInjectedTimeWithoutNewMessage() async throws {
        let clock = FixtureClock()
        let (store, gateway, messages, _) = try await setup([], withAutomation: true, clock: clock)
        await gateway.start()
        let part = SteveStore.OutboundPart(id: "deferred", chatGuid: "chat", recipient: "user@example.test", replyTo: "fixture", inboxGUIDs: [], text: "Morning update", attachmentPath: nil, workspace: nil, permission: nil, notBefore: clock.now().addingTimeInterval(3600))
        try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: try await store.gatewayEpoch())
        try await gateway.pollSchedules(now: clock.now())
        try await Task.sleep(for: .milliseconds(30))
        let before = await messages.sent; XCTAssertTrue(before.isEmpty)
        clock.advance(3601)
        try await gateway.pollSchedules(now: clock.now())
        try await eventually { await messages.sent == ["Morning update"] }
    }

    private func stageFollowUpAcrossQuietHours(
        store: SteveStore,
        gateway: GatewayCoordinator,
        clock: FixtureClock,
        taskID: String,
        endsAt: String
    ) async throws -> (SteveUserAutomationStore, UserScheduleRun, SteveStore.OutboundPart) {
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let settings = try await store.getSettings()!
        let boundary = try ScheduleAuthorization(chatGUID: "chat", senderHandle: "user@example.test", workspace: settings.workspaceRoot!, permission: "workspace-write")
        let epoch = try await store.gatewayEpoch()!
        let provenance = ExplicitUserProvenance(source: .pairedMessage, sourceID: taskID, statement: "Track this plan", explicitlyRequested: true, recordedAt: clock.now())
        let next = ISO8601DateFormatter().string(from: clock.now().addingTimeInterval(1))
        let plan = WorkerPlanUpdate(summary: "One verified fixture check", state: .active, userQuote: "Track this plan", endsAt: endsAt, nextCheckAt: next)
        try await automation.savePlan(taskID: taskID, update: plan, authorization: boundary, provenance: provenance, timeZone: "America/New_York", now: clock.now(), expectedEpoch: epoch)
        clock.advance(1)
        let claimed = try await automation.claimDue(now: clock.now(), authorization: boundary, dispatchEpoch: epoch)
        let run = try XCTUnwrap(claimed.first)
        let accepted = try await store.acceptScheduledRun(id: run.id, expectedEpoch: epoch)
        XCTAssertTrue(accepted)
        _ = try await store.claimInbox(["schedule:" + run.id])
        let part = SteveStore.OutboundPart(id: "follow-up:" + taskID, chatGuid: "chat", recipient: "user@example.test", replyTo: "fixture", inboxGUIDs: [], text: "I couldn't prepare the scheduled update.", attachmentPath: nil, workspace: settings.workspaceRoot, permission: "workspace-write", notBefore: clock.now().addingTimeInterval(60), followUpRunID: run.id)
        try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: epoch)
        try await gateway.pollSchedules(now: clock.now())
        return (automation, run, part)
    }

    func testFollowUpDeliveryRechecksQuietHoursAtSendAndWakesAtMorning() async throws {
        let clock = FixtureClock(ISO8601DateFormatter().date(from: "2026-09-21T01:58:59Z")!) // 9:58:59 PM EDT.
        let (store, gateway, messages, _) = try await setup([], withAutomation: true, clock: clock)
        await gateway.start()
        let (automation, run, part) = try await stageFollowUpAcrossQuietHours(store: store, gateway: gateway, clock: clock, taskID: "morning", endsAt: "2026-09-23T12:00:00-04:00")
        clock.advance(60) // The ready part reaches send-time at 10 PM.
        try await gateway.pollSchedules(now: clock.now())
        try await Task.sleep(for: .milliseconds(30))
        let quietSent = await messages.sent
        XCTAssertTrue(quietSent.isEmpty)
        try await automation.recordOutcome(id: run.id, state: .uncertain, detail: "Fixture delivery outcome needs review.", now: clock.now())
        clock.advance(36_000) // 8 AM EDT.
        for _ in 0..<150 {
            try await gateway.pollSchedules(now: clock.now())
            if await messages.sent == ["I couldn't prepare the scheduled update."] { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        let queueState = try await store.queueState(part.id)
        let runState = try await automation.run(id: run.id)?.state
        XCTFail("Deferred follow-up did not send; queue=\(queueState ?? "missing") run=\(String(describing: runState))")
    }

    func testDeferredFollowUpCancellationAndExpirySuppressDelivery() async throws {
        let cancelledClock = FixtureClock(ISO8601DateFormatter().date(from: "2026-09-21T01:58:59Z")!)
        let (cancelledStore, cancelledGateway, cancelledMessages, _) = try await setup([], withAutomation: true, clock: cancelledClock)
        await cancelledGateway.start()
        let (cancelledAutomation, _, cancelledPart) = try await stageFollowUpAcrossQuietHours(store: cancelledStore, gateway: cancelledGateway, clock: cancelledClock, taskID: "cancelled", endsAt: "2026-09-23T12:00:00-04:00")
        cancelledClock.advance(60); try await cancelledGateway.pollSchedules(now: cancelledClock.now())
        try await cancelledAutomation.cancelPlan(taskID: "cancelled", provenance: .init(source: .pairedMessage, sourceID: "cancel", statement: "Cancel this plan", explicitlyRequested: true, recordedAt: cancelledClock.now()), now: cancelledClock.now(), expectedEpoch: try await cancelledStore.gatewayEpoch()!)
        cancelledClock.advance(36_000); try await cancelledGateway.pollSchedules(now: cancelledClock.now())
        try await eventually { try await cancelledStore.queueState(cancelledPart.id) == "failed" }
        let cancelledSent = await cancelledMessages.sent
        XCTAssertTrue(cancelledSent.isEmpty)

        let expiredClock = FixtureClock(ISO8601DateFormatter().date(from: "2026-09-21T01:58:59Z")!)
        let (expiredStore, expiredGateway, expiredMessages, _) = try await setup([], withAutomation: true, clock: expiredClock)
        await expiredGateway.start()
        let (_, _, expiredPart) = try await stageFollowUpAcrossQuietHours(store: expiredStore, gateway: expiredGateway, clock: expiredClock, taskID: "expired", endsAt: "2026-09-20T22:30:00-04:00")
        expiredClock.advance(60); try await expiredGateway.pollSchedules(now: expiredClock.now())
        expiredClock.advance(36_000); try await expiredGateway.pollSchedules(now: expiredClock.now())
        try await eventually { try await expiredStore.queueState(expiredPart.id) == "failed" }
        let expiredSent = await expiredMessages.sent
        XCTAssertTrue(expiredSent.isEmpty)
    }

}
