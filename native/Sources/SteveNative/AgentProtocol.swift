import Foundation

/// The wire contract between the relay and worker turns. Keeping this
/// Codable and versioned makes the orchestration inspectable and lets a
/// malformed model response fail closed instead of becoming user-facing prose.
enum AgentProtocol {
    static let schemaVersion = 1
    static let lastNativeCapture = "steve-capture:last"
}

enum RelayAction: String, Codable, Sendable {
    case execute
    case reply
    case cancel
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
    let taskID: String?
    let taskTitle: String?
    let mode: OperatorMode?
    var memoryUpdates: [RelayUserControl]? = nil

    init(action: RelayAction, workerPrompt: String? = nil, userMessage: String? = nil, workerContextAction: WorkerContextAction? = nil, control: RelayUserControl? = nil, taskID: String? = nil, taskTitle: String? = nil, mode: OperatorMode? = nil) {
        schemaVersion = AgentProtocol.schemaVersion
        kind = "relay_request"
        self.action = action
        self.workerPrompt = workerPrompt
        self.userMessage = userMessage
        self.workerContextAction = workerContextAction
        self.control = control
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.mode = mode
    }

    func validate() throws {
        guard schemaVersion == AgentProtocol.schemaVersion else {
            throw AgentEnvelopeError.unsupportedSchema(schemaVersion)
        }
        guard kind == "relay_request" else { throw AgentEnvelopeError.invalidKind(kind) }
        guard (memoryUpdates?.count ?? 0) <= 8 else { throw AgentEnvelopeError.invalidPayload("Too many memory updates") }
        for update in memoryUpdates ?? [] {
            guard [.preferenceSet, .preferenceForget].contains(update.operation) else { throw AgentEnvelopeError.invalidPayload("Memory updates can only set or forget preferences") }
            try update.validate()
        }
        switch action {
        case .cancel:
            guard let taskID, !taskID.isEmpty, (workerPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), control == nil else { throw AgentEnvelopeError.invalidPayload("cancel requires an existing taskID and no work or control") }
        case .control:
            guard let control, (workerPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) else { throw AgentEnvelopeError.invalidPayload("control requires a typed control and no workerPrompt") }
            try control.validate()
        case .execute:
            guard let workerPrompt, !workerPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentEnvelopeError.invalidPayload("execute requires workerPrompt")
            }
        case .reply, .clarify, .refuse:
            guard let userMessage, !userMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentEnvelopeError.invalidPayload("reply, clarify and refuse require userMessage")
            }
            guard (workerPrompt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true), control == nil else { throw AgentEnvelopeError.invalidPayload("direct replies cannot also request execution") }
        }
    }

    func validateTaskRouting() throws {
        guard action == .execute, taskID == nil else { return }
        guard mode != nil, let taskTitle, !taskTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentEnvelopeError.invalidPayload("A new task requires its execution mode and a short taskTitle")
        }
    }
}

enum WorkerStatus: String, Codable, Sendable {
    case completed
    case needsClarification = "needs_clarification"
    case blocked
    case failed
    case needsComputer = "needs_computer"
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
    var blocker: WorkerBlocker? = nil
    var plan: WorkerPlanUpdate? = nil
    var notifyUser: Bool? = nil

    enum CodingKeys: String, CodingKey { case schemaVersion, kind, status, summary, userQuestion, artifacts, blocker, plan, notifyUser }
    init(schemaVersion: Int, kind: String, status: WorkerStatus, summary: String, userQuestion: String?, artifacts: [WorkerArtifactEnvelope], blocker: WorkerBlocker? = nil, plan: WorkerPlanUpdate? = nil, notifyUser: Bool? = nil) {
        self.schemaVersion = schemaVersion; self.kind = kind; self.status = status; self.summary = summary
        self.userQuestion = userQuestion; self.artifacts = artifacts; self.blocker = blocker; self.plan = plan; self.notifyUser = notifyUser
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        kind = try values.decode(String.self, forKey: .kind)
        status = try values.decode(WorkerStatus.self, forKey: .status)
        summary = try values.decode(String.self, forKey: .summary)
        userQuestion = try values.decodeIfPresent(String.self, forKey: .userQuestion)
        artifacts = try values.decodeIfPresent([WorkerArtifactEnvelope].self, forKey: .artifacts) ?? []
        blocker = try values.decodeIfPresent(WorkerBlocker.self, forKey: .blocker)
        plan = try values.decodeIfPresent(WorkerPlanUpdate.self, forKey: .plan)
        notifyUser = try values.decodeIfPresent(Bool.self, forKey: .notifyUser)
    }

    func validate() throws {
        guard schemaVersion == AgentProtocol.schemaVersion else {
            throw AgentEnvelopeError.unsupportedSchema(schemaVersion)
        }
        guard kind == "worker_result" else { throw AgentEnvelopeError.invalidKind(kind) }
        if let blocker {
            guard status == .blocked || status == .needsClarification else { throw AgentEnvelopeError.invalidPayload("A blocker requires a waiting result") }
            try blocker.validate()
        }
        try plan?.validate()
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentEnvelopeError.invalidPayload("worker result requires summary")
        }
        guard Set(artifacts.map(\.id)).count == artifacts.count,
              artifacts.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && ($0.path.hasPrefix("/") || $0.path == AgentProtocol.lastNativeCapture) }) else {
            throw AgentEnvelopeError.invalidPayload("artifacts require unique nonempty IDs and an absolute path or the final native capture")
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

    enum CodingKeys: String, CodingKey { case schemaVersion, kind, status, messages, attachments, recovery }

    init(schemaVersion: Int, kind: String, status: DeliveryStatus, messages: [String], attachments: [DeliveryAttachmentEnvelope], recovery: WorkerRecoveryEnvelope?) {
        self.schemaVersion = schemaVersion; self.kind = kind; self.status = status
        self.messages = messages; self.attachments = attachments; self.recovery = recovery
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        kind = try values.decode(String.self, forKey: .kind)
        status = try values.decode(DeliveryStatus.self, forKey: .status)
        messages = try values.decodeIfPresent([String].self, forKey: .messages) ?? []
        attachments = try values.decodeIfPresent([DeliveryAttachmentEnvelope].self, forKey: .attachments) ?? []
        recovery = try values.decodeIfPresent(WorkerRecoveryEnvelope.self, forKey: .recovery)
    }

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
        do {
            let value = try decode(DeliveryPlanEnvelope.self, from: text)
            try value.validate()
            return value
        } catch {
            // A relay may use its intent envelope for a text-only delivery.
            // Preserve that text without admitting work, controls, or memory writes.
            guard let relay = try? relayRequest(from: text), relay.memoryUpdates?.isEmpty != false,
                  let message = relay.userMessage else { throw error }
            let status: DeliveryStatus
            switch relay.action {
            case .reply: status = .complete
            case .clarify: status = .needsClarification
            case .refuse: status = .failed
            case .execute, .control, .cancel: throw error
            }
            let value = DeliveryPlanEnvelope(schemaVersion: AgentProtocol.schemaVersion, kind: "delivery_plan", status: status, messages: [message], attachments: [], recovery: nil)
            try value.validate()
            return value
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from text: String) throws -> T {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") else {
            throw AgentEnvelopeError.missingObject
        }
        return try decoder.decode(type, from: Data(text[start...end].utf8))
    }
}
