import Foundation

/// The wire contract between the relay and worker turns. Keeping this
/// Codable and versioned makes the orchestration inspectable and lets a
/// malformed model response fail closed instead of becoming user-facing prose.
enum AgentProtocol {
    static let schemaVersion = 1
}

enum RelayAction: String, Codable, Sendable {
    case execute
    case clarify
    case refuse
    case control
}

enum WorkerContextAction: String, Codable, Sendable {
    case reuse
    case compact
    case fresh
}

struct RelayRequestEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let action: RelayAction
    let workerPrompt: String?
    let userMessage: String?
    let workerContextAction: WorkerContextAction?
    let control: RelayUserControl?

    init(action: RelayAction, workerPrompt: String? = nil, userMessage: String? = nil, workerContextAction: WorkerContextAction? = nil, control: RelayUserControl? = nil) {
        schemaVersion = AgentProtocol.schemaVersion
        kind = "relay_request"
        self.action = action
        self.workerPrompt = workerPrompt
        self.userMessage = userMessage
        self.workerContextAction = workerContextAction
        self.control = control
    }

    func validate() throws {
        guard schemaVersion == AgentProtocol.schemaVersion else {
            throw AgentEnvelopeError.unsupportedSchema(schemaVersion)
        }
        guard kind == "relay_request" else { throw AgentEnvelopeError.invalidKind(kind) }
        switch action {
        case .control:
            guard let control, workerPrompt == nil else { throw AgentEnvelopeError.invalidPayload("control requires a typed control and no workerPrompt") }
            try control.validate()
        case .execute:
            guard let workerPrompt, !workerPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentEnvelopeError.invalidPayload("execute requires workerPrompt")
            }
        case .clarify, .refuse:
            guard let userMessage, !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentEnvelopeError.invalidPayload("clarify and refuse require userMessage")
            }
        }
    }
}

enum WorkerStatus: String, Codable, Sendable {
    case completed
    case needsClarification = "needs_clarification"
    case blocked
    case failed
}

struct WorkerArtifactEnvelope: Codable, Equatable, Sendable {
    let id: String
    let path: String
    let caption: String?
    let mimeType: String?
}

struct WorkerResultEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let status: WorkerStatus
    let summary: String
    let userQuestion: String?
    let artifacts: [WorkerArtifactEnvelope]

    func validate() throws {
        guard schemaVersion == AgentProtocol.schemaVersion else {
            throw AgentEnvelopeError.unsupportedSchema(schemaVersion)
        }
        guard kind == "worker_result" else { throw AgentEnvelopeError.invalidKind(kind) }
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentEnvelopeError.invalidPayload("worker result requires summary")
        }
        guard Set(artifacts.map(\.id)).count == artifacts.count,
              artifacts.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.path.hasPrefix("/") }) else {
            throw AgentEnvelopeError.invalidPayload("artifacts require unique nonempty IDs and absolute paths")
        }
        if status == .needsClarification && (userQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw AgentEnvelopeError.invalidPayload("needs_clarification requires userQuestion")
        }
    }
}

enum DeliveryStatus: String, Codable, Sendable {
    case complete
    case needsClarification = "needs_clarification"
    case failed
}

struct DeliveryAttachmentEnvelope: Codable, Equatable, Sendable {
    let artifactID: String
    let caption: String?
}

struct WorkerRecoveryEnvelope: Codable, Equatable, Sendable {
    let action: WorkerContextAction
    let reason: String

    func validate() throws {
        guard action == .compact || action == .fresh else {
            throw AgentEnvelopeError.invalidPayload("worker recovery must compact or freshen the worker")
        }
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentEnvelopeError.invalidPayload("worker recovery requires a reason")
        }
    }
}

struct DeliveryPlanEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let kind: String
    let status: DeliveryStatus
    let messages: [String]
    let attachments: [DeliveryAttachmentEnvelope]
    let recovery: WorkerRecoveryEnvelope?

    func validate() throws {
        guard schemaVersion == AgentProtocol.schemaVersion else {
            throw AgentEnvelopeError.unsupportedSchema(schemaVersion)
        }
        guard kind == "delivery_plan" else { throw AgentEnvelopeError.invalidKind(kind) }
        if let recovery {
            try recovery.validate()
        }
        guard !messages.isEmpty || !attachments.isEmpty || recovery != nil else {
            throw AgentEnvelopeError.invalidPayload("delivery plan cannot be empty")
        }
        guard messages.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(attachments.map(\.artifactID)).count == attachments.count,
              attachments.allSatisfy({ !$0.artifactID.isEmpty }) else {
            throw AgentEnvelopeError.invalidPayload("delivery requires nonempty messages and unique artifact IDs")
        }
        if status == .needsClarification && messages.isEmpty {
            throw AgentEnvelopeError.invalidPayload("needs_clarification requires a message")
        }
    }
}

enum AgentEnvelopeError: Error, CustomStringConvertible, Sendable {
    case missingObject
    case invalidKind(String)
    case unsupportedSchema(Int)
    case invalidPayload(String)

    var description: String {
        switch self {
        case .missingObject: return "no JSON object found"
        case .invalidKind(let kind): return "unexpected envelope kind: \(kind)"
        case .unsupportedSchema(let version): return "unsupported envelope schema: \(version)"
        case .invalidPayload(let message): return message
        }
    }
}

enum AgentEnvelopeParser {
    private static let decoder = JSONDecoder()

    static func relayRequest(from text: String) throws -> RelayRequestEnvelope {
        let value = try decode(RelayRequestEnvelope.self, from: text)
        try value.validate()
        return value
    }

    static func workerResult(from text: String) throws -> WorkerResultEnvelope {
        let value = try decode(WorkerResultEnvelope.self, from: text)
        try value.validate()
        return value
    }

    static func deliveryPlan(from text: String) throws -> DeliveryPlanEnvelope {
        let value = try decode(DeliveryPlanEnvelope.self, from: text)
        try value.validate()
        return value
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw AgentEnvelopeError.missingObject
        }
        return try decoder.decode(type, from: Data(text[start...end].utf8))
    }
}
