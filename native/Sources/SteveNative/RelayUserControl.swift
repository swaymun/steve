import Foundation

enum RelayUserControlOperation: String, Codable, Sendable {
    case phoneAccess = "phone_access"
    case preferenceList = "preference_list", preferenceSet = "preference_set", preferenceForget = "preference_forget"
    case scheduleCreate = "schedule_create", scheduleList = "schedule_list", schedulePause = "schedule_pause"
    case scheduleResume = "schedule_resume", scheduleCancel = "schedule_cancel", scheduleResolve = "schedule_resolve"
}

struct RelayScheduleDefinition: Codable, Equatable, Sendable {
    enum Timing: String, Codable, Sendable { case once, interval, calendar }
    let name: String
    let prompt: String
    let kind: UserScheduleKind
    let timing: Timing
    let timeZone: String
    let at: String?
    let intervalSeconds: Int?
    let hour: Int?
    let minute: Int?
    let weekdays: [Int]?

    func rule(now: Date) throws -> UserScheduleRule {
        let rule: UserScheduleRule
        switch timing {
        case .once:
            guard let at, let date = Self.date(at) else { throw UserAutomationError.invalid("A one-time schedule requires an ISO 8601 date with an explicit UTC offset.") }
            rule = .once(at: date)
        case .interval:
            guard let seconds = intervalSeconds else { throw UserAutomationError.invalid("An interval in seconds is required.") }
            let first: Date
            if let at {
                guard let date = Self.date(at) else { throw UserAutomationError.invalid("The first occurrence must include an explicit UTC offset.") }
                first = date
            } else { first = now.addingTimeInterval(Double(seconds)) }
            rule = .interval(seconds: seconds, firstRun: first)
        case .calendar:
            guard let hour, let minute else { throw UserAutomationError.invalid("A local hour and minute are required.") }
            rule = .calendar(hour: hour, minute: minute, weekdays: weekdays ?? [])
        }
        try rule.validate(timeZone: timeZone)
        return rule
    }
    private static func date(_ value: String) -> Date? {
        guard value.range(of: #"(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

struct RelayUserControl: Codable, Equatable, Sendable {
    let operation: RelayUserControlOperation
    /// Exact words from the current human request, not a source/provenance supplied by a tool.
    let userQuote: String
    let key: String?
    let value: String?
    let scheduleID: String?
    let runID: String?
    let resolution: UserScheduleRunState?
    let schedule: RelayScheduleDefinition?

    func validate() throws {
        guard !userQuote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, userQuote.count <= 4000 else {
            throw AgentEnvelopeError.invalidPayload("control requires the exact current user's request in userQuote")
        }
        switch operation {
        case .preferenceSet:
            guard let key, let value, !key.isEmpty, !value.isEmpty else { throw AgentEnvelopeError.invalidPayload("preference_set requires key and value") }
        case .preferenceForget:
            guard let key, !key.isEmpty else { throw AgentEnvelopeError.invalidPayload("preference_forget requires key") }
        case .scheduleCreate:
            guard schedule != nil else { throw AgentEnvelopeError.invalidPayload("schedule_create requires schedule") }
        case .schedulePause, .scheduleResume, .scheduleCancel:
            guard let scheduleID, !scheduleID.isEmpty else { throw AgentEnvelopeError.invalidPayload("schedule control requires scheduleID") }
        case .scheduleResolve:
            guard let runID, !runID.isEmpty, let resolution, [.succeeded, .failed, .cancelled].contains(resolution) else { throw AgentEnvelopeError.invalidPayload("schedule_resolve requires runID and a known outcome") }
        case .preferenceList, .scheduleList, .phoneAccess: break
        }
    }
}

/// Executes only typed controls from the intent phase. Provenance is derived
/// from the current authenticated inbox, never accepted from the relay JSON.
enum UserControlExecutor {
    static func perform(_ control: RelayUserControl, inbound: [SteveInboundMessage], store: SteveUserAutomationStore, authorization: ScheduleAuthorization, epoch: String, now: Date) async throws -> String {
        try control.validate()
        guard let source = inbound.first(where: { !$0.guid.hasPrefix("schedule:") && $0.text.contains(control.userQuote) }) else {
            throw UserAutomationError.invalid("The control must quote an explicit request in the current human message. Scheduled tasks cannot change preferences or schedules.")
        }
        let provenance = ExplicitUserProvenance(source: .pairedMessage, sourceID: source.guid, statement: source.text, explicitlyRequested: true, recordedAt: now)
        switch control.operation {
        case .phoneAccess:
            throw UserAutomationError.invalid("Phone access is handled by the trusted runtime.")
        case .preferenceList:
            let preferences = try await store.preferences()
            return preferences.isEmpty ? "You have no saved preferences." : "Saved preferences: " + preferences.map { "\($0.key): \($0.value)" }.joined(separator: "; ")
        case .preferenceSet:
            let result = try await store.savePreference(key: control.key!, value: control.value!, provenance: provenance, now: now, expectedEpoch: epoch)
            return "Saved your preference: \(result.key): \(result.value)"
        case .preferenceForget:
            let removed = try await store.forgetPreference(key: control.key!, provenance: provenance, expectedEpoch: epoch)
            return removed ? "Forgot that preference." : "That preference was not saved."
        case .scheduleList:
            let schedules = try await store.schedules()
            guard !schedules.isEmpty else { return "You have no saved schedules." }
            var descriptions: [String] = []
            for schedule in schedules {
                let runs = try await store.runs(scheduleID: schedule.id)
                let unresolved = runs.filter { [.claimed, .enqueued, .uncertain].contains($0.state) }
                var description = "\(schedule.name) (\(schedule.id)): \(schedule.kind.rawValue), \(schedule.state.rawValue), \(schedule.timeZone)"
                if let next = schedule.nextRunAt { description += ", next " + ISO8601DateFormatter().string(from: next) }
                if !unresolved.isEmpty { description += "; runs " + unresolved.map { "\($0.id): \($0.state.rawValue)" }.joined(separator: ", ") }
                descriptions.append(description)
            }
            return descriptions.joined(separator: ". ")
        case .scheduleCreate:
            let definition = control.schedule!
            let created = try await store.createSchedule(requestID: source.guid + ":schedule", name: definition.name, prompt: definition.prompt, kind: definition.kind, rule: try definition.rule(now: now), timeZone: definition.timeZone, authorization: authorization, provenance: provenance, now: now, expectedEpoch: epoch)
            let next = created.nextRunAt.map { ISO8601DateFormatter().string(from: $0) } ?? "none"
            return "Scheduled \(created.name) as a \(created.kind.rawValue). Next occurrence: \(next) (\(created.timeZone))."
        case .schedulePause, .scheduleResume:
            try await store.setSchedulePaused(id: control.scheduleID!, paused: control.operation == .schedulePause, provenance: provenance, now: now, expectedEpoch: epoch)
            return control.operation == .schedulePause ? "Paused that schedule. An already running task is separate; /stop pauses Steve." : "Resumed that schedule. Missed occurrences will coalesce into at most one run."
        case .scheduleCancel:
            try await store.cancelSchedule(id: control.scheduleID!, provenance: provenance, now: now, expectedEpoch: epoch)
            return "Cancelled future occurrences of that schedule. An already running task is separate; /stop pauses Steve."
        case .scheduleResolve:
            try await store.resolveUncertainRun(id: control.runID!, state: control.resolution!, provenance: provenance, now: now, expectedEpoch: epoch)
            return "Recorded the outcome you supplied. That occurrence will not be replayed."
        }
    }
}
