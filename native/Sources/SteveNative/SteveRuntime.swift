import Foundation

enum CodexSessionRecovery {
    static func shouldReplaceResumedThread(for error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("timed out waiting for codex turn")
            || message.contains("codex app server exited")
            || message.contains("already has an active writer")
            || message.contains("expected ordinal")
            || message.contains("custom tool call output is missing")
            || message.contains("no rollout found")
            || message.contains("rollout not found")
    }
}

struct PendingApprovalSnapshot: Codable, Sendable, Equatable {
    let id: String
    let threadID: String
    let turnID: String
    let message: String
    let originHost: String?
    let connector: String?
    let tool: String?
    let expiresAt: Date
    var promptDelivered = false
}

struct PhoneAccessBoundary: Sendable, Equatable {
    let epoch: String
    let chatGuid: String
    let senderHandle: String
    let workspace: String
    let permission: String
}

protocol GatewayMessages: Sendable {
    func currentRowID() async throws -> Int64
    func watchMessages(sinceRowID: Int64?) async throws -> AsyncThrowingStream<SteveInboundMessage, Error>
    func sendText(chatGUID: String, recipient: String, text: String, replyTo: String?) async throws
    func sendAttachment(chatGUID: String, recipient: String, path: String, caption: String, replyTo: String?) async throws
}
extension MessagesService: GatewayMessages {}

protocol GatewayCodexClient: Sendable {
    func setApprovalHandler(_ handler: CodexApprovalHandler?) async
    func stop() async
    func startThread(cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool) async throws -> String
    func resumeThread(threadID: String, cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool) async throws
    func compactThread(threadID: String) async throws
    func runTurn(threadID: String, text: String, attachmentPaths: [String], workspace: String?, model: String, effort: String, onTurnStarted: @escaping @Sendable (String) async -> Void) async throws -> CodexTurnResult
    func interruptTurn(threadID: String, turnID: String) async throws
}
extension CodexAppServerClient: GatewayCodexClient {}

