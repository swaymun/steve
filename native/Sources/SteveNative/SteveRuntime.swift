import Foundation
import PDFKit

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
    var requiresConnectionSetup = false
}

struct PhoneAccessBoundary: Sendable, Equatable {
    let epoch: String
    let chatGuid: String
    let senderHandle: String
    let workspace: String
    let permission: String
    var taskID: String? = nil
    var runID: String? = nil
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
    func startThread(cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool, serviceTier: SteveServiceTier) async throws -> String
    func resumeThread(threadID: String, cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool, serviceTier: SteveServiceTier) async throws
    func compactThread(threadID: String) async throws
    func runTurn(threadID: String, text: String, attachmentPaths: [String], workspace: String?, model: String, effort: String, serviceTier: SteveServiceTier, onTurnStarted: @escaping @Sendable (String) async -> Void) async throws -> CodexTurnResult
    func runTurn(threadID: String, text: String, attachmentPaths: [String], workspace: String?, model: String, effort: String, serviceTier: SteveServiceTier, onProgress: (@Sendable (CodexTurnEvent) async -> Void)?, onTurnStarted: @escaping @Sendable (String) async -> Void) async throws -> CodexTurnResult
    func interruptTurn(threadID: String, turnID: String) async throws
    func steerTurn(threadID: String, expectedTurnID: String, text: String, attachmentPaths: [String]) async throws
    func operatorThread(threadID: String?, cwd: String, permissionProfile: String, profile: AgentModelProfile, instructions: String, mode: OperatorMode, maxHelpers: Int) async throws -> String
    func stopDescendants(threadID: String) async throws
    func quiesceThread(threadID: String) async throws
    func relayProfile(settings: Settings) async throws -> AgentModelProfile
}
extension GatewayCodexClient {
    func runTurn(threadID: String, text: String, attachmentPaths: [String], workspace: String?, model: String, effort: String, serviceTier: SteveServiceTier, onProgress: (@Sendable (CodexTurnEvent) async -> Void)?, onTurnStarted: @escaping @Sendable (String) async -> Void) async throws -> CodexTurnResult {
        try await runTurn(threadID: threadID, text: text, attachmentPaths: attachmentPaths, workspace: workspace, model: model, effort: effort, serviceTier: serviceTier, onTurnStarted: onTurnStarted)
    }
    func steerTurn(threadID: String, expectedTurnID: String, text: String, attachmentPaths: [String]) async throws { throw RPCError(message: "Active task steering is unavailable") }
    func operatorThread(threadID: String?, cwd: String, permissionProfile: String, profile: AgentModelProfile, instructions: String, mode: OperatorMode, maxHelpers: Int) async throws -> String {
        if let threadID { try await resumeThread(threadID: threadID, cwd: cwd, permissionProfile: permissionProfile, model: profile.model, developerInstructions: instructions, isRelay: false, serviceTier: profile.serviceTier); return threadID }
        return try await startThread(cwd: cwd, permissionProfile: permissionProfile, model: profile.model, developerInstructions: instructions, isRelay: false, serviceTier: profile.serviceTier)
    }
    func stopDescendants(threadID: String) async throws {}
    func quiesceThread(threadID: String) async throws {}
    func relayProfile(settings: Settings) async throws -> AgentModelProfile { .init(model: settings.relayModel ?? settings.model, effort: settings.relayModel == nil ? settings.effort : settings.relayEffort, serviceTier: settings.relayServiceTier) }
}
extension CodexAppServerClient: GatewayCodexClient {}

