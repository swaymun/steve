import Foundation

struct WorkerBlocker: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable { case signIn = "sign_in", connection, permission, information, unavailable, uncertain }
    let reason: Reason
    let userAction: String
    let verification: String
    var pageVerified: Bool? = nil

    func validate() throws {
        guard !userAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !verification.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              userAction.count <= 600, verification.count <= 2000 else {
            throw AgentEnvelopeError.invalidPayload("A blocker needs a short human step and verification step")
        }
        try PreferenceSafety.rejectCredentials(in: userAction)
        try PreferenceSafety.rejectCredentials(in: verification)
    }
}

/// Plan facts are context, never authorization for new external effects.
struct WorkerPlanUpdate: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable { case proposed, active, completed, cancelled }
    let summary: String
    let state: State
    let userQuote: String
    var startsAt: String? = nil
    var endsAt: String? = nil
    var nextCheckAt: String? = nil
    var deadline: String? = nil
    var deadlineVerified: Bool? = nil

    func validate() throws {
        guard !summary.isEmpty, summary.count <= 2000, !userQuote.isEmpty, userQuote.count <= 4000 else {
            throw AgentEnvelopeError.invalidPayload("A plan needs a concise summary and original user quote")
        }
        try PreferenceSafety.rejectCredentials(in: summary)
        for value in [startsAt, endsAt, nextCheckAt, deadline].compactMap({ $0 }) {
            guard Self.date(value) != nil else { throw AgentEnvelopeError.invalidPayload("Plan dates require ISO8601 with an offset") }
        }
        if let start = Self.date(startsAt), let end = Self.date(endsAt), end <= start {
            throw AgentEnvelopeError.invalidPayload("Plan end must follow its start")
        }
    }
    static func date(_ value: String?) -> Date? {
        guard let value, value.range(of: #"(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

struct TaskHandoff: Codable, Equatable, Sendable {
    let taskID: String
    let runID: String
    let blocker: WorkerBlocker
    let createdAt: Date
    var linkIssuedAt: Date? = nil
    var completedAt: Date? = nil
}

enum ConversationProgress {
    /// Progress contains no tool output, links, file paths, credentials or protocol data.
    static func safeMessage(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 180,
              !value.contains("{"), !value.contains("```"), !value.localizedCaseInsensitiveContains("http"),
              !value.contains("/Users/"), !value.contains("~/"),
              value.range(of: #"(?i)(?:[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}|[0-9a-f]{8}-[0-9a-f-]{27,}|(?:^|\s)/(?:tmp|private|var|home|Applications)/)"#, options: .regularExpression) == nil,
              !value.localizedCaseInsensitiveContains("still working"),
              value.range(of: #"(?i)^(?:i['’]m on it|on it|working on it|got it)[.!…]*$"#, options: .regularExpression) == nil,
              value.range(of: #"(?i)\b(?:mcp|worker_result|relay|operator|coordinator|worker|thread.?id|codex|gpt-|tool call|schema|skill|subagent|local server)\b"#, options: .regularExpression) == nil,
              (try? PreferenceSafety.rejectCredentials(in: value)) != nil else { return nil }
        let parts = StevePrompt.plainText(value)
        guard parts.count == 1 else { return nil }
        return parts.first
    }
}