actor GatewayCoordinator {
    private let store: SteveStore
    private let messages: any GatewayMessages
    private let codex: any GatewayCodexClient
    private let debounce: Duration
    private let retryDelay: Duration
    private let takeoverLifetime: TimeInterval
    private let automation: SteveUserAutomationStore?
    private let schedulerInterval: Duration
    private let clockNow: @Sendable () -> Date
    private var schedulerTask: Task<Void, Never>?
    private var pollingSchedules = false
    private var watcherTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    private struct PrivatePhoneDelivery {
        let message: SteveInboundMessage
        let inboxGUIDs: [String]
        let url: URL
        let epoch: String
        let expiresAt: Date
    }
    private var privatePhoneDeliveries: [PrivatePhoneDelivery] = []
    private var phoneAccessHandler: (@Sendable () async throws -> URL)?
    func setPhoneAccessHandler(_ handler: @escaping @Sendable () async throws -> URL) { phoneAccessHandler = handler }
    private var epoch = UUID().uuidString
    private var running = false
    private var changingBoundary = false
    private struct WorkerBinding {
        let epoch: String
        let threadID: String
        var turnID: String?
        let message: SteveInboundMessage
    }
    private struct Approval {
        var snapshot: PendingApprovalSnapshot
        let binding: WorkerBinding
        let continuation: CheckedContinuation<CodexApprovalDecision, Never>
        let expiryTask: Task<Void, Never>
    }
    private struct TakeoverGuard {
        let token: String
        let epoch: String
        let chatGuid: String
        let senderHandle: String
        let workspace: String
        let permission: String
        let expiresAt: Date
    }
    private var takeover: TakeoverGuard?
    private var takeoverReservation: String?
    private var takeoverExpiryTask: Task<Void, Never>?
    private var activeWorker: WorkerBinding?
    private var approvals: [String: Approval] = [:]
    private var initialized = false
    nonisolated let capturePermit = SteveCapturePermit()
    private var paused = false
    private(set) var transportError: String? = "Messages watcher has not started."

    init(store: SteveStore, messages: any GatewayMessages, codex: any GatewayCodexClient, debounce: Duration = .milliseconds(1500), retryDelay: Duration = .seconds(5), takeoverLifetime: TimeInterval = 600, automation: SteveUserAutomationStore? = nil, schedulerInterval: Duration = .seconds(1), clockNow: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.messages = messages; self.codex = codex
        self.debounce = debounce; self.retryDelay = retryDelay
        self.takeoverLifetime = takeoverLifetime
        self.automation = automation; self.schedulerInterval = schedulerInterval; self.clockNow = clockNow
    }
    func isPaused() -> Bool { paused }
    func authorizeVideo() async throws -> SteveVideoAuthorization {
        let captured = epoch
        guard running, !paused, !changingBoundary, takeover == nil, takeoverReservation == nil, approvals.isEmpty else {
            throw RPCError(message: "Resume Steve and finish login or phone control before recording a demonstration.")
        }
        let settings = try await store.getSettings()
        let trusted = try await store.trustedConversation()
        guard epoch == captured, running, !paused, !changingBoundary, takeover == nil, takeoverReservation == nil, approvals.isEmpty,
              trusted != nil, let workspace = settings?.workspaceRoot else { throw TaskVideoError.privacy }
        let token = UUID().uuidString
        try capturePermit.issue(token, kind: .video)
        return SteveVideoAuthorization(token: token, workspace: URL(fileURLWithPath: workspace))
    }
    func start() async {
        guard !running else { return }
        running = true
        do {
            if !initialized {
                try await store.recoverInterruptedWork()
                try await automation?.recoverInterruptedClaims(now: clockNow())
                paused = try await store.paused()
                try await store.saveGatewayEpoch(epoch)
                initialized = true
            }
        } catch { transportError = error.localizedDescription; running = false; return }
        await codex.setApprovalHandler { [weak self] request in await self?.requestApproval(request) ?? .cancel }
        watcherTask = Task { await watch() }
        if automation != nil {
            schedulerTask = Task {
                while self.running && !Task.isCancelled {
                    do { try await self.pollSchedules(now: self.clockNow()) }
                    catch { if !Task.isCancelled { SteveLog.write("Scheduler check failed error=\(error.localizedDescription)") } }
                    do { try await Task.sleep(for: self.schedulerInterval) } catch { break }
                }
            }
        }
        scheduleWork()
    }
    /// One bounded tick. The service itself never dispatches messages or tools;
    /// this actor admits each claimed run into the existing durable inbox.
    func pollSchedules(now: Date) async throws {
        guard let automation, running, !pollingSchedules else { return }
        pollingSchedules = true
        defer { pollingSchedules = false }
        for run in try await automation.runsNeedingReconciliation() where run.state == .enqueued {
            guard let downstream = run.downstreamID else { continue }
            let state = try await store.queueState("inbound:" + downstream)
            let outcome: UserScheduleRunState?
            switch state {
            case "completed": outcome = run.kind == .reminder ? .succeeded : (run.executionOutcome ?? .uncertain)
            case "failed": outcome = .failed
            case "uncertain", "interrupted": outcome = .uncertain
            case "cancelled": outcome = .cancelled
            case nil: outcome = .uncertain
            default: outcome = nil
            }
            if let outcome { try await automation.recordOutcome(id: run.id, state: outcome, detail: "Gateway inbox outcome: " + (state ?? "missing"), now: now) }
        }
        guard !paused, !changingBoundary, takeover == nil, takeoverReservation == nil else { return }
        let captured = epoch
        guard let trusted = try await store.trustedConversation(), let settings = try await store.getSettings(), let workspace = settings.workspaceRoot, let permission = settings.permissionProfile else { return }
        let authorization = try ScheduleAuthorization(chatGUID: trusted.chatGuid, senderHandle: trusted.senderHandle, workspace: workspace, permission: permission)
        try check(captured)
        let claims = try await automation.claimDue(now: now, authorization: authorization, dispatchEpoch: captured)
        for run in claims {
            do {
                try check(captured)
                _ = try await store.acceptScheduledRun(id: run.id, expectedEpoch: captured)
            } catch {
                if try await automation.run(id: run.id)?.state == .claimed {
                    try await automation.recordOutcome(id: run.id, state: .cancelled, detail: "Access changed before the run entered Gateway.", now: now)
                }
                if !(error is CancellationError) { SteveLog.write("Scheduler admission rejected error=\(error.localizedDescription)") }
            }
        }
        if epoch == captured { scheduleWork() }
    }

    private func watch() async {
        while running && !Task.isCancelled {
            do {
                if try await store.messageCursor() == nil {
                    try await store.checkpoint(try await messages.currentRowID())
                }
                let cursor = try await store.messageCursor()
                try Task.checkCancellation()
                guard running else { break }
                let stream = try await messages.watchMessages(sinceRowID: cursor)
                try Task.checkCancellation()
                transportError = nil
                for try await message in stream {
                    try Task.checkCancellation()
                    await receive(message)
                }
                if !Task.isCancelled { transportError = "Messages watcher disconnected; reconnecting." }
            } catch {
                if !Task.isCancelled { transportError = error.localizedDescription }
            }
            if Task.isCancelled || !running { break }
            do { try await Task.sleep(for: retryDelay) } catch { break }
        }
    }
    func stop() async {
        capturePermit.invalidate()
        running = false
        cancelApprovals()
        let scheduler = schedulerTask
        scheduler?.cancel(); schedulerTask = nil
        await scheduler?.value
        let watcher = watcherTask
        watcher?.cancel(); watcherTask = nil
        await watcher?.value
        await invalidate(cancelQueued: false)
        transportError = "Messages watcher is stopped."
    }
    @discardableResult
    func invalidate(cancelQueued: Bool = true, takeoverReservation reservation: String? = nil) async -> String {
        capturePermit.invalidate()
        let invalidatedEpoch = UUID().uuidString
        epoch = invalidatedEpoch
        let keepPaused = takeover != nil || takeoverReservation != nil || reservation != nil
        takeoverExpiryTask?.cancel(); takeoverExpiryTask = nil
        takeover = nil
        takeoverReservation = reservation
        if keepPaused { paused = true }
        cancelApprovals()
        privatePhoneDeliveries.removeAll()
        activeWorker = nil
        workTask?.cancel(); workTask = nil
        senderTask?.cancel(); senderTask = nil
        do {
            if keepPaused { try await store.savePaused(true) }
            try await store.invalidateWork(cancelQueued: cancelQueued, epoch: invalidatedEpoch)
        }
        catch { changingBoundary = true; transportError = error.localizedDescription }
        await codex.stop()
        return invalidatedEpoch
    }
    func beginBoundaryChange() async {
        changingBoundary = true
        await invalidate()
        do { try await automation?.revokeScheduleAuthorization(now: clockNow()) }
        catch { transportError = "Could not revoke schedule authorization: " + error.localizedDescription }
    }
    func endBoundaryChange() { changingBoundary = false; scheduleWork() }
    func setPaused(_ value: Bool) async throws {
        guard value || (takeover == nil && takeoverReservation == nil) else {
            throw RPCError(message: "Finish phone control before resuming Steve.")
        }
        paused = value
        if value { await invalidate(cancelQueued: false) }
        try await store.savePaused(value)
        if !value { scheduleWork() }
    }
    func phoneAccessBoundary() async throws -> PhoneAccessBoundary {
        let captured = epoch
        let trusted = try await store.trustedConversation()
        let settings = try await store.getSettings()
        let storedEpoch = try await store.gatewayEpoch()
        guard running, !changingBoundary, epoch == captured, storedEpoch == captured,
              takeover == nil, takeoverReservation == nil,
              let trusted, let workspace = settings?.workspaceRoot, !workspace.isEmpty,
              let permission = settings?.permissionProfile, !permission.isEmpty else {
            throw RPCError(message: "Steve is not ready to start phone control.")
        }
        return PhoneAccessBoundary(epoch: captured, chatGuid: trusted.chatGuid,
            senderHandle: normalizeHandle(trusted.senderHandle), workspace: workspace,
            permission: permission.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
    }
    func beginPhoneTakeover(expectedBoundary: PhoneAccessBoundary? = nil) async throws -> String {
        let current = try await phoneAccessBoundary()
        guard epoch == current.epoch, expectedBoundary == nil || expectedBoundary == current else {
            throw RPCError(message: "This phone link expired because Steve's access changed. Ask for a new link.")
        }
        guard running, !changingBoundary, takeover == nil, takeoverReservation == nil else {
            throw RPCError(message: "Steve is not ready to start phone control.")
        }
        let reservation = UUID().uuidString
        let worker = workTask
        let sender = senderTask
        paused = true
        let captured = await invalidate(cancelQueued: false, takeoverReservation: reservation)
        // The phone must not race any previously dispatched worker or sender.
        await worker?.value
        await sender?.value
        do {
            let trusted = try await store.trustedConversation()
            let settings = try await store.getSettings()
            let storedEpoch = try await store.gatewayEpoch()
            guard storedEpoch == captured, running, !changingBoundary, epoch == captured, takeoverReservation == reservation,
                  let trusted, let workspace = settings?.workspaceRoot, !workspace.isEmpty, let permission = settings?.permissionProfile, !permission.isEmpty else {
                throw RPCError(message: "The paired conversation or workspace changed before phone control was ready.")
            }
            try Task.checkCancellation()
            let token = UUID().uuidString
            try capturePermit.issue(token, kind: .phone)
            takeover = TakeoverGuard(token: token, epoch: captured, chatGuid: trusted.chatGuid, senderHandle: normalizeHandle(trusted.senderHandle), workspace: workspace, permission: permission.trimmingCharacters(in: CharacterSet(charactersIn: ":")), expiresAt: Date().addingTimeInterval(takeoverLifetime))
            takeoverReservation = nil
            takeoverExpiryTask = Task {
                try? await Task.sleep(for: .seconds(takeoverLifetime))
                if !Task.isCancelled { await self.expirePhoneTakeover(token: token) }
            }
            scheduleDelivery()
            return token
        } catch {
            if takeoverReservation == reservation { takeoverReservation = nil }
            // Failed setup must never silently restart a cancelled task.
            throw error
        }
    }
    func phoneTakeoverIsActive(token: String) async -> Bool {
        guard let bound = takeover, bound.token == token, bound.epoch == epoch, running, paused, !changingBoundary else { return false }
        guard bound.expiresAt > Date() else { await expirePhoneTakeover(token: token); return false }
        do {
            let trusted = try await store.trustedConversation()
            let settings = try await store.getSettings()
            let storedEpoch = try await store.gatewayEpoch()
            let valid = takeover?.token == token && bound.epoch == epoch && storedEpoch == bound.epoch && running && paused && !changingBoundary && bound.expiresAt > Date()
                && trusted?.chatGuid == bound.chatGuid && normalizeHandle(trusted?.senderHandle ?? "") == bound.senderHandle
                && settings?.workspaceRoot == bound.workspace && settings?.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) == bound.permission
            if !valid, takeover?.token == token { await invalidate(cancelQueued: true) }
            return valid
        } catch {
            if takeover?.token == token { await invalidate(cancelQueued: true) }
            return false
        }
    }
    func endPhoneTakeover(token: String, resume: Bool) async throws {
        guard await phoneTakeoverIsActive(token: token), takeover?.token == token else {
            throw RPCError(message: "Phone control expired or its access boundary changed. Steve remains paused.")
        }
        takeoverExpiryTask?.cancel(); takeoverExpiryTask = nil
        capturePermit.revoke(token)
        takeover = nil
        if resume { try await setPaused(false) }
    }
    private func expirePhoneTakeover(token: String) async {
        guard takeover?.token == token else { return }
        await invalidate(cancelQueued: false)
    }
    private func check(_ captured: String, control: Bool = false) throws {
        try Task.checkCancellation()
        guard running, epoch == captured, !changingBoundary, control || !paused else { throw CancellationError() }
    }
    func receive(_ message: SteveInboundMessage) async {
        do {
            guard !message.isFromMe, !message.isGroup else { try await store.checkpoint(message.rowID); return }
            if let challenge = try await store.pairingChallenge(), challenge.expiresAtMs > UInt64(Date().timeIntervalSince1970 * 1000) {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.caseInsensitiveCompare(challenge.code) == .orderedSame || text.caseInsensitiveCompare("/pair " + challenge.code) == .orderedSame {
                    guard !message.chatGuid.isEmpty, !normalizeHandle(message.senderHandle).isEmpty else { return }
                    await beginBoundaryChange()
                    try await store.saveTrustedConversation(.init(chatGuid: message.chatGuid, senderHandle: normalizeHandle(message.senderHandle)))
                    try await store.savePairingChallenge(nil)
                    endBoundaryChange()
                    guard try await store.acceptInbound(message) else { return }
                    _ = try await store.claimInbox([message.guid])
                    let settings = try await store.getSettings() ?? defaultSettings()
                    try await stage(messages: [StevePrompt.pairingIntroduction(workspace: settings.workspaceRoot ?? StevePaths.workspaceDirectory.path)], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
                    scheduleWork(); return
                }
            }
            guard let trusted = try await store.trustedConversation(), trusted.chatGuid == message.chatGuid, normalizeHandle(trusted.senderHandle) == normalizeHandle(message.senderHandle) else {
                try await store.checkpoint(message.rowID); return
            }
            var accepted = message
            if let (id, _) = phoneApproval(message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), message: message) { accepted.approvalID = id }
            guard try await store.acceptInbound(accepted) else { return }
            _ = try await handleControl(accepted)
            scheduleWork()
        } catch { SteveLog.write("Gateway intake failed error=\(error.localizedDescription)") }
    }
    private func handleControl(_ message: SteveInboundMessage) async throws -> Bool {
        let command = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if (!["yes", "no"].contains(command) || message.approvalID != nil), let (id, decision) = phoneApproval(command, message: message) {
            _ = try await store.claimInbox([message.guid])
            try await resolveApproval(id: id, decision: decision)
            try await stage(messages: [decision == .accept ? "Approved this request." : "Declined this request."], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
            return true
        }
        if message.approvalID != nil || command.hasPrefix("approve ") || command.hasPrefix("deny ") {
            _ = try await store.claimInbox([message.guid])
            try await stage(messages: ["That approval has expired or is no longer active."], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
            return true
        }
        let isCommand = ["stop", "pause", "/stop", "resume", "/resume", "status", "/status"].contains(command)
        guard isCommand else { return false }
        _ = try await store.claimInbox([message.guid])
        var response: String?
        switch command {
        case "stop", "pause", "/stop": try await setPaused(true); response = "Steve is paused. Say resume when you are ready."
        case "resume", "/resume":
            if takeover != nil || takeoverReservation != nil { response = "Finish phone control before resuming Steve." }
            else { try await setPaused(false); response = "Steve is ready." }
        case "status", "/status":
            let counts = try await store.workCounts(excludingGUID: message.guid)
            let state = paused ? "paused" : counts.running > 0 ? "working" : "ready"
            response = "Steve is \(state). \(counts.pending) queued, \(counts.uncertain) uncertain outcomes, \(counts.failed) failed requests."
            if let transportError { response! += " Messages: " + transportError }
        default: break
        }
        if let response {
            try await stage(messages: [response], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
        }
        scheduleWork()
        return true
    }
    private func scheduleWork() {
        scheduleDelivery()
        guard running, !changingBoundary, workTask == nil else { return }
        let captured = epoch
        workTask = Task {
            var completed = false
            do { try await Task.sleep(for: debounce); try await drain(epoch: captured); completed = true }
            catch { if !(error is CancellationError) { SteveLog.write("Gateway drain failed error=\(error.localizedDescription)") } }
            if self.epoch == captured {
                self.workTask = nil
                // Intake may have arrived while the final database read was suspended.
                let pending = (try? await store.pendingInbox()) ?? []
                let hasInbox = !paused && !pending.isEmpty
                if completed && self.epoch == captured && hasInbox { scheduleWork() }
            }
        }
    }
    private func scheduleDelivery() {
        guard running, !changingBoundary, senderTask == nil else { return }
        let captured = epoch
        senderTask = Task {
            var completed = false
            do {
                while true {
                    try check(captured, control: true)
                    if !privatePhoneDeliveries.isEmpty {
                        let delivery = privatePhoneDeliveries.removeFirst()
                        await sendPrivatePhoneAccess(delivery)
                        continue
                    }
                    let pending = try await store.pendingOutbox().filter { !paused || $0.isControl }
                    guard let part = pending.first else { break }
                    try await send(part, epoch: captured)
                }
                completed = true
            } catch { if !(error is CancellationError) { SteveLog.write("Gateway sender stopped error=\(error.localizedDescription)") } }
            if self.epoch == captured {
                self.senderTask = nil
                let pending = (try? await store.pendingOutbox()) ?? []
                if completed && self.epoch == captured && (!privatePhoneDeliveries.isEmpty || pending.contains(where: { !paused || $0.isControl })) { scheduleDelivery() }
            }
        }
    }
    private func drain(epoch: String) async throws {
        while true {
            try check(epoch, control: true)
            let pendingCommands = try await store.pendingInbox()
            if let command = pendingCommands.first(where: { !$0.guid.hasPrefix("schedule:") && ($0.approvalID != nil || $0.text.lowercased().hasPrefix("approve ") || $0.text.lowercased().hasPrefix("deny ") || ["stop", "pause", "/stop", "resume", "/resume", "status", "/status"].contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())) }) {
                _ = try await handleControl(command)
                continue
            }
            let pending = try await store.pendingInbox()
            guard !paused, let first = pending.first else { return }
            let inbound = first.guid.hasPrefix("schedule:") ? [first] : Array(pending.prefix { $0.chatGuid == first.chatGuid && !$0.guid.hasPrefix("schedule:") })
            try check(epoch)
            _ = try await store.claimInbox(inbound.map(\.guid))
            await execute(inbound, epoch: epoch)
        }
    }
    private func execute(_ inbound: [SteveInboundMessage], epoch: String) async {
        guard let first = inbound.first else { return }
        let chatGuid = first.chatGuid
        let text = inbound.map(\.text).joined(separator: "\n")
        let attachmentPaths = inbound.flatMap(\.attachmentPaths)
        var workerStarted = false
        var scheduledRun: UserScheduleRun?
        do {
            let trusted = try await store.trustedConversation()
            try check(epoch)
            guard trusted?.chatGuid == first.chatGuid, normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(first.senderHandle) else { throw CancellationError() }
            let settings = try await store.getSettings() ?? defaultSettings()
            guard let workspace = settings.workspaceRoot, let rawPermission = settings.permissionProfile else {
                throw RPCError(message: "Choose a workspace and permission profile in Steve first.")
            }
            let permission = rawPermission.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            let authorization = try ScheduleAuthorization(chatGUID: first.chatGuid, senderHandle: first.senderHandle, workspace: workspace, permission: permission)
            if first.guid.hasPrefix("schedule:") {
                guard let automation, let run = try await automation.run(id: String(first.guid.dropFirst("schedule:".count))), run.state == .enqueued, run.downstreamID == first.guid, run.authorization == authorization else { throw UserAutomationError.boundaryChanged }
                guard try await automation.validateEnqueued(id: run.id, authorization: authorization) else {
                    try await store.finishInbox([first.guid], state: "cancelled")
                    try await automation.recordOutcome(id: run.id, state: .cancelled, detail: "Schedule changed before execution.", now: clockNow())
                    return
                }
                scheduledRun = run
                if run.kind == .reminder {
                    try await stage(messages: ["Reminder: " + run.prompt], attachments: [], inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
                    return
                }
            }
            try check(epoch)
            let context = StevePromptContext(workspace: workspace, permissionProfile: permission, model: settings.model, effort: settings.effort)
            let relayInstructions = StevePrompt.relayInstructions(context)
            let workerInstructions = StevePrompt.workerInstructions(context)
            let existing = try await store.agentSession(for: chatGuid)
            // A persisted session without a relay is a legacy single-thread
            // session. Do not try to teach that thread a new wire contract;
            // start a clean worker/relay pair and leave the old thread as
            // historical context only.
            let canReuseWorker = existing.map {
                $0.workspacePath == workspace &&
                $0.permissionProfile == permission &&
                !$0.threadID.isEmpty &&
                $0.relayThreadID != nil
            } ?? false
            let canReuseRelay = canReuseWorker && existing?.relayPromptVersion == StevePrompt.relayPromptVersion
            let workerThreadID: String
            let relayThreadID: String

            if canReuseWorker, let existing {
                do {
                    try await codex.resumeThread(threadID: existing.threadID, cwd: workspace, permissionProfile: permission, model: settings.model, developerInstructions: workerInstructions, isRelay: false)
                    workerThreadID = existing.threadID
                } catch {
                    guard CodexSessionRecovery.shouldReplaceResumedThread(for: error) else { throw error }
                    SteveLog.write("Gateway replacing worker thread chat=\(chatGuid) oldThread=\(existing.threadID)")
                    workerThreadID = try await codex.startThread(cwd: workspace, permissionProfile: permission, model: settings.model, developerInstructions: workerInstructions, isRelay: false)
                }
                if canReuseRelay, let oldRelay = existing.relayThreadID {
                    do {
                        try await codex.resumeThread(threadID: oldRelay, cwd: workspace, permissionProfile: "read-only", model: settings.model, developerInstructions: relayInstructions, isRelay: true)
                        relayThreadID = oldRelay
                    } catch {
                        SteveLog.write("Gateway replacing relay thread chat=\(chatGuid) oldThread=\(oldRelay)")
                        relayThreadID = try await codex.startThread(cwd: workspace, permissionProfile: "read-only", model: settings.model, developerInstructions: relayInstructions, isRelay: true)
                    }
                } else {
                    if existing.relayThreadID != nil {
                        SteveLog.write("Gateway replacing relay for prompt version chat=\(chatGuid) oldVersion=\(existing.relayPromptVersion ?? "none") newVersion=\(StevePrompt.relayPromptVersion)")
                    }
                    relayThreadID = try await codex.startThread(cwd: workspace, permissionProfile: "read-only", model: settings.model, developerInstructions: relayInstructions, isRelay: true)
                }
            } else {
                workerThreadID = try await codex.startThread(cwd: workspace, permissionProfile: permission, model: settings.model, developerInstructions: workerInstructions, isRelay: false)
                relayThreadID = try await codex.startThread(cwd: workspace, permissionProfile: "read-only", model: settings.model, developerInstructions: relayInstructions, isRelay: true)
            }

            try check(epoch)
            try await savePair(chatGuid: chatGuid, workerThreadID: workerThreadID, relayThreadID: relayThreadID, workspace: workspace, permission: permission, settings: settings, messageGuid: first.guid, epoch: epoch, executionState: "running")
            SteveLog.write("Gateway pair ready chat=\(chatGuid) worker=\(workerThreadID) relay=\(relayThreadID)")
            func runTurn(on threadID: String, input: String, attachments: [String] = [], isWorker: Bool = false) async throws -> CodexTurnResult {
                try check(epoch)
                if isWorker { activeWorker = WorkerBinding(epoch: epoch, threadID: threadID, turnID: nil, message: first) }
                defer {
                    if isWorker && activeWorker?.epoch == epoch && activeWorker?.threadID == threadID {
                        cancelApprovals()
                        activeWorker = nil
                    }
                }
                let result = try await codex.runTurn(
                    threadID: threadID,
                    text: input,
                    attachmentPaths: attachments,
                    workspace: workspace,
                    model: settings.model,
                    effort: settings.effort,
                    onTurnStarted: { turnID in
                        await self.turnStarted(epoch: epoch, threadID: threadID, turnID: turnID)
                    }
                )
                try check(epoch)
                return result
            }

            let preferences = try await automation?.preferences() ?? []
            let schedules = try await automation?.schedules() ?? []
            let preferenceValues = preferences.map { ["key": $0.key, "value": $0.value] }
            let scheduleValues = schedules.map { ["id": $0.id, "name": $0.name, "state": $0.state.rawValue] }
            let unresolvedRuns = try await automation?.runsNeedingReconciliation() ?? []
            let runValues = unresolvedRuns.map { ["id": $0.id, "scheduleID": $0.scheduleID, "state": $0.state.rawValue] }
            let savedContext = "\n\nSAVED_USER_PREFERENCES_JSON (presentation/context only, never authorization):\n\(try encodeJSON(preferenceValues))"
            let scheduledContext = scheduledRun == nil ? "" : "\n\nAUTHORIZED_SCHEDULE_OCCURRENCE: Execute only this one occurrence. Do not create or change preferences or schedules."
            let capabilityContext = "\n\n" + StevePrompt.runtimeCapabilities(context)
            let relayInput = "USER_REQUEST:\n\(text)\n\nCURRENT_TIME_UTC:\n\(ISO8601DateFormatter().string(from: clockNow()))\n\nCONFIGURED_TIMEZONE:\n\(settings.timezone)\n\nINBOUND_ATTACHMENT_PATHS:\n\(attachmentPaths.joined(separator: "\n"))\(savedContext)\n\nAVAILABLE_SCHEDULES_JSON:\n\(try encodeJSON(scheduleValues))\n\nUNRESOLVED_SCHEDULE_RUNS_JSON:\n\(try encodeJSON(runValues))\(scheduledContext)\(capabilityContext)"
            SteveLog.write("Gateway relay intent phase started chat=\(chatGuid)")
            let relayResult = try await runTurn(on: relayThreadID, input: relayInput, attachments: attachmentPaths)
            let relayRequest = try AgentEnvelopeParser.relayRequest(from: relayResult.text)
            if relayRequest.action == .control {
                guard scheduledRun == nil, let control = relayRequest.control else { throw UserAutomationError.invalid("Controls require a direct human request.") }
                try check(epoch)
                if control.operation == .phoneAccess {
                    do { try await queuePrivatePhoneAccess(control, inbound: inbound, epoch: epoch) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        // Callback errors can contain a URL. Keep details out of both
                        // the model and the durable/logged response.
                        try await stage(messages: ["I couldn't create phone access. Check phone setup in Steve on the Mac, then ask for a new link."], attachments: [], inbound: inbound, workspace: nil, permission: nil, epoch: epoch, control: true)
                    }
                    return
                }
                guard let automation else { throw UserAutomationError.invalid("Saved preferences and schedules are unavailable.") }
                let response: String
                do { response = try await UserControlExecutor.perform(control, inbound: inbound, store: automation, authorization: authorization, epoch: epoch, now: clockNow()) }
                catch { response = "I couldn't make that change: " + error.localizedDescription }
                try await stage(messages: [response], attachments: [], inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
                return
            }
            if relayRequest.action != .execute {
                if let run = scheduledRun { try await automation?.recordExecutionOutcome(id: run.id, outcome: .failed) }
                try await stage(messages: [relayRequest.userMessage ?? "I need one more detail before I can do that."], attachments: [], inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
                try check(epoch)
                try await savePair(chatGuid: chatGuid, workerThreadID: workerThreadID, relayThreadID: relayThreadID, workspace: workspace, permission: permission, settings: settings, messageGuid: first.guid, epoch: epoch)
                return
            }

            guard let requestedWorkerPrompt = relayRequest.workerPrompt else {
                throw AgentEnvelopeError.invalidPayload("execute request did not include workerPrompt")
            }
            let workerInput = (existing?.relayThreadID == nil
                ? StevePrompt.workerBootstrap(context) + "\n\n" + requestedWorkerPrompt
                : requestedWorkerPrompt) + savedContext + scheduledContext + capabilityContext
            func applyWorkerContextAction(_ action: WorkerContextAction, to threadID: String) async throws -> String {
                guard action != .reuse else { return threadID }
                try check(epoch)
                switch action {
                case .reuse:
                    return threadID
                case .compact:
                    SteveLog.write("Gateway relay requested worker compaction chat=\(chatGuid) thread=\(threadID)")
                    try await codex.compactThread(threadID: threadID)
                    return threadID
                case .fresh:
                    let freshThreadID = try await codex.startThread(
                        cwd: workspace,
                        permissionProfile: permission,
                        model: settings.model,
                        developerInstructions: workerInstructions,
                        isRelay: false
                    )
                    try check(epoch)
                    try await savePair(
                        chatGuid: chatGuid,
                        workerThreadID: freshThreadID,
                        relayThreadID: relayThreadID,
                        workspace: workspace,
                        permission: permission,
                        settings: settings,
                        messageGuid: first.guid,
                        epoch: epoch,
                        executionState: "running"
                    )
                    SteveLog.write("Gateway relay reset worker context chat=\(chatGuid) oldThread=\(threadID) newThread=\(freshThreadID)")
                    return freshThreadID
                }
            }

            func runWorker(on threadID: String) async throws -> (envelope: WorkerResultEnvelope, artifacts: [WorkerArtifactEnvelope]) {
                SteveLog.write("Gateway worker execution phase started chat=\(chatGuid) thread=\(threadID)")
                workerStarted = true
                let result = try await runTurn(on: threadID, input: workerInput, attachments: attachmentPaths, isWorker: true)
                let envelope = try AgentEnvelopeParser.workerResult(from: result.text)
                return (envelope, try verifiedArtifacts(from: envelope, workspace: workspace))
            }

            func requestDelivery(for execution: (envelope: WorkerResultEnvelope, artifacts: [WorkerArtifactEnvelope]), recoveryAttempted: Bool) async throws -> DeliveryPlanEnvelope {
                let artifactSummary = execution.artifacts.map { ["id": $0.id, "caption": $0.caption ?? "", "mimeType": $0.mimeType ?? ""] }
                let recoveryState = recoveryAttempted
                    ? "\n\nRECOVERY_ATTEMPTED: true. Do not request another worker recovery."
                    : ""
                let deliveryInput = "WORKER_RESULT_JSON:\n\(try encodeJSON(execution.envelope))\n\nVERIFIED_ARTIFACTS_JSON:\n\(try encodeJSON(artifactSummary))\(recoveryState)\n\nCreate the user-facing delivery plan now. Select attachment ids only when useful."
                SteveLog.write("Gateway relay delivery phase started chat=\(chatGuid) artifacts=\(execution.artifacts.count) recoveryAttempted=\(recoveryAttempted)")
                let deliveryResult = try await runTurn(on: relayThreadID, input: deliveryInput)
                return try AgentEnvelopeParser.deliveryPlan(from: deliveryResult.text)
            }

            let activeWorkerThreadID = try await applyWorkerContextAction(relayRequest.workerContextAction ?? .reuse, to: workerThreadID)
            let execution = try await runWorker(on: activeWorkerThreadID)
            if let run = scheduledRun { try await automation?.recordExecutionOutcome(id: run.id, outcome: execution.envelope.status == .completed ? .succeeded : .failed) }
            let deliveryPlan = try await requestDelivery(for: execution, recoveryAttempted: true)
            guard deliveryPlan.recovery == nil else {
                throw AgentEnvelopeError.invalidPayload("Worker recovery requires a new explicit request; completed actions cannot be replayed")
            }
            let artifactMap = Dictionary(uniqueKeysWithValues: execution.artifacts.map { ($0.id, $0) })
            // Resolve the entire delivery plan before making any transport call.
            let selected = try deliveryPlan.attachments.map { requested -> (String, String) in
                guard let artifact = artifactMap[requested.artifactID] else {
                    throw AgentEnvelopeError.invalidPayload("delivery selected unknown artifact \(requested.artifactID)")
                }
                return (artifact.path, requested.caption ?? artifact.caption ?? "")
            }
            try await stage(messages: deliveryPlan.messages, attachments: selected, inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
            try check(epoch)
            try await savePair(chatGuid: chatGuid, workerThreadID: activeWorkerThreadID, relayThreadID: relayThreadID, workspace: workspace, permission: permission, settings: settings, messageGuid: first.guid, epoch: epoch)
        } catch {
            // A failed envelope or lost completion may follow successful actions.
            // Record uncertainty; never rerun the original worker request.
            if self.epoch == epoch && !Task.isCancelled {
                try? await store.finishInbox(inbound.map(\.guid), state: workerStarted ? "uncertain" : "failed")
                SteveLog.write("Gateway execution needs review error=\(error.localizedDescription)")
                let notice = workerStarted
                    ? "I couldn't verify the final outcome. Some actions may have completed. I haven't retried the task."
                    : "I couldn't start that task. \(error.localizedDescription)"
                do {
                    let settings = try await store.getSettings() ?? defaultSettings()
                    try check(epoch)
                    // The notice has its own identity; sending it must not turn the
                    // original uncertain action into a completed request.
                    let part = SteveStore.OutboundPart(id: "outcome:" + first.guid, chatGuid: first.chatGuid, recipient: first.senderHandle, replyTo: first.guid, inboxGUIDs: [], text: notice, attachmentPath: nil, workspace: settings.workspaceRoot, permission: settings.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
                    try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: epoch)
                    scheduleDelivery()
                } catch { SteveLog.write("Gateway outcome notice unavailable error=\(error.localizedDescription)") }
            }
        }
    }
    func pendingApproval() -> PendingApprovalSnapshot? {
        approvals.values.filter { $0.snapshot.expiresAt > Date() }.map(\.snapshot).sorted { $0.expiresAt < $1.expiresAt }.first
    }
    func resolveApproval(id: String, decision: CodexApprovalDecision) async throws {
        guard running, let approval = approvals[id], approval.snapshot.expiresAt > Date(),
              approval.binding.epoch == epoch, !paused, !changingBoundary,
              activeWorker?.threadID == approval.snapshot.threadID, activeWorker?.turnID == approval.snapshot.turnID else {
            throw RPCError(message: "That approval has expired or is no longer active.")
        }
        let trusted = try await store.trustedConversation()
        guard running, let current = approvals[id], current.binding.epoch == epoch,
              current.snapshot.expiresAt > Date(), !paused, !changingBoundary,
              trusted?.chatGuid == approval.binding.message.chatGuid,
              normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(approval.binding.message.senderHandle) else {
            throw RPCError(message: "The approval's paired conversation is no longer active.")
        }
        finishApproval(id: id, decision: decision)
    }
    private func finishApproval(id: String, decision: CodexApprovalDecision) {
        guard let approval = approvals.removeValue(forKey: id) else { return }
        approval.expiryTask.cancel()
        approval.continuation.resume(returning: decision)
    }
    private func cancelApprovals() {
        for id in Array(approvals.keys) { finishApproval(id: id, decision: .cancel) }
    }
    private func phoneApproval(_ text: String, message: SteveInboundMessage) -> (String, CodexApprovalDecision)? {
        let eligible = approvals.values.filter { $0.binding.message.chatGuid == message.chatGuid && normalizeHandle($0.binding.message.senderHandle) == normalizeHandle(message.senderHandle) && $0.snapshot.expiresAt > Date() }
        let fields = text.split(separator: " ").map(String.init)
        if fields.count == 2, let decision: CodexApprovalDecision = ["approve": .accept, "deny": .decline][fields[0]], let item = eligible.first(where: { $0.snapshot.id.lowercased() == fields[1] }) {
            return (item.snapshot.id, decision)
        }
        if eligible.count == 1, eligible[0].snapshot.promptDelivered, let decision: CodexApprovalDecision = ["yes": .accept, "no": .decline][text] { return (eligible[0].snapshot.id, decision) }
        return nil
    }
    private func queuePrivatePhoneAccess(_ control: RelayUserControl, inbound: [SteveInboundMessage], epoch: String) async throws {
        try control.validate()
        guard let source = inbound.first(where: { !$0.guid.hasPrefix("schedule:") && $0.text.contains(control.userQuote) }),
              let phoneAccessHandler else { throw RPCError(message: "Phone access is unavailable.") }
        try check(epoch, control: true)
        let trusted = try await store.trustedConversation()
        guard trusted?.chatGuid == source.chatGuid, normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(source.senderHandle) else { throw CancellationError() }
        let expiresAt = clockNow().addingTimeInterval(120)
        let url = try await phoneAccessHandler()
        try check(epoch, control: true)
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.absoluteString.count <= 4096, clockNow() < expiresAt else {
            throw RPCError(message: "Phone access is unavailable.")
        }
        // Never stage this bearer URL in the durable outbox or send it to Codex.
        // Keep its inbox running until sent: restart treats it as uncertain.
        privatePhoneDeliveries.append(.init(message: source, inboxGUIDs: inbound.map(\.guid), url: url, epoch: epoch, expiresAt: expiresAt))
        scheduleDelivery()
    }
    private func sendPrivatePhoneAccess(_ delivery: PrivatePhoneDelivery) async {
        var invokedTransport = false
        do {
            try check(delivery.epoch, control: true)
            let trusted = try await store.trustedConversation()
            try check(delivery.epoch, control: true)
            guard clockNow() < delivery.expiresAt,
                  trusted?.chatGuid == delivery.message.chatGuid,
                  normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(delivery.message.senderHandle) else { throw CancellationError() }
            invokedTransport = true
            try await messages.sendText(chatGUID: delivery.message.chatGuid, recipient: delivery.message.senderHandle,
                text: "Open this private one-use link in Safari promptly; it expires two minutes after your request. Opening it pauses Steve; sending the link does not. This link stays in your Messages history.\n" + delivery.url.absoluteString,
                replyTo: delivery.message.guid)
            try await store.finishInbox(delivery.inboxGUIDs, state: "completed")
        } catch {
            // An invoked Messages transport may have delivered the secret. Never
            // retry it or persist its URL/error; the user can request a fresh link.
            try? await store.finishInbox(delivery.inboxGUIDs, state: invokedTransport ? "uncertain" : "cancelled")
        }
    }
    private func requestApproval(_ request: CodexApprovalRequest) async -> CodexApprovalDecision {
        // Even an unsupported prompt may precede authentication. Do not retain
        // demonstration frames while a human decision is outstanding.
        capturePermit.invalidate()
        guard running, request.method == "mcpServer/elicitation/request", request.mode == "url" || request.isEmptyBrowserOriginForm || request.nativeAppName != nil, let binding = activeWorker,
              binding.epoch == epoch, binding.threadID == request.threadID, binding.turnID == request.turnID,
              binding.turnID != nil, !paused, !changingBoundary, request.expiresAt > Date() else { return .cancel }
        let originHost: String?
        let safeMessage: String
        if let appName = request.nativeAppName {
            guard request.mode == "form", !appName.isEmpty, appName.count <= 200,
                  !appName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .cancel }
            originHost = nil
            safeMessage = "Allow Computer Use to use \(appName) for this session?"
        } else {
            guard let origin = request.origin.flatMap({ URLComponents(string: $0) }), origin.scheme?.lowercased() == "https",
                  let host = origin.host, !host.isEmpty, origin.url != nil, origin.user == nil, origin.password == nil else { return .cancel }
            originHost = host
            // Authentication URLs can carry credentials. Only display their host.
            safeMessage = request.message.replacingOccurrences(of: #"https?://[^\s<>]+"#, with: "[link withheld]", options: [.regularExpression, .caseInsensitive])
        }
        let id = String(UUID().uuidString.prefix(8)).uppercased()
        func identifier(_ value: String?) -> String? {
            guard let value, value.count <= 100, value.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return nil }
            return value
        }
        let snapshot = PendingApprovalSnapshot(id: id, threadID: binding.threadID, turnID: binding.turnID!, message: String(safeMessage.prefix(1200)), originHost: originHost, connector: identifier(request.connector), tool: identifier(request.tool), expiresAt: request.expiresAt)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.running, !Task.isCancelled, self.epoch == binding.epoch else { continuation.resume(returning: .cancel); return }
                let expiry = Task {
                    try? await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow)))
                    if !Task.isCancelled { self.finishApproval(id: id, decision: .cancel) }
                }
                approvals[id] = Approval(snapshot: snapshot, binding: binding, continuation: continuation, expiryTask: expiry)
                Task { await self.sendApprovalPrompt(snapshot, binding: binding) }
            }
        } onCancel: {
            Task { await self.finishApproval(id: id, decision: .cancel) }
        }
    }
    private func sendApprovalPrompt(_ approval: PendingApprovalSnapshot, binding: WorkerBinding) async {
        do {
            try check(binding.epoch)
            guard approvals[approval.id] != nil else { return }
            let context = [approval.connector, approval.tool, approval.originHost].compactMap { $0 }.joined(separator: " · ")
            let text = "Approval needed\(context.isEmpty ? "" : " (" + context + ")"): \(approval.message)\nReply approve \(approval.id) or deny \(approval.id). This approval expires shortly."
            let part = SteveStore.OutboundPart(id: "approval:" + approval.id, chatGuid: binding.message.chatGuid, recipient: binding.message.senderHandle, replyTo: binding.message.guid, inboxGUIDs: [], text: text, attachmentPath: nil, workspace: nil, permission: nil, isControl: true)
            try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: binding.epoch)
            scheduleDelivery()
        } catch { finishApproval(id: approval.id, decision: .cancel) }
    }
    private func turnStarted(epoch: String, threadID: String, turnID: String) async {
        if activeWorker?.epoch == epoch && activeWorker?.threadID == threadID { activeWorker?.turnID = turnID }
        if self.epoch != epoch || paused || changingBoundary {
            try? await codex.interruptTurn(threadID: threadID, turnID: turnID)
        }
    }
    private func savePair(chatGuid: String, workerThreadID: String, relayThreadID: String, workspace: String, permission: String, settings: Settings, messageGuid: String, epoch: String, executionState: String = "idle") async throws {
        try Task.checkCancellation()
        try await store.saveAgentSession(.init(chatGuid: chatGuid, threadID: workerThreadID, relayThreadID: relayThreadID, relayPromptVersion: StevePrompt.relayPromptVersion, workspacePath: workspace, permissionProfile: permission, model: settings.model, effort: settings.effort, lastMessageGuid: messageGuid, executionState: executionState, updatedAt: Date()), expectedEpoch: epoch)
    }
    private func stage(messages values: [String], attachments: [(String, String)], inbound: [SteveInboundMessage], workspace: String?, permission: String?, epoch: String, control: Bool = false) async throws {
        guard let first = inbound.first else { return }
        try check(epoch, control: control)
        let guids = inbound.map(\.guid)
        var parts = values.flatMap { StevePrompt.plainText($0) }.map {
            SteveStore.OutboundPart(id: UUID().uuidString, chatGuid: first.chatGuid, recipient: first.senderHandle, replyTo: first.guid, inboxGUIDs: guids, text: $0, attachmentPath: nil, workspace: workspace, permission: permission, isControl: control)
        }
        parts += attachments.map {
            SteveStore.OutboundPart(id: UUID().uuidString, chatGuid: first.chatGuid, recipient: first.senderHandle, replyTo: first.guid, inboxGUIDs: guids, text: $0.1, attachmentPath: $0.0, workspace: workspace, permission: permission, isControl: control)
        }
        try await store.stageDelivery(parts, inboxGUIDs: guids, expectedEpoch: epoch)
        scheduleDelivery()
    }
    private func send(_ part: SteveStore.OutboundPart, epoch: String) async throws {
        let trusted = try await store.trustedConversation()
        let settings = try await store.getSettings() ?? defaultSettings()
        try check(epoch, control: part.isControl)
        if part.id.hasPrefix("approval:"), approvals[String(part.id.dropFirst("approval:".count))] == nil {
            try await store.failOutboundPart(part)
            return
        }
        do {
            guard trusted?.chatGuid == part.chatGuid, normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(part.recipient),
                  part.workspace == nil || part.workspace == settings.workspaceRoot,
                  part.permission == nil || part.permission == settings.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) else {
                throw RPCError(message: "Delivery boundary changed")
            }
            let remaining = try await store.pendingOutbox().filter { $0.id == part.id || !Set($0.inboxGUIDs).isDisjoint(with: part.inboxGUIDs) }
            for candidate in remaining {
                guard let path = candidate.attachmentPath, let workspace = candidate.workspace else { continue }
                _ = try verifiedArtifacts(from: .init(schemaVersion: AgentProtocol.schemaVersion, kind: "worker_result", status: .completed, summary: "", userQuestion: nil, artifacts: [.init(id: "delivery", path: path, caption: nil, mimeType: nil)]), workspace: workspace)
            }
        } catch {
            try await store.failOutboundPart(part)
            if part.id.hasPrefix("approval:") { finishApproval(id: String(part.id.dropFirst("approval:".count)), decision: .cancel) }
            SteveLog.write("Gateway quarantined undeliverable result error=\(error.localizedDescription)")
            return
        }
        guard try await store.beginSending(part.id) else { return }
        do {
            try check(epoch, control: part.isControl)
            if let path = part.attachmentPath {
                try await messages.sendAttachment(chatGUID: part.chatGuid, recipient: part.recipient, path: path, caption: part.text, replyTo: part.replyTo)
            } else {
                try await messages.sendText(chatGUID: part.chatGuid, recipient: part.recipient, text: part.text, replyTo: part.replyTo)
            }
            try await store.finishSending(part, sent: true)
            if part.id.hasPrefix("approval:") {
                approvals[String(part.id.dropFirst("approval:".count))]?.snapshot.promptDelivered = true
            }
        } catch {
            try? await store.finishSending(part, sent: false)
            if part.id.hasPrefix("approval:") { finishApproval(id: String(part.id.dropFirst("approval:".count)), decision: .cancel) }
            if Task.isCancelled || self.epoch != epoch { throw CancellationError() }
            SteveLog.write("Gateway send outcome uncertain; not retrying error=\(error.localizedDescription)")
        }
    }
    func verifiedArtifacts(from envelope: WorkerResultEnvelope, workspace: String) throws -> [WorkerArtifactEnvelope] {
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL.path
        var seen = Set<String>()
        return try envelope.artifacts.map { item in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = URL(fileURLWithPath: item.path).resolvingSymlinksInPath().standardizedFileURL
            let regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            guard !id.isEmpty, seen.insert(id).inserted, url.path.hasPrefix(root + "/"), regular, FileManager.default.isReadableFile(atPath: url.path) else {
                throw AgentEnvelopeError.invalidPayload("artifact is not a readable workspace file")
            }
            return .init(id: id, path: url.path, caption: item.caption, mimeType: item.mimeType)
        }
    }
    private func encodeJSON<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
}