actor GatewayCoordinator {
    private let store: SteveStore
    private let messages: any GatewayMessages
    private let codex: any GatewayCodexClient
    private let debounce: Duration
    private let retryDelay: Duration
    private let acknowledgementDelay: Duration
    private var pendingProgressRuns = Set<String>()
    private let takeoverLifetime: TimeInterval
    private let automation: SteveUserAutomationStore?
    private let schedulerInterval: Duration
    private let clockNow: @Sendable () -> Date
    private var schedulerTask: Task<Void, Never>?
    private var pollingSchedules = false
    private var watcherTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    private var senderTask: Task<Void, Never>?
    // Scheduling slots may be replaced on invalidation; retain every owned
    // database-using task until it actually finishes so stop can join it.
    private var inFlightTasks: [UUID: Task<Void, Never>] = [:]
    private struct PrivatePhoneDelivery {
        let message: SteveInboundMessage
        let inboxGUIDs: [String]
        let url: URL
        let epoch: String
        let expiresAt: Date
        var taskID: String? = nil
        var runID: String? = nil
    }
    private var issuingPhoneTask: (id: String, runID: String)?
    private var privatePhoneDeliveries: [PrivatePhoneDelivery] = []
    private var phoneAccessHandler: (@Sendable () async throws -> URL)?
    func setPhoneAccessHandler(_ handler: @escaping @Sendable () async throws -> URL) { phoneAccessHandler = handler }
    private var epoch = UUID().uuidString
    private var running = false
    private var changingBoundary = false
    private var connectionHandoffToken: String?
    private struct WorkerBinding {
        let epoch: String
        let threadID: String
        let taskID: String
        var turnID: String?
        let message: SteveInboundMessage
    }
    private struct Approval {
        var snapshot: PendingApprovalSnapshot
        let binding: WorkerBinding
        let continuation: CheckedContinuation<CodexApprovalDecision, Never>
        let expiryTask: Task<Void, Never>
        let connectionURL: URL?
        var promptQueued = false
    }
    private struct TakeoverGuard {
        let token: String
        let epoch: String
        let chatGuid: String
        let senderHandle: String
        let workspace: String
        let permission: String
        let expiresAt: Date
        var taskID: String? = nil
        var runID: String? = nil
    }
    private var takeover: TakeoverGuard?
    private var takeoverReservation: String?
    private var takeoverExpiryTask: Task<Void, Never>?
    private var activeWorkers: [String: WorkerBinding] = [:]
    private var operatorRuns: [String: Task<Void, Never>] = [:]
    private var computerOwner: String?
    private var loginReservation: (taskID: String, runID: String, expiresAt: Date)?
    private var steeringTasks: [String: Task<Void, Never>] = [:]
    private var approvals: [String: Approval] = [:]
    private var phoneApprovalOrder: [String] = []
    private var initialized = false
    nonisolated let capturePermit = SteveCapturePermit()
    private var paused = false
    private var pauseTransitionInProgress = false
    private var configuringOwner = false
    private(set) var transportError: String? = "Messages watcher has not started."

    init(store: SteveStore, messages: any GatewayMessages, codex: any GatewayCodexClient, debounce: Duration = .milliseconds(1500), retryDelay: Duration = .seconds(5), takeoverLifetime: TimeInterval = 600, acknowledgementDelay: Duration = .seconds(10), automation: SteveUserAutomationStore? = nil, schedulerInterval: Duration = .seconds(1), clockNow: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.messages = messages; self.codex = codex
        self.debounce = debounce; self.retryDelay = retryDelay
        self.takeoverLifetime = takeoverLifetime
        self.acknowledgementDelay = acknowledgementDelay
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
                    guard await receive(message) else { throw RPCError(message: "Messages intake could not be saved; reconnecting from the last checkpoint.") }
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
        while !inFlightTasks.isEmpty {
            let tasks = Array(inFlightTasks.values)
            for task in tasks { task.cancel() }
            for task in tasks { await task.value }
        }
        transportError = "Messages watcher is stopped."
    }
    @discardableResult
    func invalidate(cancelQueued: Bool = true, takeoverReservation reservation: String? = nil) async -> String {
        await invalidateResult(cancelQueued: cancelQueued, takeoverReservation: reservation).epoch
    }
    private func invalidateResult(cancelQueued: Bool = true, takeoverReservation reservation: String? = nil) async -> (epoch: String, persisted: Bool) {
        capturePermit.invalidate()
        connectionHandoffToken = nil
        let invalidatedEpoch = UUID().uuidString
        epoch = invalidatedEpoch
        let keepPaused = takeover != nil || takeoverReservation != nil || reservation != nil
        takeoverExpiryTask?.cancel(); takeoverExpiryTask = nil
        takeover = nil
        takeoverReservation = reservation
        if keepPaused { paused = true }
        cancelApprovals()
        for task in inFlightTasks.values { task.cancel() }
        privatePhoneDeliveries.removeAll()
        activeWorkers.removeAll()
        let cancelledOperators = Array(operatorRuns.values)
        for run in cancelledOperators { run.cancel() }
        operatorRuns.removeAll()
        for task in steeringTasks.values { task.cancel() }
        steeringTasks.removeAll()
        computerOwner = nil
        loginReservation = nil
        workTask?.cancel(); workTask = nil
        senderTask?.cancel(); senderTask = nil
        var persisted = true
        do {
            if keepPaused { try await store.savePaused(true) }
            try await store.invalidateWork(cancelQueued: cancelQueued, epoch: invalidatedEpoch)
        }
        catch { persisted = false; changingBoundary = true; transportError = error.localizedDescription }
        await codex.stop()
        for run in cancelledOperators { await run.value }
        return (invalidatedEpoch, persisted)
    }
    func beginBoundaryChange() async {
        _ = await prepareBoundaryChange()
    }
    private func prepareBoundaryChange() async -> Bool {
        changingBoundary = true
        let invalidation = await invalidateResult()
        guard invalidation.persisted else { return false }
        do {
            try await automation?.revokeScheduleAuthorization(now: clockNow())
            return true
        } catch {
            transportError = "Could not revoke schedule authorization: " + error.localizedDescription
            return false
        }
    }
    func beginSettingsBoundaryChange() async throws {
        guard await prepareBoundaryChange() else {
            throw RPCError(message: transportError ?? "Could not prepare the settings boundary.")
        }
    }
    func abortSettingsBoundaryChange(_ error: Error) {
        // Invalidation and schedule revocation already succeeded, so the old
        // persisted settings remain authoritative and may safely be retried.
        // The caller surfaces the error. Do not leave a stale transport error
        // after a later successful retry, or schedule work from this failure.
        SteveLog.write("Could not save settings: " + error.localizedDescription)
        changingBoundary = false
    }
    func endBoundaryChange() { changingBoundary = false; scheduleWork() }
    func boundaryChangeIsActive() -> Bool { changingBoundary }
    func agentSettingsDidChange() { scheduleWork() }

    func configureOwner(address: String, receiveAddress: String) async throws {
        guard !configuringOwner, !changingBoundary else { throw RPCError(message: "Connection settings are still changing. Try again in a moment.") }
        configuringOwner = true
        defer { configuringOwner = false }
        let address = try SteveOnboarding.ownerAddress(address)
        if let trusted = try await store.trustedConversation() {
            guard normalizeHandle(trusted.senderHandle) == address else {
                throw RPCError(message: "Another owner is connected. Disconnect that conversation in Steve before choosing a different owner.")
            }
            return // Repeated setup preserves the exact chat, work and grants.
        }
        if let existing = try await store.ownerSetup(), existing.address == address, existing.receiveAddress == receiveAddress { return }
        let rowID = try await messages.currentRowID()
        let owner = SteveOwnerSetup(id: UUID().uuidString, address: address, receiveAddress: receiveAddress, afterRowID: rowID, configuredAt: clockNow())
        try await beginSettingsBoundaryChange()
        do { try await store.saveOwnerSetup(owner); endBoundaryChange() }
        catch { abortSettingsBoundaryChange(error); throw error }
    }
    func setPaused(_ value: Bool) async throws {
        guard !pauseTransitionInProgress else {
            throw RPCError(message: "Steve is still finishing the previous pause or resume. Try again in a moment.")
        }
        pauseTransitionInProgress = true
        defer { pauseTransitionInProgress = false }
        guard value || (takeover == nil && takeoverReservation == nil) else {
            throw RPCError(message: "Finish phone control before resuming Steve.")
        }
        if !value, let token = connectionHandoffToken {
            // Cancel an opening queued on MainActor, or wait for its synchronous
            // open call to finish before the worker may resume.
            capturePermit.revoke(token)
            connectionHandoffToken = nil
        }
        paused = value
        if value { await invalidate(cancelQueued: true) }
        else {
            for var task in try await store.operatorTasks() where task.state == .interrupted && task.mode == .background && (task.recoveryAttempts ?? 0) < 1 {
                let previous = task.runID
                task.state = .queued; task.contextAction = .fresh; task.runID = UUID().uuidString
                task.recoveryAttempts = (task.recoveryAttempts ?? 0) + 1
                try await store.saveOperatorTask(task, expectedEpoch: epoch, expectedRunID: previous)
            }
        }
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
            permission: permission.trimmingCharacters(in: CharacterSet(charactersIn: ":")), taskID: issuingPhoneTask?.id, runID: issuingPhoneTask?.runID)
    }
    func beginPhoneTakeover(expectedBoundary: PhoneAccessBoundary? = nil) async throws -> String {
        let current = try await phoneAccessBoundary()
        var comparable = expectedBoundary
        comparable?.taskID = current.taskID; comparable?.runID = current.runID
        guard epoch == current.epoch, expectedBoundary == nil || comparable == current else {
            throw RPCError(message: "This phone link expired because Steve's access changed. Ask for a new link.")
        }
        guard running, !changingBoundary, takeover == nil, takeoverReservation == nil else {
            throw RPCError(message: "Steve is not ready to start phone control.")
        }
        if let id = expectedBoundary?.taskID {
            guard let task = try await store.operatorTask(id: id), task.runID == expectedBoundary?.runID,
                  task.state == .blocked, let handoff = task.handoff, handoff.blocker.reason == .signIn,
                  handoff.completedAt == nil, (handoff.linkIssuedAt ?? handoff.createdAt).addingTimeInterval(120) > clockNow() else { throw RPCError(message: "That sign-in task is no longer waiting.") }
        }
        guard epoch == current.epoch, running, !changingBoundary, takeover == nil, takeoverReservation == nil else {
            throw RPCError(message: "This phone link no longer matches Steve’s access.")
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
            takeover = TakeoverGuard(token: token, epoch: captured, chatGuid: trusted.chatGuid, senderHandle: normalizeHandle(trusted.senderHandle), workspace: workspace, permission: permission.trimmingCharacters(in: CharacterSet(charactersIn: ":")), expiresAt: Date().addingTimeInterval(takeoverLifetime), taskID: expectedBoundary?.taskID, runID: expectedBoundary?.runID)
            takeoverReservation = nil
            let expiryID = UUID()
            takeoverExpiryTask = Task {
                defer { self.inFlightTasks.removeValue(forKey: expiryID) }
                try? await Task.sleep(for: .seconds(takeoverLifetime))
                if !Task.isCancelled { await self.expirePhoneTakeover(token: token) }
            }
            inFlightTasks[expiryID] = takeoverExpiryTask
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
        let taskID = takeover?.taskID
        let runID = takeover?.runID
        takeoverExpiryTask?.cancel(); takeoverExpiryTask = nil
        capturePermit.revoke(token)
        takeover = nil
        if resume {
            if let taskID, let runID { try await continueHandoff(taskID: taskID, runID: runID, inbound: nil) }
            try await setPaused(false)
        }
    }
    private func expirePhoneTakeover(token: String) async {
        guard takeover?.token == token else { return }
        await invalidate(cancelQueued: false)
    }
    private func check(_ captured: String, control: Bool = false) throws {
        try Task.checkCancellation()
        guard running, epoch == captured, !changingBoundary, control || !paused else { throw CancellationError() }
    }
    @discardableResult
    func receive(_ message: SteveInboundMessage) async -> Bool {
        do {
            guard !message.isFromMe, !message.isGroup else { try await store.checkpoint(message.rowID); return true }
            guard !changingBoundary, !configuringOwner else { return false }
            var message = message
            if try await store.ownerSetup() != nil, message.service?.caseInsensitiveCompare("iMessage") != .orderedSame {
                try await store.checkpoint(message.rowID); return true
            }
            if let challenge = try await store.pairingChallenge(), challenge.expiresAtMs > UInt64(Date().timeIntervalSince1970 * 1000) {
                let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.caseInsensitiveCompare(challenge.code) == .orderedSame || text.caseInsensitiveCompare("/pair " + challenge.code) == .orderedSame {
                    guard !message.chatGuid.isEmpty, !normalizeHandle(message.senderHandle).isEmpty else { return true }
                    guard message.service?.caseInsensitiveCompare("iMessage") == .orderedSame else {
                        try await store.checkpoint(message.rowID); return true
                    }
                    let owner = try await store.ownerSetup()
                    if let owner, normalizeHandle(message.senderHandle) != owner.address {
                        try await store.checkpoint(message.rowID); return true
                    }
                    try await beginSettingsBoundaryChange()
                    do {
                        let bound = try await store.bindPairing(message, expected: challenge, owner: owner)
                        endBoundaryChange()
                        guard bound else { try await store.checkpoint(message.rowID); return true }
                    } catch { abortSettingsBoundaryChange(error); throw error }
                    guard try await store.acceptInbound(message) else { return true }
                    _ = try await store.claimInbox([message.guid])
                    let settings = try await store.getSettings() ?? defaultSettings()
                    try await stage(messages: [StevePrompt.pairingIntroduction(workspace: settings.workspaceRoot ?? StevePaths.workspaceDirectory.path, name: settings.displayName)], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
                    scheduleWork(); return true
                }
            }
            if try await store.trustedConversation() == nil,
               let owner = try await store.ownerSetup(), owner.accepts(message) {
                guard !changingBoundary, !configuringOwner else { return false }
                try await beginSettingsBoundaryChange()
                do {
                    message.beginsConversation = try await store.bindOwner(message, expected: owner)
                    endBoundaryChange()
                } catch {
                    abortSettingsBoundaryChange(error)
                    throw error
                }
            }
            guard let trusted = try await store.trustedConversation(), trusted.chatGuid == message.chatGuid, normalizeHandle(trusted.senderHandle) == normalizeHandle(message.senderHandle) else {
                try await store.checkpoint(message.rowID); return true
            }
            var accepted = message
            if let (id, _) = phoneApproval(message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), message: message) { accepted.approvalID = id }
            guard try await store.acceptInbound(accepted) else { return true }
            _ = try await handleControl(accepted)
            scheduleWork()
            return true
        } catch {
            SteveLog.write("Gateway intake failed error=\(error.localizedDescription)")
            return false
        }
    }
    private func handleControl(_ message: SteveInboundMessage) async throws -> Bool {
        let command = message.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["i'm signed in", "i’m signed in", "im signed in", "signed in", "done, continue", "done—continue", "done-continue"].contains(command.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))) {
            let pending = try await store.operatorTasks(chatGuid: message.chatGuid).filter {
                $0.state == .blocked && $0.handoff?.blocker.reason == .signIn && $0.handoff?.completedAt == nil
                    && normalizeHandle($0.senderHandle) == normalizeHandle(message.senderHandle)
            }
            if pending.count == 1, let task = pending.first {
                _ = try await store.claimInbox([message.guid])
                if let control = takeover {
                    guard control.taskID == task.id, control.runID == task.runID else {
                        try await stage(messages: ["Finish phone control, then tell me which sign-in to continue."], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
                        return true
                    }
                    try await endPhoneTakeover(token: control.token, resume: false)
                }
                try await continueHandoff(taskID: task.id, runID: task.runID, inbound: message)
                if paused { try await setPaused(false) }
                return true
            }
            if pending.count > 1 {
                _ = try await store.claimInbox([message.guid])
                try await stage(messages: ["Which sign-in is ready: " + pending.map(\.title).joined(separator: " or ") + "?"], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
                return true
            }
        }
        let fields = command.split(separator: " ")
        let pendingForSender = approvals.values.filter {
            $0.binding.message.chatGuid == message.chatGuid
                && normalizeHandle($0.binding.message.senderHandle) == normalizeHandle(message.senderHandle)
                && $0.snapshot.expiresAt > Date()
        }
        let connection = pendingForSender.first { pending in
            guard pending.snapshot.requiresConnectionSetup else { return false }
            if fields.count == 2, fields[0] == "approve" { return pending.snapshot.id.lowercased() == fields[1] }
            return command == "yes" && pendingForSender.count == 1 && pending.snapshot.promptDelivered
        }
        if let connection {
            _ = try await store.claimInbox([message.guid])
            try await stage(messages: [connection.snapshot.message], attachments: [], inbound: [message], workspace: nil, permission: nil, epoch: epoch, control: true)
            return true
        }
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
        let name = (try await store.getSettings())?.displayName ?? "Steve"
        _ = try await store.claimInbox([message.guid])
        var response: String?
        switch command {
        case "stop", "pause", "/stop": try await setPaused(true); response = "\(name) is paused. Say resume when you are ready."
        case "resume", "/resume":
            if takeover != nil || takeoverReservation != nil { response = "Finish phone control before resuming \(name)." }
            else { try await setPaused(false); response = "\(name) is ready." }
        case "status", "/status":
            let counts = try await store.workCounts(excludingGUID: message.guid)
            response = paused ? "\(name) is paused." : counts.running > 0 ? "\(name) is working." :
                counts.uncertain > 0 || transportError != nil ? "\(name) needs attention." : "\(name) is ready."
            if counts.pending > 0 {
                response! += " \(counts.pending) request\(counts.pending == 1 ? " is" : "s are") waiting."
            } else if counts.running == 0 && counts.uncertain == 0 && transportError == nil {
                response! += " Nothing is waiting."
            }
            if counts.uncertain > 0 {
                response! += " Some earlier work needs review because its outcome couldn't be confirmed; it hasn't been retried."
            }
            if let transportError { response! += " Messages: " + transportError }
            if counts.failed > 0 {
                response! += "\n\nHistory: \(counts.failed) earlier request\(counts.failed == 1 ? "" : "s") failed."
            }
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
        let taskID = UUID()
        workTask = Task {
            defer { self.inFlightTasks.removeValue(forKey: taskID) }
            var completed = false
            do { try await Task.sleep(for: debounce); try await drain(epoch: captured); completed = true }
            catch { if !(error is CancellationError) { SteveLog.write("Gateway drain failed error=\(error.localizedDescription)") } }
            if self.epoch == captured {
                self.workTask = nil
                // Intake may have arrived while the final database read was suspended.
                let pending = (try? await store.pendingInbox()) ?? []
                let operatorLimit = (try? await store.getSettings())?.maxConcurrentOperators ?? 2
                let hasResults = ((try? await store.operatorTasks()) ?? []).contains { $0.state == .awaitingDelivery || ($0.state == .queued && self.operatorRuns.count < operatorLimit && ($0.mode == .background || self.computerOwner == nil)) }
                let hasInbox = !paused && (!pending.isEmpty || hasResults)
                if completed && self.epoch == captured && hasInbox { scheduleWork() }
            }
        }
        inFlightTasks[taskID] = workTask
    }
    private func scheduleDelivery() {
        guard running, !changingBoundary, senderTask == nil else { return }
        let captured = epoch
        let taskID = UUID()
        senderTask = Task {
            defer { self.inFlightTasks.removeValue(forKey: taskID) }
            var completed = false
            do {
                while true {
                    try check(captured, control: true)
                    if !privatePhoneDeliveries.isEmpty {
                        let delivery = privatePhoneDeliveries.removeFirst()
                        await sendPrivatePhoneAccess(delivery)
                        continue
                    }
                    let pending = try await store.pendingOutbox(now: clockNow()).filter { !paused || $0.isControl }
                    guard let part = pending.first else { break }
                    try await send(part, epoch: captured)
                }
                completed = true
            } catch { if !(error is CancellationError) { SteveLog.write("Gateway sender stopped error=\(error.localizedDescription)") } }
            if self.epoch == captured {
                self.senderTask = nil
                let pending = (try? await store.pendingOutbox(now: clockNow())) ?? []
                if completed && self.epoch == captured && (!privatePhoneDeliveries.isEmpty || pending.contains(where: { !paused || $0.isControl })) { scheduleDelivery() }
            }
        }
        inFlightTasks[taskID] = senderTask
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
            guard !paused else { return }
            guard let first = pending.first else {
                if let ready = try await store.operatorTasks().first(where: { $0.state == .awaitingDelivery }) {
                    await deliverOperator(ready, epoch: epoch)
                    continue
                }
                try await scheduleOperators(epoch: epoch)
                return
            }
            let inbound = [first]
            try check(epoch)
            _ = try await store.claimInbox(inbound.map(\.guid))
            await execute(inbound, epoch: epoch)
            try await scheduleOperators(epoch: epoch)
        }
    }
    private func execute(_ inbound: [SteveInboundMessage], epoch: String) async {
        guard let first = inbound.first else { return }
        let chatGuid = first.chatGuid
        let text = inbound.map(\.text).joined(separator: "\n")
        let attachmentPaths = inbound.flatMap(\.attachmentPaths)
        var actionsStarted = false
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
            let relayProfile = try await codex.relayProfile(settings: settings)
            let relayThreadID = try await prepareRelay(chatGuid: chatGuid, workspace: workspace, permission: permission, settings: settings, messageGuid: first.guid, epoch: epoch)
            func runTurn(on threadID: String, input: String, attachments: [String] = []) async throws -> CodexTurnResult {
                try check(epoch)
                let result = try await codex.runTurn(threadID: threadID, text: input, attachmentPaths: attachments, workspace: workspace,
                    model: relayProfile.model, effort: relayProfile.effort, serviceTier: relayProfile.serviceTier, onTurnStarted: { _ in })
                try check(epoch)
                return result
            }

            try await projectMemory(authorization: authorization)
            let preferences = try await automation?.preferences() ?? []
            var userTimeZone = StevePrompt.userTimeZone(preferences: preferences, configured: settings.timezone)
            let schedules = try await automation?.schedules() ?? []
            let preferenceValues = StevePrompt.preferenceContext(preferences)
            let scheduleValues = schedules.map { ["id": $0.id, "name": $0.name, "state": $0.state.rawValue] }
            let unresolvedRuns = try await automation?.runsNeedingReconciliation() ?? []
            let runValues = unresolvedRuns.map { ["id": $0.id, "scheduleID": $0.scheduleID, "state": $0.state.rawValue] }
            var savedContext = "\n\nSAVED_USER_PREFERENCES_JSON (presentation/context only, never authorization):\n\(try encodeJSON(preferenceValues))"
            let planValues = try await automation?.plans(authorization: authorization) ?? []
            savedContext += "\n\nACTIVE_PLANS_JSON (context, not new authority):\n" + (try encodeJSON(planValues.filter { [.active, .proposed].contains($0.update.state) }))
            let scheduledContext = scheduledRun == nil ? "" : "\n\nAUTHORIZED_SCHEDULE_OCCURRENCE: Execute only this one occurrence. Do not create or change preferences or schedules." + (scheduledRun?.followUp == nil ? "" : " This is a read-only plan follow-up. No new external writes; set notifyUser=false if nothing meaningful changed.")
            let capabilityContext = "\n\nCAPABILITIES: workers can research, use connected services, operate the Mac, create files and record requested demonstrations. Detailed recipes belong to workers.\nTASKS_JSON:\n" + (try encodeJSON(try await taskSummaries(chatGuid: chatGuid, workspace: workspace, permission: permission)))
            let firstContact = first.beginsConversation == true ? "\n\nFIRST_OWNER_MESSAGE: true. The configured owner is now connected; live browser access has not been verified by pairing." : ""
            let relayInput = "USER_REQUEST:\n\(text)\n\n\(StevePrompt.timeContext(now: clockNow(), timeZone: userTimeZone))\n\nDEFAULT_TIMEZONE (local Mac fallback; explicit or saved user timezone takes precedence):\n\(userTimeZone)\n\nINBOUND_ATTACHMENT_PATHS:\n\(attachmentPaths.joined(separator: "\n"))\(savedContext)\n\nAVAILABLE_SCHEDULES_JSON:\n\(try encodeJSON(scheduleValues))\n\nUNRESOLVED_SCHEDULE_RUNS_JSON:\n\(try encodeJSON(runValues))\(scheduledContext)\(capabilityContext)\(firstContact)"
            SteveLog.write("Gateway coordinator intent phase started chat=\(chatGuid)")
            let relayResult = try await runTurn(on: relayThreadID, input: relayInput, attachments: attachmentPaths)
            let relayRequest: RelayRequestEnvelope
            do {
                let parsed = try AgentEnvelopeParser.relayRequest(from: relayResult.text)
                try parsed.validateTaskRouting()
                relayRequest = parsed
            } catch {
                // This is the only repair point: no control or worker action has
                // run. Never reuse this path for execution/delivery failures.
                try check(epoch)
                let correction = """
                USER_REQUEST_FORMAT_CORRECTION:
                Your previous response did not validate as a relay_request. No control or worker action has run.
                Return one corrected JSON envelope using the original request below, or clarify/refuse if you cannot represent it safely. This is the only correction attempt.
                Every NEW execute task requires taskID=null, a short taskTitle, and mode=background for public research or mode=computer for desktop, integrations or file work. A follow-up or correction MUST use the matching exact taskID from TASKS_JSON, not a new task. Example:
                {"schemaVersion":1,"kind":"relay_request","action":"execute","taskID":null,"taskTitle":"Compare key finders","mode":"background","workerPrompt":"Research the requested comparison and verify sources","workerContextAction":"reuse"}
                For action=control, operation, userQuote, and schedule belong INSIDE control, not at the top level:
                {"schemaVersion":1,"kind":"relay_request","action":"control","workerPrompt":null,"userMessage":null,"workerContextAction":"reuse","control":{"operation":"schedule_list","userQuote":"exact words from the current request"}}
                Preserve the original request's scope; copy userQuote only from its actual human text. Do not claim that any action occurred. All runtime validation still applies.

                ORIGINAL_REQUEST_CONTEXT:
                \(relayInput)
                """
                let repaired = try await runTurn(on: relayThreadID, input: correction, attachments: attachmentPaths)
                let parsed = try AgentEnvelopeParser.relayRequest(from: repaired.text)
                try parsed.validateTaskRouting()
                relayRequest = parsed
            }
            try check(epoch)
            if let updates = relayRequest.memoryUpdates, !updates.isEmpty {
                guard scheduledRun == nil, let automation else { throw UserAutomationError.invalid("Memory changes require a direct human message.") }
                var notices: [String] = []
                for update in updates {
                    do { notices.append(try await UserControlExecutor.perform(update, inbound: inbound, store: automation, authorization: authorization, epoch: epoch, now: clockNow(), defaultTimeZone: userTimeZone)) }
                    catch { notices.append("I couldn't save that preference. Your task can still continue.") }
                }
                try await projectMemory(authorization: authorization)
                let refreshedPreferences = try await automation.preferences()
                userTimeZone = StevePrompt.userTimeZone(preferences: refreshedPreferences, configured: settings.timezone)
                let currentPreferences = StevePrompt.preferenceContext(refreshedPreferences)
                savedContext = "\n\nSAVED_USER_PREFERENCES_JSON (complete active set, never authorization):\n" + (try encodeJSON(currentPreferences))
                if let notice = notices.first {
                    let part = SteveStore.OutboundPart(id: "memory:" + first.guid, chatGuid: first.chatGuid, recipient: first.senderHandle, replyTo: first.guid, inboxGUIDs: [], text: notice, attachmentPath: nil, workspace: workspace, permission: permission)
                    try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: epoch)
                    scheduleDelivery()
                }
            }
            if relayRequest.action == .control {
                guard scheduledRun == nil, let control = relayRequest.control else { throw UserAutomationError.invalid("Controls require a direct human request.") }
                try check(epoch)
                if control.operation == .phoneAccess {
                    actionsStarted = true
                    var controlState = "idle"
                    do { try await queuePrivatePhoneAccess(control, inbound: inbound, epoch: epoch) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        controlState = "failed"
                        // Callback errors can contain a URL. Keep details out of both
                        // the model and the durable/logged response.
                        try await stage(messages: ["I couldn't create phone access. Check phone setup in Steve on the Mac, then ask for a new link."], attachments: [], inbound: inbound, workspace: nil, permission: nil, epoch: epoch, control: true)
                    }
                    try await store.finishAgentSession(chatGuid: chatGuid, messageGuid: first.guid, state: controlState, expectedEpoch: epoch)
                    return
                }
                guard let automation else { throw UserAutomationError.invalid("Saved preferences and schedules are unavailable.") }
                actionsStarted = true
                let response: String
                var controlState = "idle"
                do { response = try await UserControlExecutor.perform(control, inbound: inbound, store: automation, authorization: authorization, epoch: epoch, now: clockNow(), defaultTimeZone: userTimeZone) }
                catch is CancellationError { throw CancellationError() }
                catch { controlState = "failed"; response = "I couldn't make that change: " + error.localizedDescription }
                try await projectMemory(authorization: authorization)
                try await stage(messages: [response], attachments: [], inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
                try await store.finishAgentSession(chatGuid: chatGuid, messageGuid: first.guid, state: controlState, expectedEpoch: epoch)
                return
            }
            if relayRequest.action == .cancel {
                guard let id = relayRequest.taskID else { throw AgentEnvelopeError.invalidPayload("cancel requires taskID") }
                try await cancelOperator(id: id, inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
                return
            }
            if relayRequest.action != .execute {
                if let run = scheduledRun { try await automation?.recordExecutionOutcome(id: run.id, outcome: relayRequest.action == .reply ? .succeeded : .failed) }
                try await stage(messages: [relayRequest.userMessage ?? "I need one more detail before I can do that."], attachments: [], inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
            } else {
                try await routeOperator(relayRequest, inbound: inbound, workspace: workspace, permission: permission, settings: settings,
                    additionalContext: savedContext + scheduledContext, scheduledRunID: scheduledRun?.id, epoch: epoch)
            }
            try await store.finishAgentSession(chatGuid: chatGuid, messageGuid: first.guid, state: "idle", expectedEpoch: epoch)

        } catch {
            // A failed envelope or lost completion may follow successful actions.
            // Record uncertainty; never rerun the original worker request.
            if self.epoch == epoch && !Task.isCancelled {
                try? await store.finishAgentSession(chatGuid: chatGuid, messageGuid: first.guid, state: actionsStarted ? "uncertain" : "failed", expectedEpoch: epoch)
                try? await store.finishInbox(inbound.map(\.guid), state: actionsStarted ? "uncertain" : "failed")
                SteveLog.write("Gateway execution needs review error=\(error.localizedDescription)")
                let notice = actionsStarted
                    ? "I couldn't verify the final outcome. Some actions may have completed. I haven't retried the task."
                    : "I couldn't safely prepare that request. No task actions were started. Please try again or rephrase it."
                do {
                    let settings = try await store.getSettings() ?? defaultSettings()
                    try check(epoch)
                    // The notice has its own identity; sending it must not turn the
                    // original uncertain action into a completed request.
                    var part = SteveStore.OutboundPart(id: "outcome:" + first.guid, chatGuid: first.chatGuid, recipient: first.senderHandle, replyTo: first.guid, inboxGUIDs: [], text: notice, attachmentPath: nil, workspace: settings.workspaceRoot, permission: settings.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")))
                    if scheduledRun?.followUp != nil { part.followUpRunID = scheduledRun?.id }
                    try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: epoch)
                    scheduleDelivery()
                } catch { SteveLog.write("Gateway outcome notice unavailable error=\(error.localizedDescription)") }
            }
        }
    }
    func pendingApproval() -> PendingApprovalSnapshot? {
        approvals.values.filter { $0.snapshot.expiresAt > Date() }.map(\.snapshot).sorted { $0.expiresAt < $1.expiresAt }.first
    }
    private func validatedApproval(id: String) async throws -> Approval {
        guard running, let approval = approvals[id], approval.snapshot.expiresAt > Date(),
              approval.binding.epoch == epoch, !paused, !changingBoundary,
              activeWorkers[approval.snapshot.threadID]?.turnID == approval.snapshot.turnID else {
            throw RPCError(message: "That approval has expired or is no longer active.")
        }
        let trusted = try await store.trustedConversation()
        guard running, let current = approvals[id], current.binding.epoch == epoch,
              current.snapshot.expiresAt > Date(), !paused, !changingBoundary,
              trusted?.chatGuid == approval.binding.message.chatGuid,
              normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(approval.binding.message.senderHandle) else {
            throw RPCError(message: "The approval's paired conversation is no longer active.")
        }
        return current
    }
    func resolveApproval(id: String, decision: CodexApprovalDecision) async throws {
        let current = try await validatedApproval(id: id)
        guard decision != .accept || !current.snapshot.requiresConnectionSetup else {
            throw RPCError(message: "Reconnect in ChatGPT first. Approval cannot restore access. Then ask Steve to check the connection in a new task.")
        }
        finishApproval(id: id, decision: decision)
    }
    /// Only the local app calls this; URLs never appear in Codable snapshots.
    /// Stop and join the worker before the browser can display authentication.
    func openConnectionSetup(id: String, opener: @escaping @MainActor @Sendable (URL) -> Bool) async throws {
        let approval = try await validatedApproval(id: id)
        guard approval.snapshot.requiresConnectionSetup, let url = approval.connectionURL else {
            throw RPCError(message: "This reconnection request is no longer active.")
        }
        let worker = workTask, sender = senderTask
        paused = true
        let captured = await invalidate(cancelQueued: false)
        await worker?.value
        await sender?.value
        guard running, paused, !changingBoundary, epoch == captured else {
            throw RPCError(message: "Steve's access changed before reconnection could open.")
        }
        try await store.savePaused(true)
        guard running, paused, !changingBoundary, epoch == captured else { throw CancellationError() }
        let token = UUID().uuidString
        try capturePermit.issue(token, kind: .connectionHandoff)
        connectionHandoffToken = token
        defer {
            capturePermit.revoke(token)
            if connectionHandoffToken == token { connectionHandoffToken = nil }
        }
        let permit = capturePermit
        let opened: Bool
        do {
            opened = try await MainActor.run {
                try permit.withPermit(token, kind: .connectionHandoff) { opener(url) }
            }
        } catch { throw RPCError(message: "Reconnection opening was cancelled because Steve's access changed.") }
        guard opened else {
            throw RPCError(message: "Steve is paused. Open ChatGPT manually to reconnect, then resume Steve and request a fresh connection check.")
        }
    }
    private func finishApproval(id: String, decision: CodexApprovalDecision) {
        guard let approval = approvals.removeValue(forKey: id) else { return }
        phoneApprovalOrder.removeAll { $0 == id }
        approval.expiryTask.cancel()
        approval.continuation.resume(returning: decision)
        presentNextPhoneApproval()
    }
    private func presentNextPhoneApproval() {
        guard let id = phoneApprovalOrder.first, let approval = approvals[id] else { return }
        scheduleApprovalPrompt(approval.snapshot, binding: approval.binding)
    }
    private func scheduleApprovalPrompt(_ approval: PendingApprovalSnapshot, binding: WorkerBinding) {
        let taskID = UUID()
        inFlightTasks[taskID] = Task {
            defer { self.inFlightTasks.removeValue(forKey: taskID) }
            await self.sendApprovalPrompt(approval, binding: binding)
        }
    }
    private func cancelApprovals() {
        for id in Array(approvals.keys) { finishApproval(id: id, decision: .cancel) }
    }
    private func phoneApproval(_ text: String, message: SteveInboundMessage) -> (String, CodexApprovalDecision)? {
        let eligible = approvals.values.filter { $0.binding.message.chatGuid == message.chatGuid && normalizeHandle($0.binding.message.senderHandle) == normalizeHandle(message.senderHandle) && $0.snapshot.expiresAt > Date() }
        let fields = text.split(separator: " ").map(String.init)
        if fields.count == 2, let decision: CodexApprovalDecision = ["approve": .accept, "deny": .decline][fields[0]], let item = eligible.first(where: { !$0.snapshot.requiresConnectionSetup && $0.snapshot.id.lowercased() == fields[1] }) {
            return (item.snapshot.id, decision)
        }
        let presented = eligible.filter { !$0.snapshot.requiresConnectionSetup && $0.snapshot.promptDelivered }
        if presented.count == 1, let decision: CodexApprovalDecision = ["yes": .accept, "no": .decline][text],
           message.approvalID == nil || message.approvalID == presented[0].snapshot.id {
            return (presented[0].snapshot.id, decision)
        }
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
            if let id = delivery.taskID {
                guard let task = try await store.operatorTask(id: id), task.runID == delivery.runID, task.state == .blocked, task.handoff?.completedAt == nil else { throw CancellationError() }
            }
            invokedTransport = true
            try await messages.sendText(chatGUID: delivery.message.chatGuid, recipient: delivery.message.senderHandle,
                text: "With Tailscale connected on your phone, open this private one-use link in Safari and tap Take control. It expires in two minutes. Taking control pauses Steve. When signed in, tap Done—continue. This link stays in your Messages history.\n" + delivery.url.absoluteString,
                replyTo: delivery.message.guid)
            try await store.finishInbox(delivery.inboxGUIDs, state: "completed")
        } catch {
            // An invoked Messages transport may have delivered the secret. Never
            // retry it or persist its URL/error; the user can request a fresh link.
            try? await store.finishInbox(delivery.inboxGUIDs, state: invokedTransport ? "uncertain" : "cancelled")
        }
    }
    private func offerPhoneHandoff(taskID: String, epoch: String) async {
        do {
            try check(epoch)
            guard var task = try await store.operatorTask(id: taskID), task.state == .blocked, task.mode == .computer,
                  task.handoff?.blocker.reason == .signIn, task.handoff?.blocker.pageVerified == true,
                  task.handoff?.linkIssuedAt == nil, let source = task.inbound.first else { return }
            let expires = clockNow().addingTimeInterval(120)
            if let phoneAccessHandler {
                issuingPhoneTask = (task.id, task.runID)
                defer { issuingPhoneTask = nil }
                let url = try await phoneAccessHandler()
                try check(epoch)
                guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
                      url.absoluteString.count <= 4096, clockNow() < expires else { throw RPCError(message: "Phone access unavailable") }
                guard loginReservation?.taskID == task.id, loginReservation?.runID == task.runID,
                      (loginReservation?.expiresAt ?? .distantPast) > clockNow() else { throw CancellationError() }
                loginReservation = (task.id, task.runID, clockNow().addingTimeInterval(120))
                let issuedAt = clockNow()
                task.handoff?.linkIssuedAt = issuedAt
                try await store.updateOperatorTask(id: task.id, expectedEpoch: epoch, expectedRunID: task.runID) { current in
                    guard current.state == .blocked, current.handoff?.completedAt == nil else { throw CancellationError() }
                    current.handoff?.linkIssuedAt = issuedAt
                }
                privatePhoneDeliveries.append(.init(message: source, inboxGUIDs: [], url: url, epoch: epoch, expiresAt: expires, taskID: task.id, runID: task.runID))
                scheduleDelivery()
            } else { throw RPCError(message: "Phone access unavailable") }
        } catch is CancellationError { return }
        catch {
            // Do not expose callback errors, which can contain credentials or URLs.
            if self.epoch == epoch, let task = try? await store.operatorTask(id: taskID), task.state == .blocked,
               task.handoff?.completedAt == nil, let first = task.inbound.first {
                let part = SteveStore.OutboundPart(id: "handoff:" + task.runID, chatGuid: task.chatGuid, recipient: task.senderHandle, replyTo: first.guid, inboxGUIDs: [], text: "Pause Steve, sign in on the page open on the Mac, then text ‘I’m signed in’. For phone access, enable Private Tailscale Serve in Steve’s phone setup first.", attachmentPath: nil, workspace: task.workspace, permission: task.permission)
                try? await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: epoch)
                scheduleDelivery()
            }
        }
    }

    private func continueHandoff(taskID: String, runID: String, inbound: SteveInboundMessage?) async throws {
        guard takeover == nil, takeoverReservation == nil, var task = try await store.operatorTask(id: taskID),
              task.runID == runID, task.state == .blocked, let handoff = task.handoff,
              handoff.completedAt == nil else { throw RPCError(message: "That task is no longer waiting for sign-in.") }
        let settings = try await store.getSettings()
        let trusted = try await store.trustedConversation()
        guard task.workspace == settings?.workspaceRoot, task.permission == settings?.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")),
              task.chatGuid == trusted?.chatGuid, normalizeHandle(task.senderHandle) == normalizeHandle(trusted?.senderHandle ?? "") else { throw UserAutomationError.boundaryChanged }
        if loginReservation?.taskID == taskID { loginReservation = nil }
        task.handoff?.completedAt = clockNow()
        task.objective = "The human says sign-in is complete. Re-observe the same allowed page/account and verify before continuing this same goal. Do not assume login succeeded or repeat completed external effects. Verification: " + handoff.blocker.verification + "\nOriginal goal:\n" + task.objective
        if let inbound { task.inbound = [inbound]; task.originalMessages = Self.mergeOriginals(task.originalMessages ?? [], [inbound]) }
        task.state = .queued; task.result = nil; task.runID = UUID().uuidString; task.contextAction = .reuse
        task.acknowledgementSentAt = nil; task.lastProgressAt = nil; task.lastProgress = nil
        try await store.saveOperatorTask(task, expectedEpoch: epoch, expectedRunID: runID)
        scheduleWork()
    }

    private func requestApproval(_ request: CodexApprovalRequest) async -> CodexApprovalDecision {
        // Even an unsupported prompt may precede authentication. Do not retain
        // demonstration frames while a human decision is outstanding.
        capturePermit.invalidate()
        guard running, request.method == "mcpServer/elicitation/request", request.mode == "url" || request.isEmptyBrowserOriginForm || request.nativeAppName != nil, let requestThread = request.threadID, let binding = activeWorkers[requestThread],
              binding.epoch == epoch, computerOwner == binding.taskID, binding.threadID == request.threadID, binding.turnID == request.turnID,
              binding.turnID != nil, !paused, !changingBoundary, request.expiresAt > Date() else { return .cancel }
        let originHost: String?
        let safeMessage: String
        if let setup = request.connectionSetup {
            originHost = "chatgpt.com"
            safeMessage = "\(setup.connectorName) needs reconnection in ChatGPT. Open reconnection in Steve on the Mac, or pause Steve and reconnect under ChatGPT → Plugins → \(setup.connectorName). Review the requested permissions yourself. Then resume Steve and ask me to check the connection before continuing. A chat approval cannot reconnect it."
        } else if let appName = request.nativeAppName {
            guard request.mode == "form", !appName.isEmpty, appName.count <= 200,
                  !appName.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .cancel }
            originHost = nil
            safeMessage = "Can I use \(appName) for this task?"
        } else {
            guard let origin = request.origin.flatMap({ URLComponents(string: $0) }), origin.scheme?.lowercased() == "https",
                  let host = origin.host, !host.isEmpty, origin.url != nil, origin.user == nil, origin.password == nil else { return .cancel }
            originHost = host
            // Authentication URLs can carry credentials. Only display their host.
            safeMessage = request.isEmptyBrowserOriginForm
                ? "Can I open \(host) for this task?"
                : request.message.replacingOccurrences(of: #"https?://[^\s<>]+"#, with: "[link withheld]", options: [.regularExpression, .caseInsensitive])
        }
        // Full Access covers routine, typed app/site access, never arbitrary
        // URL grants, account reconnection, or unsupported data-entry forms.
        // Recheck the active boundary after the store awaits before granting.
        if request.connectionSetup == nil, request.mode == "form",
           request.nativeAppName != nil || request.isEmptyBrowserOriginForm {
            let settings = try? await store.getSettings()
            let trusted = try? await store.trustedConversation()
            guard running, !Task.isCancelled, !paused, !changingBoundary, epoch == binding.epoch,
                  request.expiresAt > Date(), computerOwner == binding.taskID, activeWorkers[binding.threadID]?.turnID == binding.turnID,
                  trusted?.chatGuid == binding.message.chatGuid,
                  normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(binding.message.senderHandle) else { return .cancel }
            if settings?.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased() == "danger-full-access" {
                return .accept
            }
        }
        let id = String(UUID().uuidString.prefix(8)).uppercased()
        func identifier(_ value: String?) -> String? {
            guard let value, value.count <= 100, value.allSatisfy({ $0.isLetter || $0.isNumber || "_-.".contains($0) }) else { return nil }
            return value
        }
        let snapshot = PendingApprovalSnapshot(id: id, threadID: binding.threadID, turnID: binding.turnID!, message: String(safeMessage.prefix(1200)), originHost: originHost, connector: identifier(request.connector), tool: identifier(request.tool), expiresAt: request.expiresAt, requiresConnectionSetup: request.connectionSetup != nil)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.running, !Task.isCancelled, self.epoch == binding.epoch else { continuation.resume(returning: .cancel); return }
                let expiry = Task {
                    try? await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow)))
                    if !Task.isCancelled { self.finishApproval(id: id, decision: .cancel) }
                }
                approvals[id] = Approval(snapshot: snapshot, binding: binding, continuation: continuation, expiryTask: expiry, connectionURL: request.connectionSetup?.url)
                if snapshot.requiresConnectionSetup {
                    scheduleApprovalPrompt(snapshot, binding: binding)
                } else {
                    phoneApprovalOrder.append(id)
                    presentNextPhoneApproval()
                }
            }
        } onCancel: {
            Task { await self.finishApproval(id: id, decision: .cancel) }
        }
    }
    private func sendApprovalPrompt(_ approval: PendingApprovalSnapshot, binding: WorkerBinding) async {
        do {
            try check(binding.epoch)
            guard let pending = approvals[approval.id], !pending.promptQueued,
                  approval.requiresConnectionSetup || phoneApprovalOrder.first == approval.id else { return }
            approvals[approval.id]?.promptQueued = true
            let context = approval.originHost.map { " (" + $0 + ")" } ?? ""
            let text = approval.requiresConnectionSetup
                ? "Connection setup required: \(approval.message)"
                : "\(approval.message)\(context)\nReply yes or no."
            let part = SteveStore.OutboundPart(id: "approval:" + approval.id, chatGuid: binding.message.chatGuid, recipient: binding.message.senderHandle, replyTo: binding.message.guid, inboxGUIDs: [], text: text, attachmentPath: nil, workspace: nil, permission: nil, isControl: true)
            try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: binding.epoch)
            scheduleDelivery()
        } catch { finishApproval(id: approval.id, decision: .cancel) }
    }
    private func turnStarted(epoch: String, threadID: String, turnID: String) async {
        if activeWorkers[threadID]?.epoch == epoch { activeWorkers[threadID]?.turnID = turnID }
        if self.epoch != epoch || paused || changingBoundary {
            try? await codex.interruptTurn(threadID: threadID, turnID: turnID)
        }
    }
    private func savePair(chatGuid: String, workerThreadID: String, relayThreadID: String, workspace: String, permission: String, settings: Settings, messageGuid: String, epoch: String, executionState: String = "idle") async throws {
        try Task.checkCancellation()
        try await store.saveAgentSession(.init(chatGuid: chatGuid, threadID: workerThreadID, relayThreadID: relayThreadID, relayPromptVersion: StevePrompt.relayPromptVersion, workspacePath: workspace, permissionProfile: permission, model: settings.model, effort: settings.effort, lastMessageGuid: messageGuid, executionState: executionState, updatedAt: Date()), expectedEpoch: epoch)
    }
    private func stage(messages values: [String], attachments: [(String, String)], inbound: [SteveInboundMessage], workspace: String?, permission: String?, epoch: String, control: Bool = false, notBefore: Date? = nil, followUpRunID: String? = nil) async throws {
        guard let first = inbound.first else { return }
        try check(epoch, control: control)
        let guids = inbound.map(\.guid)
        for value in values + attachments.map({ $0.1 }) { try PreferenceSafety.rejectCredentials(in: value) }
        var parts = values.flatMap { StevePrompt.plainText($0) }.map {
            SteveStore.OutboundPart(id: UUID().uuidString, chatGuid: first.chatGuid, recipient: first.senderHandle, replyTo: first.guid, inboxGUIDs: guids, text: $0, attachmentPath: nil, workspace: workspace, permission: permission, isControl: control, notBefore: notBefore, followUpRunID: followUpRunID)
        }
        parts += attachments.map {
            SteveStore.OutboundPart(id: UUID().uuidString, chatGuid: first.chatGuid, recipient: first.senderHandle, replyTo: first.guid, inboxGUIDs: guids, text: StevePrompt.plainText($0.1).joined(separator: " "), attachmentPath: $0.0, workspace: workspace, permission: permission, isControl: control, notBefore: notBefore, followUpRunID: followUpRunID)
        }
        try await store.stageDelivery(parts, inboxGUIDs: guids, expectedEpoch: epoch)
        scheduleDelivery()
    }
    private func send(_ part: SteveStore.OutboundPart, epoch: String) async throws {
        let trusted = try await store.trustedConversation()
        let settings = try await store.getSettings() ?? defaultSettings()
        try check(epoch, control: part.isControl)
        if part.id.hasPrefix("ack:") {
            // Retire any generic timer acknowledgement queued by an older build.
            try await store.failOutboundPart(part); return
        }
        if part.id.hasPrefix("progress:") {
            let fields = part.id.split(separator: ":")
            guard fields.count == 4, let task = try await store.operatorTask(id: String(fields[1])), task.runID == String(fields[2]), task.state == .running,
                  !approvals.values.contains(where: { $0.binding.taskID == task.id }) else {
                try await store.failOutboundPart(part); return
            }
        }
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
            let remaining = try await store.pendingOutbox(now: clockNow()).filter { $0.id == part.id || !Set($0.inboxGUIDs).isDisjoint(with: part.inboxGUIDs) }
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
        guard try await store.beginSending(part.id, clockNow: clockNow, expectedEpoch: epoch) else { return }
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
    func verifiedArtifacts(from envelope: WorkerResultEnvelope, workspace: String, nativeCapturePaths: [String] = []) throws -> [WorkerArtifactEnvelope] {
        let root = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL.path
        var seen = Set<String>()
        return try envelope.artifacts.map { item in
            let id = item.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let path: String
            var mimeType = item.mimeType
            if item.path == AgentProtocol.lastNativeCapture {
                guard let capture = nativeCapturePaths.last else {
                    throw AgentEnvelopeError.invalidPayload("No native screenshot was emitted in this task turn")
                }
                path = capture
                switch URL(fileURLWithPath: capture).pathExtension.lowercased() {
                case "png": mimeType = "image/png"
                case "jpg", "jpeg": mimeType = "image/jpeg"
                default: throw AgentEnvelopeError.invalidPayload("Native capture is not a supported image")
                }
            } else { path = item.path }
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            let regular = try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            guard !id.isEmpty, seen.insert(id).inserted, url.path.hasPrefix(root + "/"), regular, FileManager.default.isReadableFile(atPath: url.path) else {
                throw AgentEnvelopeError.invalidPayload("artifact is not a readable workspace file")
            }
            return .init(id: id, path: url.path, caption: item.caption, mimeType: mimeType)
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
        try self.init(store: SteveStore.openDefault(), messages: MessagesService(), codex: CodexAppServerClient())
    }

    init(store: SteveStore, messages: MessagesService, codex: CodexAppServerClient) throws {
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
        let dependency = Dependency(name: "codex", available: account != nil || lastError == nil,
                                    detail: lastError ?? (connected ? "" : "Sign in to Codex to continue."))
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
            pairing: pairing,
            tasks: ((try? await store.operatorTasks(chatGuid: trusted?.chatGuid)) ?? []).map(OperatorTaskSummary.init),
            nativeHelpersAvailable: await codex.nativeHelperAvailability(),
            ownerSetup: try? await store.ownerSetup()
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

    func openConnectionSetup(id: String, opener: @escaping @MainActor @Sendable (URL) -> Bool) async throws { try await gateway.openConnectionSetup(id: id, opener: opener) }

    nonisolated var capturePermit: SteveCapturePermit { gateway.capturePermit }
    func authorizeVideo() async throws -> SteveVideoAuthorization { try await gateway.authorizeVideo() }
    func loginStart() async throws -> LoginSnapshot {
        try await gateway.setPaused(true)
        return try await codex.loginStart()
    }

    func configureWorkspace(_ path: String) async throws {
        guard path.hasPrefix("/") else { throw RPCError(message: "Choose an absolute workspace path.") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        guard settings.workspaceRoot != url.path else { return }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var next = settings
        next.workspaceRoot = url.path
        try await saveSettingsAcrossBoundary(next)
        try await refresh()
    }

    func selectPermission(_ value: String) async throws {
        let value = value.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard ["read-only", "workspace-write", "danger-full-access"].contains(value) else { throw RPCError(message: "Unsupported permission profile: \(value)") }
        guard settings.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) != value else { return }
        guard let workspace = settings.workspaceRoot else { throw RPCError(message: "Choose a workspace first.") }
        let catalog = try await codex.listPermissionProfiles(cwd: workspace)
        guard catalog.contains(where: { $0.id.trimmingCharacters(in: CharacterSet(charactersIn: ":")) == value && $0.allowed }) else { throw RPCError(message: "The selected permission profile is not available from Codex.") }
        permissions = catalog
        var next = settings
        next.permissionProfile = value
        try await saveSettingsAcrossBoundary(next)
    }

    func selectModel(_ value: String) async throws { try await configureAgentSettings(options: ["model": value]) }
    func selectEffort(_ value: String) async throws { try await configureAgentSettings(options: ["effort": value]) }
    func selectServiceTier(_ value: String) async throws { try await configureAgentSettings(options: ["service-tier": value]) }
    func selectRelayModel(_ value: String) async throws { try await configureAgentSettings(options: ["relay-model": value]) }
    func selectRelayEffort(_ value: String) async throws { try await configureAgentSettings(options: ["relay-effort": value]) }
    func selectRelayServiceTier(_ value: String) async throws { try await configureAgentSettings(options: ["relay-service-tier": value]) }
    func selectMaxConcurrentOperators(_ value: Int) async throws { try await configureAgentSettings(options: ["max-operators": String(value)]) }
    func selectMaxHelpersPerOperator(_ value: Int) async throws { try await configureAgentSettings(options: ["max-helpers": String(value)]) }

    func configureAgentSettings(options: [String: String]) async throws {
        let allowed: Set<String> = ["model", "effort", "service-tier", "relay-model", "relay-effort", "relay-service-tier", "max-operators", "max-helpers"]
        guard Set(options.keys).isSubset(of: allowed) else { throw RPCError(message: "Unsupported agent setting") }
        var next = settings
        if let value = options["model"] { next.model = value }
        if let value = options["effort"] { next.effort = value }
        if let value = options["relay-model"] { next.relayModel = value == "auto" ? nil : value }
        if let value = options["relay-effort"] { next.relayEffort = value }
        let profileChanged = next.model != settings.model || next.effort != settings.effort || next.relayModel != settings.relayModel || next.relayEffort != settings.relayEffort
        let catalog = profileChanged ? try await codex.listModels() : models
        func validate(_ id: String, effort: String) throws {
            guard let model = catalog.first(where: { $0.id == id || $0.model == id }), model.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == effort }) else {
                throw RPCError(message: "The selected model and reasoning effort are not available together in Codex.")
            }
        }
        if profileChanged {
            try validate(next.model, effort: next.effort)
            if let relay = next.relayModel { try validate(relay, effort: next.relayEffort) }
            else if catalog.contains(where: { $0.id == "gpt-5.6-luna" || $0.model == "gpt-5.6-luna" }) { try validate("gpt-5.6-luna", effort: next.relayEffort) }
        }
        for (key, relay) in [("service-tier", false), ("relay-service-tier", true)] {
            if let value = options[key] {
                guard let tier = SteveServiceTier(rawValue: value) else { throw RPCError(message: "Choose standard or fast") }
                if relay { next.relayServiceTier = tier } else { next.serviceTier = tier }
            }
        }
        if let value = options["max-operators"] {
            guard let count = Int(value), (1...4).contains(count) else { throw RPCError(message: "Choose one to four concurrent workers") }
            next.maxConcurrentOperators = count
        }
        if let value = options["max-helpers"] {
            guard let count = Int(value), (0...2).contains(count) else { throw RPCError(message: "Choose zero to two helpers per worker") }
            next.maxHelpersPerOperator = count
        }
        // Profile changes apply to future turns; workspace, pairing and access
        // changes retain their stronger invalidate-and-revoke boundary.
        try await store.saveSettings(next)
        settings = next; models = catalog
        await gateway.agentSettingsDidChange()
    }
    private func saveSettingsAcrossBoundary(_ next: Settings) async throws {
        try await gateway.beginSettingsBoundaryChange()
        do {
            try await store.saveSettings(next)
        } catch {
            await gateway.abortSettingsBoundaryChange(error)
            throw error
        }
        settings = next
        await gateway.endBoundaryChange()
    }
    func setPaused(_ value: Bool) async throws { try await gateway.setPaused(value) }
    func boundaryChangeIsActive() async -> Bool { await gateway.boundaryChangeIsActive() }

    func configureIdentity(name: String?, personality: String?) async throws {
        let identity = try SteveOnboarding.identity(name: name ?? settings.displayName, personality: personality ?? settings.personality)
        var next = settings
        next.displayName = identity.name
        next.personality = identity.personality
        try await store.saveSettings(next)
        settings = next
        await gateway.agentSettingsDidChange()
    }

    func configureOwner(_ input: String) async throws -> String {
        let address = try SteveOnboarding.ownerAddress(input)
        let accounts = try await messages.discoverAccounts()
        let receiveAddress = try SteveOnboarding.receivingAddress(for: address, accounts: accounts)
        try await gateway.configureOwner(address: address, receiveAddress: receiveAddress)
        return receiveAddress
    }

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

    func disconnectPhone() async throws {
        try await gateway.beginSettingsBoundaryChange()
        do {
            try await store.saveOwnerSetup(nil)
            try await store.saveTrustedConversation(nil)
            await gateway.endBoundaryChange()
        } catch { await gateway.abortSettingsBoundaryChange(error); throw error }
    }
}

