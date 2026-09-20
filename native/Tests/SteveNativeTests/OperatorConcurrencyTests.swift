import XCTest
@testable import SteveNative

private actor ConcurrentMessages: GatewayMessages {
    var sent: [String] = []
    func currentRowID() -> Int64 { 0 }
    func watchMessages(sinceRowID: Int64?) -> AsyncThrowingStream<SteveInboundMessage, Error> { AsyncThrowingStream { _ in } }
    func sendText(chatGUID: String, recipient: String, text: String, replyTo: String?) { sent.append(text) }
    func sendAttachment(chatGUID: String, recipient: String, path: String, caption: String, replyTo: String?) { XCTFail("No fixture should send attachments") }
}

/// Relay responses are queued independently from explicitly held operator turns.
/// This avoids depending on the order in which concurrent runTurn calls arrive.
private actor ConcurrentCodex: GatewayCodexClient {
    var routes: [String] = []
    var active: Set<String> = []
    var started: [String] = []
    var inputs: [String] = []
    var completed: Set<String> = []
    var interrupted: Set<String> = []
    var quiesced: [String] = []
    var stops = 0
    var deliveries = 0
    var steerAttempts = 0
    var rejectSteer = false
    func enqueue(_ request: RelayRequestEnvelope) throws { routes.append(String(decoding: try JSONEncoder().encode(request), as: UTF8.self)) }
    func failSteering() { rejectSteer = true }
    func complete(_ thread: String) { completed.insert(thread) }
    func setApprovalHandler(_ handler: CodexApprovalHandler?) {}
    private var holdingStop = false
    private var stopWaiter: CheckedContinuation<Void, Never>?
    var stopIsHeld: Bool { stopWaiter != nil }
    func holdStop() { holdingStop = true }
    func releaseStop() {
        holdingStop = false
        stopWaiter?.resume(); stopWaiter = nil
    }
    func stop() async {
        stops += 1; interrupted.formUnion(active)
        if holdingStop { await withCheckedContinuation { stopWaiter = $0 } }
    }
    func startThread(cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool, serviceTier: SteveServiceTier) -> String { isRelay ? "relay" : UUID().uuidString }
    func resumeThread(threadID: String, cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool, serviceTier: SteveServiceTier) {}
    func compactThread(threadID: String) {}
    func interruptTurn(threadID: String, turnID: String) { interrupted.insert(threadID) }
    func quiesceThread(threadID: String) { quiesced.append(threadID); interrupted.insert(threadID) }
    func steerTurn(threadID: String, expectedTurnID: String, text: String, attachmentPaths: [String]) throws {
        steerAttempts += 1
        if rejectSteer { throw RPCError(message: "fixture finishing turn") }
    }
    func runTurn(threadID: String, text: String, attachmentPaths: [String], workspace: String?, model: String, effort: String, serviceTier: SteveServiceTier, onTurnStarted: @escaping @Sendable (String) async -> Void) async throws -> CodexTurnResult {
        if threadID == "relay" {
            await onTurnStarted(UUID().uuidString)
            if text.hasPrefix("WORKER_RESULT_JSON:") {
                deliveries += 1
                return .init(text: #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Verified fixture result"],"attachments":[]}"#, attachmentPaths: [])
            }
            guard !routes.isEmpty else { throw RPCError(message: "Unexpected relay routing turn") }
            return .init(text: routes.removeFirst(), attachmentPaths: [])
        }
        // A resumed thread represents another turn, not a stale completion gate.
        completed.remove(threadID); interrupted.remove(threadID)
        started.append(threadID); inputs.append(text); active.insert(threadID)
        defer { active.remove(threadID) }
        await onTurnStarted(UUID().uuidString)
        while !completed.contains(threadID) {
            try Task.checkCancellation()
            if interrupted.contains(threadID) { throw CodexTurnInterrupted() }
            try await Task.sleep(for: .milliseconds(5))
        }
        return .init(text: #"{"schemaVersion":1,"kind":"worker_result","status":"completed","summary":"Verified fixture result","artifacts":[]}"#, attachmentPaths: [])
    }
}

final class OperatorConcurrencyTests: XCTestCase {
    private func message(_ id: String) -> SteveInboundMessage {
        .init(guid: id, chatGuid: "chat", senderHandle: "fixture@example.test", text: id, isFromMe: false, isGroup: false, attachmentPaths: [], replyToGuid: nil)
    }
    private func fixture() async throws -> (SteveStore, GatewayCoordinator, ConcurrentMessages, ConcurrentCodex) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try SteveStore(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        var settings = Settings(displayName: "Fixture", model: "fixture", effort: "low", workspaceRoot: root.path)
        settings.permissionProfile = "workspace-write"; settings.maxConcurrentOperators = 2
        try await store.saveSettings(settings)
        try await store.saveTrustedConversation(.init(chatGuid: "chat", senderHandle: "fixture@example.test"))
        let messages = ConcurrentMessages(), codex = ConcurrentCodex()
        let gateway = GatewayCoordinator(store: store, messages: messages, codex: codex, debounce: .milliseconds(5), retryDelay: .milliseconds(10))
        addTeardownBlock {
            await codex.releaseStop()
            await gateway.stop()
            let active = await codex.active
            XCTAssertTrue(active.isEmpty, "stop must join all fixture operator turns")
            try? FileManager.default.removeItem(at: root)
        }
        return (store, gateway, messages, codex)
    }
    private func eventually(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<400 { if try await condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        throw RPCError(message: "Concurrency fixture condition timed out")
    }
    private func launch(_ id: String, mode: OperatorMode, gateway: GatewayCoordinator, codex: ConcurrentCodex) async throws {
        try await codex.enqueue(.init(action: .execute, workerPrompt: id, taskTitle: id, mode: mode))
        await gateway.receive(message(id))
    }
    func testTwoBackgroundOperatorsLeaveRelayResponsiveAndStopJoinsBoth() async throws {
        let (_, gateway, messages, codex) = try await fixture()
        await gateway.start()
        try await launch("first", mode: .background, gateway: gateway, codex: codex)
        try await eventually { await codex.active.count == 1 }
        try await launch("second", mode: .background, gateway: gateway, codex: codex)
        try await eventually { await codex.active.count == 2 }
        try await codex.enqueue(.init(action: .reply, userMessage: "Relay remains responsive"))
        await gateway.receive(message("question"))
        try await eventually { await messages.sent.contains("Relay remains responsive") }
        let active = await codex.active
        XCTAssertEqual(active.count, 2)
        await gateway.stop()
        let remaining = await codex.active, stops = await codex.stops
        XCTAssertTrue(remaining.isEmpty); XCTAssertGreaterThan(stops, 0)
    }
    func testComputerOperatorsWaitForExclusiveOwner() async throws {
        let (store, gateway, _, codex) = try await fixture(); await gateway.start()
        try await launch("first", mode: .computer, gateway: gateway, codex: codex)
        try await eventually { await codex.active.count == 1 }
        try await launch("second", mode: .computer, gateway: gateway, codex: codex)
        try await eventually { try await store.operatorTasks().contains { $0.title == "second" && $0.state == .queued } }
        let first = await codex.started
        XCTAssertEqual(first.count, 1)
        await codex.complete(first[0])
        try await eventually { await codex.started.count == 2 }
        let active = await codex.active
        XCTAssertEqual(active.count, 1)
    }
    func testTargetedCancellationKeepsUnrelatedOperatorRunning() async throws {
        let (store, gateway, _, codex) = try await fixture(); await gateway.start()
        try await launch("first", mode: .background, gateway: gateway, codex: codex)
        try await launch("second", mode: .background, gateway: gateway, codex: codex)
        try await eventually { await codex.active.count == 2 }
        let tasks = try await store.operatorTasks(), first = try XCTUnwrap(tasks.first { $0.title == "first" }), second = try XCTUnwrap(tasks.first { $0.title == "second" })
        try await codex.enqueue(.init(action: .cancel, taskID: first.id))
        await gateway.receive(message("cancel first"))
        try await eventually { try await store.queueState("inbound:cancel first") == "completed" }
        let active = await codex.active, stops = await codex.stops, quiesced = await codex.quiesced
        XCTAssertEqual(active, [try XCTUnwrap(second.threadID)]); XCTAssertEqual(stops, 0)
        XCTAssertTrue(quiesced.contains(try XCTUnwrap(first.threadID)))
    }
    func testFailedSteerPreservesFollowUpAndDeliversOriginalBeforeContinuation() async throws {
        let (store, gateway, messages, codex) = try await fixture(); await gateway.start()
        try await launch("first", mode: .background, gateway: gateway, codex: codex)
        try await eventually { await codex.active.count == 1 }
        let tasks = try await store.operatorTasks(), task = try XCTUnwrap(tasks.first)
        await codex.failSteering()
        try await codex.enqueue(.init(action: .execute, workerPrompt: "Include the correction", taskID: task.id))
        await gateway.receive(message("follow-up"))
        try await eventually { await codex.steerAttempts > 0 }
        let pending = try await store.operatorTask(id: task.id)
        XCTAssertEqual(pending?.pendingFollowUps?.count, 1)
        await codex.complete(try XCTUnwrap(task.threadID))
        try await eventually { await codex.started.count == 2 }
        let deliveryCount = await codex.deliveries, inputs = await codex.inputs
        XCTAssertEqual(deliveryCount, 1); XCTAssertTrue(inputs.last?.contains("Include the correction") == true)
        try await eventually { try await store.queueState("inbound:first") == "completed" }
        await codex.complete(try XCTUnwrap(task.threadID))
        try await eventually { try await store.queueState("inbound:follow-up") == "completed" }
        let sent = await messages.sent
        XCTAssertEqual(sent.filter { $0 == "Verified fixture result" }.count, 2)
    }
    func testRestartMarksRunningTaskUncertainWithoutReplaying() async throws {
        let (store, gateway, _, codex) = try await fixture()
        try await store.saveGatewayEpoch("previous")
        let settings = try await store.getSettings()!
        let task = OperatorTaskRecord(id: "persisted", chatGuid: "chat", senderHandle: "fixture@example.test", workspace: settings.workspaceRoot!, permission: "workspace-write", title: "Previous", objective: "Do not replay", threadID: "previous-thread", mode: .computer, state: .running, inbound: [message("original")], runID: "old-run")
        try await store.saveOperatorTask(task, expectedEpoch: "previous")
        await gateway.start()
        let restored = try await store.operatorTask(id: task.id)
        XCTAssertEqual(restored?.state, .uncertain)
        try await codex.enqueue(.init(action: .reply, userMessage: "No replay"))
        await gateway.receive(message("question"))
        try await eventually { try await store.queueState("inbound:question") == "completed" }
        let starts = await codex.started
        XCTAssertTrue(starts.isEmpty)
    }
    func testTaskFromDifferentChatCannotBeContinued() async throws {
        let (store, gateway, _, codex) = try await fixture(); await gateway.start()
        let settings = try await store.getSettings()!, epoch = try await store.gatewayEpoch()!
        let task = OperatorTaskRecord(id: "foreign", chatGuid: "other-chat", senderHandle: "fixture@example.test", workspace: settings.workspaceRoot!, permission: "workspace-write", title: "Foreign", objective: "Private", mode: .background, state: .completed, inbound: [], runID: "foreign-run")
        try await store.saveOperatorTask(task, expectedEpoch: epoch)
        try await codex.enqueue(.init(action: .execute, workerPrompt: "Continue", taskID: task.id))
        await gateway.receive(message("cross-chat"))
        try await eventually { let state = try await store.queueState("inbound:cross-chat"); return state == "uncertain" || state == "failed" }
        let unchanged = try await store.operatorTask(id: task.id), started = await codex.started
        XCTAssertEqual(unchanged?.runID, task.runID); XCTAssertEqual(unchanged?.state, .completed); XCTAssertEqual(unchanged?.objective, task.objective); XCTAssertTrue(started.isEmpty)
    }
    func testResumeRejectedUntilHeldPauseFinishesThenExplicitResumeSucceeds() async throws {
        let (store, gateway, _, codex) = try await fixture()
        await gateway.start()
        await codex.holdStop()
        let pausing = Task { try await gateway.setPaused(true) }
        // Cleanup must unblock the first pause even if any assertion throws.
        addTeardownBlock {
            await codex.releaseStop()
            _ = try? await pausing.value
        }
        try await eventually { await codex.stopIsHeld }
        do {
            try await gateway.setPaused(false)
            XCTFail("Resume crossed an unfinished pause transition")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("finish"), "Expected an actionable still-finishing message")
        }
        let during = await gateway.isPaused()
        XCTAssertTrue(during)
        let startedDuring = await codex.started
        XCTAssertTrue(startedDuring.isEmpty)
        await codex.releaseStop()
        try await pausing.value
        let paused = await gateway.isPaused(), persistedPaused = try await store.paused()
        XCTAssertTrue(paused); XCTAssertTrue(persistedPaused)
        try await gateway.setPaused(false)
        let resumed = await gateway.isPaused(), persistedResumed = try await store.paused()
        XCTAssertFalse(resumed); XCTAssertFalse(persistedResumed)
    }

    func testQueuedFreshContextSurvivesOrdinaryReuseFollowUp() async throws {
        let (store, gateway, _, codex) = try await fixture()
        await gateway.start()
        try await launch("computer-owner", mode: .computer, gateway: gateway, codex: codex)
        try await eventually { await codex.active.count == 1 }
        let settings = try await store.getSettings()!, epoch = try await store.gatewayEpoch()!
        let queued = OperatorTaskRecord(id: "queued-fresh", chatGuid: "chat", senderHandle: "fixture@example.test",
            workspace: settings.workspaceRoot!, permission: "workspace-write", title: "Queued fresh task", objective: "Start anew",
            threadID: "old-thread-must-not-resume", mode: .computer, state: .queued,
            inbound: [message("queued-original")], runID: "queued-run", contextAction: .fresh)
        try await store.saveOperatorTask(queued, expectedEpoch: epoch)
        try await codex.enqueue(.init(action: .execute, workerPrompt: "Also include this detail", workerContextAction: .reuse, taskID: queued.id))
        await gateway.receive(message("queued-follow-up"))
        try await eventually {
            try await store.operatorTask(id: queued.id)?.inbound.contains { $0.guid == "queued-follow-up" } == true
        }
        let updated = try await store.operatorTask(id: queued.id), starts = await codex.started
        XCTAssertEqual(updated?.state, .queued)
        XCTAssertEqual(updated?.contextAction, .fresh, "A routine follow-up must not revive the old thread")
        XCTAssertEqual(updated?.threadID, queued.threadID)
        XCTAssertTrue(updated?.objective.contains("Also include this detail") == true)
        XCTAssertEqual(starts.count, 1, "The existing computer owner must still block this task")
    }

    func testLegacyTaskOriginalWordsSurviveFreshFollowUp() async throws {
        let (store, gateway, _, codex) = try await fixture()
        await gateway.start()
        let settings = try await store.getSettings()!
        let original = message("Only vegetarian, never book it")
        let old = OperatorTaskRecord(id: "legacy", chatGuid: "chat", senderHandle: original.senderHandle, workspace: settings.workspaceRoot!, permission: "workspace-write", title: "Dinner", objective: "Find dinner", mode: .background, state: .completed, inbound: [original], runID: "old-run")
        try await store.saveOperatorTask(old, expectedEpoch: try await store.gatewayEpoch()!)
        try await codex.enqueue(.init(action: .execute, workerPrompt: "Cheaper options", workerContextAction: .fresh, taskID: "legacy"))
        await gateway.receive(message("Actually, cheaper."))
        try await eventually { await codex.inputs.count == 1 }
        let inputs = await codex.inputs
        XCTAssertTrue(inputs[0].contains("Only vegetarian, never book it"))
        XCTAssertTrue(inputs[0].contains("Actually, cheaper."))
        let saved = try await store.operatorTask(id: "legacy")
        XCTAssertEqual(saved?.originalMessages?.count, 2)
    }

}