actor SteveRuntime {
    let store: SteveStore
    let messages: MessagesService
    let codex: CodexAppServerClient
    let gateway: GatewayCoordinator
    private var settings: Settings
    private var account: AccountSnapshot?
    private var models: [ModelEntry] = []
    private var permissions: [PermissionProfile] = []
    private var usage: Usage?
    private var lastError: String?

    init() throws {
        let store = try SteveStore.openDefault()
        let messages = MessagesService()
        let codex = CodexAppServerClient()
        self.store = store
        self.messages = messages
        self.codex = codex
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        self.gateway = GatewayCoordinator(store: store, messages: messages, codex: codex, automation: automation)
        self.settings = try awaitBlocking { try await store.getSettings() } ?? defaultSettings()
    }

    func start() async {
        do {
            if settings.workspaceRoot == nil {
                try FileManager.default.createDirectory(at: StevePaths.workspaceDirectory, withIntermediateDirectories: true)
                settings.workspaceRoot = StevePaths.workspaceDirectory.path
                try await store.saveSettings(settings)
            }
            if let workspace = settings.workspaceRoot { try FileManager.default.createDirectory(atPath: workspace, withIntermediateDirectories: true) }
            await gateway.start()
            try await refresh()
        } catch { lastError = error.localizedDescription; SteveLog.write("Steve startup failed error=\(error.localizedDescription)") }
    }

    func setPhoneAccessHandler(_ handler: @escaping @Sendable () async throws -> URL) async {
        await gateway.setPhoneAccessHandler(handler)
    }

    func stop() async { await gateway.stop(); await codex.stop() }

    func snapshot() async -> Snapshot {
        let paused = await gateway.isPaused()
        let messagesError = await gateway.transportError
        let uncertain = (try? await store.uncertainWorkCount()) ?? 0
        let connected = account?.account != nil
        let detail = lastError ?? messagesError ?? (uncertain > 0 ? "Some work has an uncertain outcome and was not retried." : nil) ?? (connected ? "" : "Sign in to Codex to continue.")
        let dependency = Dependency(name: "codex", available: account != nil || lastError == nil, detail: detail)
        let trusted = try? await store.trustedConversation()
        let pairing = try? await store.pairingChallenge()
        return Snapshot(
            status: Status(state: paused || !detail.isEmpty ? "Degraded" : "Ready", detail: detail, connected: connected),
            settings: settings,
            paused: paused,
            dependencies: [dependency, Dependency(name: "messages", available: messagesError == nil, detail: messagesError ?? "")],
            transportMode: "native-messages",
            account: account,
            models: models,
            permissions: permissions,
            usage: usage,
            trustedConversation: trusted,
            pairing: pairing
        )
    }

    func refresh() async throws {
        settings = try await store.getSettings() ?? settings
        do {
            account = try await codex.accountRead()
            lastError = nil
            if account?.account != nil {
                models = (try? await codex.listModels()) ?? models
                if let workspace = settings.workspaceRoot { permissions = (try? await codex.listPermissionProfiles(cwd: workspace)) ?? permissions }
                usage = try? await codex.rateLimitsRead()
            }
        } catch {
            lastError = error.localizedDescription
            SteveLog.write("Codex refresh failed error=\(error.localizedDescription)")
        }
    }

    func phoneAccessBoundary() async throws -> PhoneAccessBoundary { try await gateway.phoneAccessBoundary() }
    func beginPhoneTakeover(expectedBoundary: PhoneAccessBoundary) async throws -> String { try await gateway.beginPhoneTakeover(expectedBoundary: expectedBoundary) }
    func phoneTakeoverIsActive(token: String) async -> Bool { await gateway.phoneTakeoverIsActive(token: token) }
    func endPhoneTakeover(token: String, resume: Bool) async throws { try await gateway.endPhoneTakeover(token: token, resume: resume) }

    func pendingApproval() async -> PendingApprovalSnapshot? { await gateway.pendingApproval() }
    func resolveApproval(id: String, decision: CodexApprovalDecision) async throws { try await gateway.resolveApproval(id: id, decision: decision) }

    nonisolated var capturePermit: SteveCapturePermit { gateway.capturePermit }
    func authorizeVideo() async throws -> SteveVideoAuthorization { try await gateway.authorizeVideo() }
    func loginStart() async throws -> LoginSnapshot {
        try await gateway.setPaused(true)
        return try await codex.loginStart()
    }

    func configureWorkspace(_ path: String) async throws {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        await gateway.beginBoundaryChange()
        var next = settings
        next.workspaceRoot = url.path
        settings = next
        do { try await store.saveSettings(next) } catch { throw error }
        await gateway.endBoundaryChange()
        try await refresh()
    }

    func selectPermission(_ value: String) async throws {
        let value = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard ["read-only", "workspace-write", "danger-full-access"].contains(value) else { throw RPCError(message: "Unsupported permission profile: \(value)") }
        guard let workspace = settings.workspaceRoot else { throw RPCError(message: "Choose a workspace first.") }
        let catalog = try await codex.listPermissionProfiles(cwd: workspace)
        guard catalog.contains(where: { $0.id.trimmingCharacters(in: CharacterSet(charactersIn: ":")) == value && $0.allowed }) else { throw RPCError(message: "The selected permission profile is not available from Codex.") }
        permissions = catalog
        await gateway.beginBoundaryChange()
        settings.permissionProfile = value
        try await store.saveSettings(settings)
        await gateway.endBoundaryChange()
    }

    func selectModel(_ value: String) async throws {
        let catalog = try await codex.listModels()
        guard catalog.contains(where: { $0.id == value || $0.model == value }) else { throw RPCError(message: "The selected model is not available from Codex.") }
        await gateway.beginBoundaryChange()
        models = catalog; settings.model = value; try await store.saveSettings(settings)
        await gateway.endBoundaryChange()
    }
    func selectEffort(_ value: String) async throws {
        let catalog = try await codex.listModels()
        guard let model = catalog.first(where: { $0.id == settings.model || $0.model == settings.model }), model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == value }) else { throw RPCError(message: "This reasoning effort is not supported by the selected model.") }
        await gateway.beginBoundaryChange()
        models = catalog; settings.effort = value; try await store.saveSettings(settings)
        await gateway.endBoundaryChange()
    }
    func setPaused(_ value: Bool) async throws { try await gateway.setPaused(value) }

    func createPairing() async throws -> PairingSnapshot {
        let accounts = try await messages.discoverAccounts()
        guard let address = accounts.first?.address, !address.isEmpty else { throw RPCError(message: "No Messages account was found. Add Steve under Full Disk Access and relaunch.") }
        let encoded = address.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? address
        let challenge = PairingChallenge(
            code: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased(),
            expiresAtMs: UInt64(Date().timeIntervalSince1970 * 1_000) + 10 * 60 * 1_000,
            receiveAddress: address,
            uri: "im:\(encoded)",
            messageURI: "sms:\(encoded)"
        )
        try await store.savePairingChallenge(challenge)
        return PairingSnapshot(addresses: accounts.map { ReceiveAddress(address: $0.address, label: $0.label) }, challenge: challenge, trustedConversation: try await store.trustedConversation(), icloudAccount: address, messagesError: nil)
    }

    func disconnectPhone() async throws { await gateway.beginBoundaryChange(); try await store.saveTrustedConversation(nil); try await store.savePairingChallenge(nil); await gateway.endBoundaryChange() }
}

private func normalizeHandle(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.contains("@") { return trimmed }
    return trimmed.filter { $0.isNumber || $0 == "+" }
}

private func defaultSettings() -> Settings {
    Settings(displayName: "Steve", model: "gpt-5.6-sol", effort: "low", workspaceRoot: StevePaths.workspaceDirectory.path)
}

private func awaitBlocking<T>(_ operation: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<T, Error>!
    Task {
        do { result = .success(try await operation()) }
        catch { result = .failure(error) }
        semaphore.signal()
    }
    semaphore.wait()
    return try result.get()
}