func normalizeHandle(_ value: String) -> String {
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

extension GatewayCoordinator {
    private func taskSummaries(chatGuid: String, workspace: String, permission: String) async throws -> [OperatorTaskSummary] {
        let tasks = try await store.operatorTasks(chatGuid: chatGuid).filter { $0.workspace == workspace && $0.permission == permission }
        let active = tasks.filter { [.queued, .running, .awaitingDelivery].contains($0.state) }
        let recent = tasks.filter { !active.contains($0) }.sorted { $0.updatedAt < $1.updatedAt }.suffix(20)
        return (active + recent).map(OperatorTaskSummary.init)
    }

    private func prepareRelay(chatGuid: String, workspace: String, permission: String, settings: Settings, messageGuid: String, epoch: String) async throws -> String {
        let existing = try await store.agentSession(for: chatGuid)
        let context = StevePromptContext(workspace: workspace, permissionProfile: permission, model: settings.model, effort: settings.effort, agentName: settings.displayName, personality: settings.personality)
        let profile = try await codex.relayProfile(settings: settings)
        let compatible = existing?.workspacePath == workspace && existing?.permissionProfile == permission
        // A loaded App Server thread can retain its original developer contract.
        // Migrate once when that contract changes; durable tasks/preferences
        // carry forward without replaying old work or copying stale instructions.
        var relayID = compatible && existing?.relayPromptVersion == StevePrompt.relayPromptVersion ? existing?.relayThreadID : nil
        if let id = relayID {
            do { try await codex.resumeThread(threadID: id, cwd: workspace, permissionProfile: "read-only", model: profile.model, developerInstructions: StevePrompt.relayInstructions(context), isRelay: true, serviceTier: profile.serviceTier) }
            catch {
                guard CodexSessionRecovery.shouldReplaceResumedThread(for: error) else { throw error }
                relayID = nil
            }
        }
        if relayID == nil { relayID = try await codex.startThread(cwd: workspace, permissionProfile: "read-only", model: profile.model, developerInstructions: StevePrompt.relayInstructions(context), isRelay: true, serviceTier: profile.serviceTier) }
        try check(epoch)
        if compatible, let existing, !existing.threadID.isEmpty,
           try await store.operatorTasks(chatGuid: chatGuid).isEmpty,
           let trusted = try await store.trustedConversation() {
            let legacy = OperatorTaskRecord(id: UUID().uuidString, chatGuid: chatGuid, senderHandle: trusted.senderHandle,
                workspace: workspace, permission: permission, title: "Earlier conversation", objective: "Earlier worker context; continue only when the user refers to this work.",
                threadID: existing.threadID, mode: .computer, state: .completed, inbound: [], runID: UUID().uuidString,
                summary: "Previous worker history retained during upgrade.")
            try await store.saveOperatorTask(legacy, expectedEpoch: epoch)
        }
        try await savePair(chatGuid: chatGuid, workerThreadID: compatible ? (existing?.threadID ?? "") : "", relayThreadID: relayID!, workspace: workspace, permission: permission, settings: settings, messageGuid: messageGuid, epoch: epoch, executionState: "running")
        return relayID!
    }

    private func routeOperator(_ request: RelayRequestEnvelope, inbound: [SteveInboundMessage], workspace: String, permission: String, settings: Settings, additionalContext: String, scheduledRunID: String?, epoch: String) async throws {
        guard let first = inbound.first, let brief = request.workerPrompt else { throw AgentEnvelopeError.invalidPayload("execute requires a prompt") }
        let prompt = "ORIGINAL_USER_MESSAGES_JSON (authoritative intent and authorization):\n" + (try encodeJSON(inbound)) + "\n\nRELAY_BRIEF:\n" + brief
        var task: OperatorTaskRecord
        var queuedContextAction: WorkerContextAction?
        if let id = request.taskID {
            guard let existing = try await store.operatorTask(id: id), existing.chatGuid == first.chatGuid,
                  normalizeHandle(existing.senderHandle) == normalizeHandle(first.senderHandle), existing.workspace == workspace, existing.permission == permission else {
                throw AgentEnvelopeError.invalidPayload("Follow-up task is outside the current conversation boundary")
            }
            task = existing
            task.originalMessages = existing.originalMessages ?? existing.inbound
            if task.state == .awaitingDelivery {
                await deliverOperator(task, epoch: epoch)
                guard let delivered = try await store.operatorTask(id: id), delivered.state != .awaitingDelivery else { throw CancellationError() }
                task = delivered
            }
            if task.state == .running {
                guard request.workerContextAction == nil || request.workerContextAction == .reuse else { throw RPCError(message: "Stop this task before replacing or compacting its active context.") }
                let update = OperatorFollowUp(text: prompt + additionalContext, attachmentPaths: inbound.flatMap(\.attachmentPaths), inbound: inbound)
                let updated = try await store.updateOperatorTask(id: id, expectedEpoch: epoch, expectedRunID: task.runID) { current in
                    current.originalMessages = Self.mergeOriginals(current.originalMessages ?? current.inbound, inbound)
                    // A turn can finish while routing awaits SQLite. Preserve its
                    // result and queue this update for its owner in that case.
                    if current.state == .running || current.state == .awaitingDelivery {
                        current.pendingFollowUps = (current.pendingFollowUps ?? []) + [update]
                    } else if current.state == .queued {
                        current.inbound += inbound
                        current.objective += "\n\nFollow-up: " + update.text
                    } else {
                        current.inbound = inbound
                        current.objective = "Continue this task with the user's follow-up. Check existing results before acting: " + update.text
                        current.state = .queued
                        current.runID = UUID().uuidString
                        current.result = nil
                        current.contextAction = .reuse
                    }
                }
                if updated.state == .running, let thread = updated.threadID, let turn = activeWorkers[thread]?.turnID {
                    let previous = steeringTasks[id]
                    let steeringID = UUID()
                    steeringTasks[id] = Task {
                        defer { self.inFlightTasks.removeValue(forKey: steeringID) }
                        await previous?.value
                        await self.flushFollowUps(taskID: id, runID: updated.runID, epoch: epoch, threadID: thread, turnID: turn)
                    }
                    inFlightTasks[steeringID] = steeringTasks[id]
                    await steeringTasks[id]?.value
                }
                return
            }
            if task.state == .queued {
                queuedContextAction = task.contextAction
                task.objective += "\n\nFollow-up: " + prompt + additionalContext
                task.inbound += inbound
            } else {
                task.objective = prompt + additionalContext + (task.state == .uncertain || task.state == .interrupted ? "\nEarlier execution was interrupted or uncertain. Inspect actual state before any further action; never blindly repeat it." : "")
                task.inbound = inbound
            }
            task.runID = UUID().uuidString
            task.result = nil
            task.state = .queued
            task.mode = request.mode ?? task.mode
        } else {
            task = OperatorTaskRecord(id: UUID().uuidString, chatGuid: first.chatGuid, senderHandle: first.senderHandle,
                workspace: workspace, permission: permission, title: String((request.taskTitle ?? first.text).prefix(100)),
                objective: prompt + additionalContext, mode: request.mode ?? .computer, state: .queued, inbound: inbound, runID: UUID().uuidString)
        }
        // An ordinary correction must not undo a fresh/compact action that is
        // still queued behind another computer owner.
        let requestedContextAction = request.workerContextAction ?? .reuse
        task.contextAction = requestedContextAction == .reuse ? (queuedContextAction ?? .reuse) : requestedContextAction
        task.originalMessages = Self.mergeOriginals(task.originalMessages ?? task.inbound, inbound)
        task.handoff = nil
        task.acknowledgementSentAt = nil
        task.lastProgressAt = nil
        task.lastProgress = nil
        task.scheduledRunID = scheduledRunID
        task.updatedAt = Date()
        try check(epoch)
        try await store.saveOperatorTask(task, expectedEpoch: epoch)
    }

    private func scheduleOperators(epoch: String) async throws {
        try check(epoch)
        let settings = try await store.getSettings() ?? defaultSettings()
        let tasks = try await store.operatorTasks()
        let loginReserved = tasks.contains { task in
            guard task.mode == .computer, [.blocked, .awaitingDelivery].contains(task.state),
                  let handoff = task.handoff, handoff.blocker.reason == .signIn,
                  handoff.blocker.pageVerified == true, handoff.completedAt == nil else { return false }
            return (handoff.linkIssuedAt ?? handoff.createdAt).addingTimeInterval(120) > clockNow()
        }
        for var task in tasks where task.state == .queued {
            guard operatorRuns.count < settings.maxConcurrentOperators else { break }
            guard operatorRuns[task.id] == nil else { continue }
            if task.mode == .computer && (computerOwner != nil || loginReserved || (loginReservation?.expiresAt ?? .distantPast) > clockNow()) { continue }
            let trusted = try await store.trustedConversation()
            guard task.chatGuid == trusted?.chatGuid, normalizeHandle(task.senderHandle) == normalizeHandle(trusted?.senderHandle ?? ""),
                  task.workspace == settings.workspaceRoot, task.permission == settings.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) else {
                task.state = .cancelled; try await store.saveOperatorTask(task, expectedEpoch: epoch); continue
            }
            try check(epoch)
            task.state = .running
            try await store.saveOperatorTask(task, expectedEpoch: epoch, expectedRunID: task.runID)
            try check(epoch)
            if task.mode == .computer { computerOwner = task.id }
            let launched = task
            let runningID = UUID()
            operatorRuns[task.id] = Task {
                defer { self.inFlightTasks.removeValue(forKey: runningID) }
                await self.runOperator(launched, settings: settings, epoch: epoch)
            }
            inFlightTasks[runningID] = operatorRuns[task.id]
        }
    }

    private func runOperator(_ launched: OperatorTaskRecord, settings: Settings, epoch: String) async {
        let openingDeadline = ContinuousClock.now.advanced(by: acknowledgementDelay)
        var threadID: String?
        var actionsStarted = false
        var quiescent = true
        defer {
            if let threadID { activeWorkers.removeValue(forKey: threadID) }
            operatorRuns.removeValue(forKey: launched.id)
            if quiescent, computerOwner == launched.id { computerOwner = nil }
            steeringTasks.removeValue(forKey: launched.id)
            if self.epoch == epoch { scheduleWork() }
        }
        do {
            try check(epoch)
            let root = URL(fileURLWithPath: launched.workspace).resolvingSymlinksInPath()
            let artifacts = root.appendingPathComponent(".steve-tasks").appendingPathComponent(launched.id)
            guard artifacts.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw RPCError(message: "Task artifact directory is outside the workspace") }
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            guard artifacts.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw RPCError(message: "Task artifact directory moved outside the workspace") }
            let context = StevePromptContext(workspace: launched.workspace, permissionProfile: launched.permission, model: settings.model, effort: settings.effort, agentName: settings.displayName, personality: settings.personality)
            let instructions = StevePrompt.workerInstructions(context) + "\n\n" + StevePrompt.operatorOwnership(mode: launched.mode, maxHelpers: settings.maxHelpersPerOperator, artifacts: artifacts.path)
            let oldID = launched.contextAction == .fresh ? nil : launched.threadID
            do {
                threadID = try await codex.operatorThread(threadID: oldID, cwd: launched.workspace, permissionProfile: launched.permission, profile: settings.operatorProfile, instructions: instructions, mode: launched.mode, maxHelpers: settings.maxHelpersPerOperator)
            } catch {
                guard oldID != nil, CodexSessionRecovery.shouldReplaceResumedThread(for: error) else { throw error }
                threadID = try await codex.operatorThread(threadID: nil, cwd: launched.workspace, permissionProfile: launched.permission, profile: settings.operatorProfile, instructions: instructions, mode: launched.mode, maxHelpers: settings.maxHelpersPerOperator)
            }
            guard let threadID, var current = try await store.operatorTask(id: launched.id), current.runID == launched.runID, current.state == .running, let first = current.inbound.first else { throw CancellationError() }
            current.threadID = threadID
            try await store.saveOperatorTask(current, expectedEpoch: epoch, expectedRunID: launched.runID)
            if launched.contextAction == .compact { try await codex.compactThread(threadID: threadID) }
            activeWorkers[threadID] = WorkerBinding(epoch: epoch, threadID: threadID, taskID: launched.id, turnID: nil, message: first)
            actionsStarted = true
            quiescent = false
            let start = Date()
            let originalContext = "\n\nPRIOR_USER_MESSAGES_JSON:\n" + (try encodeJSON(current.originalMessages ?? current.inbound))
            let result = try await codex.runTurn(threadID: threadID, text: current.objective + originalContext, attachmentPaths: current.inbound.flatMap(\.attachmentPaths), workspace: current.workspace,
                model: settings.model, effort: settings.effort, serviceTier: settings.serviceTier, onProgress: { event in
                    guard event.phase == .commentary else { return }
                    await self.receiveOperatorProgress(taskID: launched.id, runID: launched.runID, text: event.text, epoch: epoch, notBefore: openingDeadline)
                }, onTurnStarted: { turnID in
                    await self.operatorTurnStarted(taskID: launched.id, epoch: epoch, threadID: threadID, turnID: turnID)
                })
            try check(epoch)
            // The owner must join its helpers before a result can be delivered
            // or the Mac can be handed to a different task.
            try await codex.stopDescendants(threadID: threadID)
            quiescent = true
            activeWorkers.removeValue(forKey: threadID)
            await steeringTasks[launched.id]?.value
            var envelope = try AgentEnvelopeParser.workerResult(from: result.text)
            var verified = try verifiedArtifacts(from: envelope, workspace: launched.workspace, nativeCapturePaths: result.nativeCapturePaths)
            func needsReadableFormat(_ files: [WorkerArtifactEnvelope], task: OperatorTaskRecord) -> Bool {
                guard !StevePrompt.markdownRequested(in: (task.originalMessages ?? task.inbound).map(\.text)) else { return false }
                return files.contains { ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased()) || $0.mimeType?.lowercased().contains("markdown") == true }
            }
            guard let latest = try await store.operatorTask(id: launched.id), latest.runID == launched.runID, latest.state == .running else { throw CancellationError() }
            try check(epoch)
            if !(launched.mode == .background && envelope.status == .needsComputer), needsReadableFormat(verified, task: latest) {
                let originalArtifacts = verified
                let targetExtension = StevePrompt.readableDocumentExtension(in: (latest.originalMessages ?? latest.inbound).map(\.text))
                activeWorkers[threadID] = WorkerBinding(epoch: epoch, threadID: threadID, taskID: launched.id, turnID: nil, message: first)
                quiescent = false
                let repair = "Your completed work is retained. Only repair the deliverable format: convert the Markdown attachments below into readable \(targetExtension.uppercased()) files, reopen and verify them, then return the same result and any blocker with corrected artifacts. Keep each artifact ID, replacing each Markdown file with the requested format and retaining all other artifacts. Do not repeat external actions or do new research. The user did not request Markdown.\nVERIFIED_ARTIFACTS_JSON:\n" + (try encodeJSON(verified)) + "\nCOMPLETED_RESULT_JSON:\n" + (try encodeJSON(envelope))
                let repaired = try await codex.runTurn(threadID: threadID, text: repair, attachmentPaths: [], workspace: current.workspace,
                    model: settings.model, effort: settings.effort, serviceTier: settings.serviceTier, onProgress: nil, onTurnStarted: { turnID in
                        await self.operatorTurnStarted(taskID: launched.id, epoch: epoch, threadID: threadID, turnID: turnID)
                    })
                try check(epoch)
                try await codex.stopDescendants(threadID: threadID)
                quiescent = true
                activeWorkers.removeValue(forKey: threadID)
                await steeringTasks[launched.id]?.value
                envelope = try AgentEnvelopeParser.workerResult(from: repaired.text)
                verified = try verifiedArtifacts(from: envelope, workspace: launched.workspace, nativeCapturePaths: result.nativeCapturePaths + repaired.nativeCapturePaths)
                guard let afterRepair = try await store.operatorTask(id: launched.id), afterRepair.runID == launched.runID, afterRepair.state == .running else { throw CancellationError() }
                guard !needsReadableFormat(verified, task: afterRepair), originalArtifacts.allSatisfy({ original in
                    guard let replacement = verified.first(where: { $0.id == original.id }) else { return false }
                    if ["md", "markdown", "mdown", "mkd"].contains(URL(fileURLWithPath: original.path).pathExtension.lowercased()) || original.mimeType?.lowercased().contains("markdown") == true {
                        return URL(fileURLWithPath: replacement.path).pathExtension.lowercased() == targetExtension
                            && (targetExtension != "pdf" || (PDFDocument(url: URL(fileURLWithPath: replacement.path))?.pageCount ?? 0) > 0)
                    }
                    return replacement.path == original.path
                }) else { throw AgentEnvelopeError.invalidPayload("The task did not prepare readable replacement files after one format correction") }
            }
            let finalEnvelope = envelope
            let accepted = WorkerResultEnvelope(schemaVersion: finalEnvelope.schemaVersion, kind: finalEnvelope.kind, status: finalEnvelope.status, summary: finalEnvelope.summary, userQuestion: finalEnvelope.userQuestion, artifacts: verified, blocker: finalEnvelope.blocker, plan: finalEnvelope.plan, notifyUser: finalEnvelope.notifyUser)
            if launched.mode == .computer, finalEnvelope.blocker?.reason == .signIn, finalEnvelope.blocker?.pageVerified == true {
                loginReservation = (launched.id, launched.runID, clockNow().addingTimeInterval(120))
            }
            try await store.updateOperatorTask(id: launched.id, expectedEpoch: epoch, expectedRunID: launched.runID) { task in
                guard task.state == .running else { throw CancellationError() }
                task.summary = finalEnvelope.summary
                task.result = accepted
                if let blocker = finalEnvelope.blocker {
                    task.handoff = TaskHandoff(taskID: task.id, runID: task.runID, blocker: blocker, createdAt: self.clockNow())
                }
                if finalEnvelope.status == .needsComputer && task.mode == .background {
                    task.mode = .computer; task.state = .queued
                    task.objective = "Continue your same task using the connected services and Computer Use now available. Verify current state before actions. Original goal:\n" + task.objective
                    task.contextAction = .reuse
                } else {
                    task.state = .awaitingDelivery
                }
            }
            SteveLog.write("Worker completed mode=\(launched.mode.rawValue) seconds=\(Int(Date().timeIntervalSince(start))) status=\(finalEnvelope.status.rawValue)")
        } catch {
            if let threadID, self.epoch == epoch {
                for id in approvals.keys.filter({ approvals[$0]?.binding.threadID == threadID }) { finishApproval(id: id, decision: .cancel) }
                // Cleanup runs outside the cancelled task so RPC cancellation
                // cannot suppress the interrupt. A failed stop keeps the lease.
                let client = codex
                quiescent = await Task {
                    do { try await client.quiesceThread(threadID: threadID); try await client.stopDescendants(threadID: threadID); return true }
                    catch { return false }
                }.value
                if !quiescent { transportError = "A task could not be confirmed stopped. Pause and resume Steve before more computer tasks." }
            }
            if self.epoch == epoch, !Task.isCancelled,
               var task = try? await store.operatorTask(id: launched.id), task.runID == launched.runID, task.state == .running {
                if (task.recoveryAttempts ?? 0) < 1, (!actionsStarted || task.mode == .background), CodexSessionRecovery.shouldReplaceResumedThread(for: error), quiescent {
                    task.recoveryAttempts = (task.recoveryAttempts ?? 0) + 1
                    task.contextAction = .fresh; task.state = .queued
                    let previousRun = task.runID; task.runID = UUID().uuidString
                    task.objective = "Recover this safe read or unstarted task once, preserving the original scope.\n" + task.objective
                    try? await store.saveOperatorTask(task, expectedEpoch: epoch, expectedRunID: previousRun)
                    return
                }
                task.state = actionsStarted ? .uncertain : .failed
                task.summary = actionsStarted ? "The final outcome could not be verified. Actions may have completed; nothing was retried." : "The task could not be started."
                try? await store.saveOperatorTask(task, expectedEpoch: epoch, expectedRunID: launched.runID)
                try? await store.finishInbox(task.inbound.map(\.guid), state: task.state.rawValue)
                if let run = task.scheduledRunID { try? await automation?.recordExecutionOutcome(id: run, outcome: .failed) }
                try? await stageTaskNotice(task, text: task.title + ": " + task.summary, prefix: "outcome:", epoch: epoch)
                SteveLog.write("Worker needs review error=\(error.localizedDescription)")
            }
        }
    }

    private func projectMemory(authorization: ScheduleAuthorization) async throws {
        // A projection problem must not discard an accepted preference or task.
        do { try await automation?.projectMemory(workspace: authorization.workspace, authorization: authorization) }
        catch { SteveLog.write("Private memory projection unavailable: " + error.localizedDescription) }
    }

    private static func mergeOriginals(_ old: [SteveInboundMessage], _ new: [SteveInboundMessage]) -> [SteveInboundMessage] {
        var seen = Set<String>()
        return (old + new).filter { seen.insert($0.guid).inserted }
    }

    private func receiveOperatorProgress(taskID: String, runID: String, text: String, epoch: String, notBefore: ContinuousClock.Instant) async {
        do { try check(epoch) } catch { return }
        guard let message = ConversationProgress.safeMessage(text) else { return }
        guard ContinuousClock.now < notBefore else {
            await operatorProgress(taskID: taskID, runID: runID, text: message, epoch: epoch)
            return
        }
        // Hold the agent's opening for slow tasks without blocking its tools.
        // No generated opening means no acknowledgement; never invent a fallback.
        guard pendingProgressRuns.insert(runID).inserted else { return }
        let timerID = UUID()
        inFlightTasks[timerID] = Task {
            defer {
                self.pendingProgressRuns.remove(runID)
                self.inFlightTasks.removeValue(forKey: timerID)
            }
            do { try await Task.sleep(until: notBefore, clock: .continuous) }
            catch { return }
            await self.operatorProgress(taskID: taskID, runID: runID, text: message, epoch: epoch)
        }
    }

    private func operatorProgress(taskID: String, runID: String, text: String, epoch: String) async {
        do {
            try check(epoch)
            guard let message = ConversationProgress.safeMessage(text),
                  !approvals.values.contains(where: { $0.binding.taskID == taskID }) else { return }
            let now = clockNow()
            let task = try await store.updateOperatorTask(id: taskID, expectedEpoch: epoch, expectedRunID: runID) { current in
                guard current.state == .running, let first = current.inbound.first, !first.guid.hasPrefix("schedule:"), message != current.lastProgress else { throw CancellationError() }
                if current.lastProgressAt == nil {
                    current.acknowledgementSentAt = now
                } else if let last = current.lastProgressAt, now.timeIntervalSince(last) < 60 { throw CancellationError() }
                current.lastProgressAt = now; current.lastProgress = message
            }
            guard let first = task.inbound.first else { return }
            let part = SteveStore.OutboundPart(id: "progress:" + task.id + ":" + runID + ":" + UUID().uuidString, chatGuid: task.chatGuid, recipient: task.senderHandle, replyTo: first.guid, inboxGUIDs: [], text: message, attachmentPath: nil, workspace: task.workspace, permission: task.permission)
            try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: epoch)
            scheduleDelivery()
        } catch { /* Progress is optional; never fail or replay the user's task. */ }
    }

    private func operatorTurnStarted(taskID: String, epoch: String, threadID: String, turnID: String) async {
        await turnStarted(epoch: epoch, threadID: threadID, turnID: turnID)
        guard let task = try? await store.operatorTask(id: taskID) else { return }
        await flushFollowUps(taskID: taskID, runID: task.runID, epoch: epoch, threadID: threadID, turnID: turnID)
    }

    private func flushFollowUps(taskID: String, runID: String, epoch: String, threadID: String, turnID: String) async {
        guard let task = try? await store.operatorTask(id: taskID), task.runID == runID else { return }
        for update in task.pendingFollowUps ?? [] {
            do {
                try check(epoch)
                try await codex.steerTurn(threadID: threadID, expectedTurnID: turnID, text: update.text, attachmentPaths: update.attachmentPaths)
                try await store.updateOperatorTask(id: taskID, expectedEpoch: epoch, expectedRunID: runID) { current in
                    if current.pendingFollowUps?.contains(where: { $0.id == update.id }) == true { current.inbound += update.inbound }
                    current.pendingFollowUps?.removeAll { $0.id == update.id }
                }
            } catch {
                // The turn may already be finishing. The durable update will
                // become a continuation after its current result is delivered.
                return
            }
        }
    }

    private func deliverOperator(_ task: OperatorTaskRecord, epoch: String) async {
        do {
            try check(epoch)
            guard let envelope = task.result, let first = task.inbound.first else { throw AgentEnvelopeError.invalidPayload("Task result is missing") }
            let settings = try await store.getSettings() ?? defaultSettings()
            let trusted = try await store.trustedConversation()
            guard trusted?.chatGuid == task.chatGuid, normalizeHandle(trusted?.senderHandle ?? "") == normalizeHandle(task.senderHandle),
                  settings.workspaceRoot == task.workspace, settings.permissionProfile?.trimmingCharacters(in: CharacterSet(charactersIn: ":")) == task.permission else { throw CancellationError() }
            let authorization = try ScheduleAuthorization(chatGUID: task.chatGuid, senderHandle: task.senderHandle, workspace: task.workspace, permission: task.permission)
            var followUpStatus = envelope.plan != nil && task.scheduledRunID == nil
                ? "No future checks were scheduled. Do not promise monitoring or an end notification." : nil
            if let update = envelope.plan, task.scheduledRunID == nil, let automation,
               let source = (task.originalMessages ?? task.inbound).last(where: { !$0.guid.hasPrefix("schedule:") && $0.text.contains(update.userQuote) }) {
                let provenance = ExplicitUserProvenance(source: .pairedMessage, sourceID: source.guid, statement: update.userQuote, explicitlyRequested: true, recordedAt: clockNow())
                let timeZone = StevePrompt.userTimeZone(preferences: try await automation.preferences(), configured: settings.timezone)
                try await automation.savePlan(taskID: task.id, update: update, authorization: authorization, provenance: provenance, timeZone: timeZone, now: clockNow(), expectedEpoch: epoch)
                try await projectMemory(authorization: authorization)
                if let saved = try await automation.plans(authorization: authorization).first(where: { $0.taskID == task.id }),
                   let id = saved.scheduleID, let schedule = try await automation.schedule(id: id),
                   schedule.state == .active, let next = schedule.nextRunAt, let policy = schedule.followUp {
                    let formatter = ISO8601DateFormatter()
                    formatter.timeZone = TimeZone(identifier: timeZone)
                    followUpStatus = "Read-only follow-through is scheduled. Next check: \(formatter.string(from: next)); subsequent fallback checks at most daily at 9 AM. Stops before \(formatter.string(from: policy.expiresAt)). Notify only of meaningful changes; no end notification is scheduled."
                }
            }
            var deferNotificationUntil: Date?
            var followUpRunID: String?
            if let runID = task.scheduledRunID, let automation, let run = try await automation.run(id: runID), let policy = run.followUp {
                followUpRunID = runID
                let followUpSchedule = try await automation.schedule(id: run.scheduleID)
                deferNotificationUntil = policy.deferredUntil(now: clockNow(), timeZone: followUpSchedule?.timeZone ?? StevePrompt.defaultTimeZone(configured: settings.timezone))
                let valid = try await automation.validateEnqueued(id: runID, authorization: authorization)
                let meaningful = envelope.notifyUser != false && valid && clockNow() < policy.expiresAt
                let notify = meaningful ? try await automation.reservePlanNotification(taskID: policy.taskID, summary: envelope.summary, expectedEpoch: epoch) : false
                if !notify {
                    try await store.updateOperatorTask(id: task.id, expectedEpoch: epoch, expectedRunID: task.runID) { $0.state = !valid ? .cancelled : envelope.status == .completed ? .completed : .blocked }
                    if valid { try await automation.recordExecutionOutcome(id: runID, outcome: envelope.status == .completed ? .succeeded : .failed) }
                    else { try await automation.recordOutcome(id: runID, state: .cancelled, detail: "Plan ended before notification.", now: clockNow()) }
                    try await store.finishInbox(task.inbound.map(\.guid), state: valid ? "completed" : "cancelled")
                    return
                }
            }
            let relay = try await prepareRelay(chatGuid: task.chatGuid, workspace: task.workspace, permission: task.permission, settings: settings, messageGuid: first.guid, epoch: epoch)
            let profile = try await codex.relayProfile(settings: settings)
            let artifactSummary = envelope.artifacts.map { ["id": $0.id, "caption": $0.caption ?? "", "mimeType": $0.mimeType ?? ""] }
            let input = "WORKER_RESULT_JSON:\n\(try encodeJSON(envelope))\n\nTASK_TITLE: \(task.title)\nTASK_ID: \(task.id)\n\nVERIFIED_ARTIFACTS_JSON:\n\(try encodeJSON(artifactSummary))\n\nRECOVERY_ATTEMPTED: true. Deliver this task's verified result; never repeat its execution."
                + (followUpStatus.map { "\n\nFOLLOW_UP_STATUS (authoritative runtime state, overrides scheduling claims in the summary):\n" + $0 } ?? "")
            let result = try await codex.runTurn(threadID: relay, text: input, attachmentPaths: [], workspace: task.workspace, model: profile.model, effort: profile.effort, serviceTier: profile.serviceTier, onTurnStarted: { _ in })
            let plan = try AgentEnvelopeParser.deliveryPlan(from: result.text)
            guard plan.recovery == nil else { throw AgentEnvelopeError.invalidPayload("Completed work cannot be replayed") }
            guard let current = try await store.operatorTask(id: task.id), current.runID == task.runID, current.state == .awaitingDelivery else { throw CancellationError() }
            let map = Dictionary(uniqueKeysWithValues: envelope.artifacts.map { ($0.id, $0) })
            let selected = try plan.attachments.map { item -> (String, String) in
                guard let artifact = map[item.artifactID] else { throw AgentEnvelopeError.invalidPayload("Unknown task artifact") }
                return (artifact.path, item.caption ?? artifact.caption ?? "")
            }
            try await stage(messages: plan.messages, attachments: selected, inbound: current.inbound, workspace: task.workspace, permission: task.permission, epoch: epoch, notBefore: deferNotificationUntil, followUpRunID: followUpRunID)
            try await store.updateOperatorTask(id: task.id, expectedEpoch: epoch, expectedRunID: task.runID) { finished in
                switch envelope.status {
                case .completed: finished.state = .completed
                case .needsClarification: finished.state = .needsClarification
                case .blocked, .needsComputer: finished.state = .blocked
                case .failed: finished.state = .failed
                }
                if let followUps = finished.pendingFollowUps, !followUps.isEmpty {
                    finished.state = .queued
                    finished.objective = "Continue with these user follow-ups. Your earlier result was delivered; inspect current state and do not repeat completed actions.\n" + followUps.map(\.text).joined(separator: "\n\n")
                    finished.inbound = followUps.flatMap(\.inbound)
                    finished.pendingFollowUps = []
                    finished.result = nil
                    finished.runID = UUID().uuidString
                    finished.contextAction = .reuse
                }
            }
            if envelope.blocker?.reason == .signIn, envelope.blocker?.pageVerified == true,
               task.scheduledRunID == nil, (task.pendingFollowUps ?? []).isEmpty {
                await offerPhoneHandoff(taskID: task.id, epoch: epoch)
            }
            if let run = task.scheduledRunID { try await automation?.recordExecutionOutcome(id: run, outcome: envelope.status == .completed ? .succeeded : .failed) }
            try await store.finishAgentSession(chatGuid: task.chatGuid, messageGuid: first.guid, state: "idle", expectedEpoch: epoch)
        } catch {
            guard self.epoch == epoch, !Task.isCancelled else { return }
            var failed = task; failed.state = .uncertain
            try? await store.saveOperatorTask(failed, expectedEpoch: epoch, expectedRunID: task.runID)
            try? await store.finishInbox(task.inbound.map(\.guid), state: "uncertain")
            try? await stageTaskNotice(task, text: "I finished working on \(task.title), but couldn't prepare its reply. I haven't repeated the task.", prefix: "delivery-outcome:", epoch: epoch)
            SteveLog.write("Worker delivery requires review error=\(error.localizedDescription)")
        }
    }

    private func stageTaskNotice(_ task: OperatorTaskRecord, text: String, prefix: String, epoch: String) async throws {
        try PreferenceSafety.rejectCredentials(in: text)
        guard let first = task.inbound.first, let current = try await store.operatorTask(id: task.id),
              current.runID == task.runID, [.failed, .uncertain].contains(current.state) else { return }
        var part = SteveStore.OutboundPart(id: prefix + task.runID, chatGuid: task.chatGuid, recipient: task.senderHandle, replyTo: first.guid, inboxGUIDs: [], text: text, attachmentPath: nil, workspace: task.workspace, permission: task.permission)
        if let runID = task.scheduledRunID, let automation, let run = try await automation.run(id: runID), let policy = run.followUp {
            guard try await automation.validateFollowUpDelivery(id: runID, authorization: run.authorization, now: clockNow()),
                  let schedule = try await automation.schedule(id: run.scheduleID) else { return }
            part.followUpRunID = runID
            part.notBefore = policy.deferredUntil(now: clockNow(), timeZone: schedule.timeZone)
        }
        try await store.stageDelivery([part], inboxGUIDs: [], expectedEpoch: epoch)
        scheduleDelivery()
    }

    private func cancelOperator(id: String, inbound: [SteveInboundMessage], workspace: String, permission: String, epoch: String) async throws {
        guard let first = inbound.first, var task = try await store.operatorTask(id: id), task.chatGuid == first.chatGuid,
              normalizeHandle(task.senderHandle) == normalizeHandle(first.senderHandle), task.workspace == workspace, task.permission == permission else { throw RPCError(message: "That task is not in this conversation") }
        if let source = inbound.first, !source.guid.hasPrefix("schedule:") {
            let provenance = ExplicitUserProvenance(source: .pairedMessage, sourceID: source.guid, statement: source.text, explicitlyRequested: true, recordedAt: clockNow())
            try await automation?.cancelPlan(taskID: task.id, provenance: provenance, now: clockNow(), expectedEpoch: epoch)
            try await projectMemory(authorization: ScheduleAuthorization(chatGUID: task.chatGuid, senderHandle: task.senderHandle, workspace: workspace, permission: permission))
        }
        task.state = .cancelled
        task.handoff = nil
        let originalRun = task.runID
        task.runID = UUID().uuidString
        try await store.saveOperatorTask(task, expectedEpoch: epoch, expectedRunID: originalRun)
        if loginReservation?.taskID == id { loginReservation = nil }
        let run = operatorRuns[id]
        if let thread = task.threadID {
            for id in approvals.keys.filter({ approvals[$0]?.binding.threadID == thread }) { finishApproval(id: id, decision: .cancel) }
        }
        run?.cancel()
        await run?.value
        if computerOwner == id { throw RPCError(message: "The task's stop could not be verified. Pause and resume Steve before more computer work.") }
        if run == nil, let thread = task.threadID { try await codex.quiesceThread(threadID: thread); try await codex.stopDescendants(threadID: thread) }
        try await store.finishInbox(task.inbound.map(\.guid), state: "cancelled")
        try await stage(messages: ["Stopped \(task.title)."], attachments: [], inbound: inbound, workspace: workspace, permission: permission, epoch: epoch)
    }
}
