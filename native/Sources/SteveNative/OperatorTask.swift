import Foundation

enum OperatorMode: String, Codable, Sendable {
    case background, computer
}

enum OperatorTaskState: String, Codable, Sendable {
    case queued, running, awaitingDelivery, completed, needsClarification, blocked, failed, cancelled, interrupted, uncertain
}

struct OperatorFollowUp: Codable, Sendable, Equatable, Identifiable {
    var id = UUID().uuidString
    let text: String
    let attachmentPaths: [String]
    let inbound: [SteveInboundMessage]
}

/// A user goal survives relay turns, app restarts, and model changes. Only the
/// current run's inbound messages are settled by its eventual delivery.
struct OperatorTaskRecord: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let chatGuid: String
    let senderHandle: String
    let workspace: String
    let permission: String
    var title: String
    var objective: String
    var threadID: String?
    var mode: OperatorMode
    var state: OperatorTaskState
    var inbound: [SteveInboundMessage]
    var runID: String
    var summary: String = ""
    var result: WorkerResultEnvelope?
    var scheduledRunID: String?
    var contextAction: WorkerContextAction = .reuse
    var pendingFollowUps: [OperatorFollowUp]?
    var originalMessages: [SteveInboundMessage]? = nil
    var handoff: TaskHandoff? = nil
    var acknowledgementSentAt: Date? = nil
    var lastProgressAt: Date? = nil
    var lastProgress: String? = nil
    var recoveryAttempts: Int? = nil
    var createdAt = Date()
    var updatedAt = Date()

    var canContinue: Bool { ![.running, .queued, .awaitingDelivery].contains(state) }
}

struct OperatorTaskSummary: Codable, Sendable, Equatable {
    let id: String
    let title: String
    let state: OperatorTaskState
    let summary: String
    let lastMessageGUID: String?
    let mode: OperatorMode
    var blocker: WorkerBlocker? = nil

    init(_ task: OperatorTaskRecord) {
        id = task.id; title = task.title; state = task.state
        summary = String(task.summary.prefix(1800)); lastMessageGUID = task.inbound.last?.guid
        mode = task.mode
        blocker = task.handoff?.blocker ?? task.result?.blocker
    }
}

struct AgentModelProfile: Sendable, Equatable {
    let model: String
    let effort: String
    let serviceTier: SteveServiceTier
}

extension Settings {
    var operatorProfile: AgentModelProfile { .init(model: model, effort: effort, serviceTier: serviceTier) }
}
