import Foundation

/// Construct only from the actual paired user's message or a local user action,
/// never from a model, website, tool result, or inferred behavior.
struct ExplicitUserProvenance: Codable, Equatable, Sendable {
    enum Source: String, Codable, Sendable { case pairedMessage, localCommand }
    let source: Source
    let sourceID: String
    let statement: String
    let explicitlyRequested: Bool
    let recordedAt: Date

    func validate() throws {
        guard explicitlyRequested, !sourceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              sourceID.count <= 200, !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              statement.count <= 4000 else { throw UserAutomationError.invalid("An explicit user request and its provenance are required.") }
        try PreferenceSafety.rejectCredentials(in: statement)
    }
}

enum UserAutomationError: Error, LocalizedError, Equatable {
    case invalid(String), notFound, conflict, boundaryChanged
    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        case .notFound: return "The saved preference, schedule, or run was not found."
        case .conflict: return "This operation conflicts with an existing saved request or outcome."
        case .boundaryChanged: return "The schedule's paired conversation or access boundary changed."
        }
    }
}

struct ExplicitPreference: Codable, Equatable, Sendable {
    let key: String
    let value: String
    let provenance: ExplicitUserProvenance
    let createdAt: Date
    let updatedAt: Date
}

enum PreferenceSafety {
    static func key(_ raw: String) throws -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty, key.count <= 120 else { throw UserAutomationError.invalid("Use a preference name between 1 and 120 characters.") }
        let compact = key.filter { $0.isLetter || $0.isNumber }
        let sensitive = ["password", "passcode", "apikey", "accesstoken", "refreshtoken", "secret", "credential", "cookie", "privatekey", "verificationcode", "creditcard", "cardnumber", "cvv", "otp"]
        guard !sensitive.contains(where: compact.contains), compact != "pin", compact != "token" else {
            throw UserAutomationError.invalid("Credentials and verification codes cannot be saved as preferences.")
        }
        return key
    }

    static func rejectCredentials(in text: String) throws {
        let patterns = [
            #"(?i)-----BEGIN (?:[A-Z ]+ )?PRIVATE KEY-----"#,
            #"(?i)\b(?:sk|ghp|gho|github_pat|xox[baprs])[-_][A-Za-z0-9_-]{12,}"#,
            #"(?i)\b(?:bearer|password|passcode|api[_ -]?key|access[_ -]?token|refresh[_ -]?token|secret|verification[_ -]?code|one[_ -]?time[_ -]?code|cvv|otp)\s*(?:is\s+|[=:]\s*)?\S+"#,
            #"\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#,
            #"(?i)https?://[^\s]+[?&](?:token|key|secret|code|password|signature)="#,
            #"^\s*\d{4,8}\s*$"#,
            #"^\s*(?:\d[ -]?){12,19}\s*$"#,
            #"^[A-Za-z0-9+/_=-]{32,}$"#
        ]
        guard !patterns.contains(where: { text.range(of: $0, options: .regularExpression) != nil }) else {
            throw UserAutomationError.invalid("Credentials and verification codes cannot be saved as preferences.")
        }
    }
}

/// Persistent authorization survives process restarts, but not changes to its
/// exact pairing, canonical workspace, or permission profile. A run separately
/// carries the current ephemeral Gateway epoch for validation before dispatch.
struct ScheduleAuthorization: Codable, Equatable, Sendable {
    let chatGUID: String
    let senderHandle: String
    let workspace: String
    let permission: String

    init(chatGUID: String, senderHandle: String, workspace: String, permission: String) throws {
        let sender = senderHandle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedSender = sender.contains("@") ? sender : sender.filter { $0.isNumber || $0 == "+" }
        let profile = permission.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        guard !chatGUID.isEmpty, !normalizedSender.isEmpty, workspace.hasPrefix("/"), ["read-only", "workspace-write", "danger-full-access"].contains(profile) else {
            throw UserAutomationError.invalid("A paired chat, absolute workspace, and supported permission profile are required.")
        }
        self.chatGUID = chatGUID
        self.senderHandle = normalizedSender
        self.workspace = URL(fileURLWithPath: workspace).resolvingSymlinksInPath().standardizedFileURL.path
        self.permission = profile
    }

    func validate() throws {
        guard try self == ScheduleAuthorization(chatGUID: chatGUID, senderHandle: senderHandle, workspace: workspace, permission: permission) else { throw UserAutomationError.boundaryChanged }
    }
}

enum UserScheduleKind: String, Codable, Sendable { case reminder, task }
enum UserScheduleState: String, Codable, Sendable { case active, paused, exhausted, blocked, cancelled }
enum UserScheduleRule: Codable, Equatable, Sendable {
    case once(at: Date)
    /// Fixed elapsed seconds; unlike calendar rules this does not preserve a
    /// local wall-clock time when UTC offsets change. Minimum one minute.
    case interval(seconds: Int, firstRun: Date)
    /// ISO weekdays: Monday=1 ... Sunday=7. Empty means every day.
    case calendar(hour: Int, minute: Int, weekdays: [Int])

    func validate(timeZone: String) throws {
        guard TimeZone(identifier: timeZone) != nil else { throw UserAutomationError.invalid("Choose a valid explicit time zone.") }
        switch self {
        case .once(let at): try Self.validateDate(at)
        case .interval(let seconds, let first):
            guard seconds >= 60 else { throw UserAutomationError.invalid("Recurring intervals must be at least one minute.") }
            try Self.validateDate(first)
            try Self.validateDate(first.addingTimeInterval(Double(seconds)))
        case .calendar(let hour, let minute, let days):
            guard (0...23).contains(hour), (0...59).contains(minute), Set(days).count == days.count,
                  days.allSatisfy({ (1...7).contains($0) }) else { throw UserAutomationError.invalid("Choose a valid local time and unique ISO weekdays.") }
        }
    }

    static func validateDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, Int64(exactly: (date.timeIntervalSince1970 * 1000).rounded(.down)) != nil else {
            throw UserAutomationError.invalid("The schedule date is outside the supported range.")
        }
    }

    func firstOccurrence(now: Date, timeZone: String) throws -> Date {
        try validate(timeZone: timeZone)
        try Self.validateDate(now)
        switch self {
        case .once(let at):
            guard at >= now else { throw UserAutomationError.invalid("A one-time schedule must be in the future.") }
            return at
        case .interval(let seconds, let first):
            if first >= now { return first }
            return first.addingTimeInterval(ceil(now.timeIntervalSince(first) / Double(seconds)) * Double(seconds))
        case .calendar: return try calendarOccurrence(relativeTo: now, timeZone: timeZone, forward: true)
        }
    }

    /// Return one latest due occurrence and the first future occurrence. This
    /// coalesces downtime rather than issuing a backlog of unattended actions.
    func coalescedOccurrence(next: Date, now: Date, timeZone: String) throws -> (due: Date, next: Date?) {
        try validate(timeZone: timeZone)
        try Self.validateDate(now)
        guard next <= now else { throw UserAutomationError.invalid("The schedule is not due.") }
        switch self {
        case .once: return (next, nil)
        case .interval(let seconds, _):
            let due = next.addingTimeInterval(floor(now.timeIntervalSince(next) / Double(seconds)) * Double(seconds))
            let future = due.addingTimeInterval(Double(seconds))
            try Self.validateDate(future)
            guard future > now else { throw UserAutomationError.invalid("Could not advance the interval.") }
            return (due, future)
        case .calendar:
            let due = try calendarOccurrence(relativeTo: now, timeZone: timeZone, forward: false)
            guard due >= next else { throw UserAutomationError.invalid("The persisted calendar occurrence is invalid.") }
            return (due, try calendarOccurrence(relativeTo: now, timeZone: timeZone, forward: true))
        }
    }

    private func calendarOccurrence(relativeTo reference: Date, timeZone: String, forward: Bool) throws -> Date {
        guard case .calendar(let hour, let minute, let weekdays) = self, let zone = TimeZone(identifier: timeZone) else { throw UserAutomationError.invalid("Invalid calendar rule.") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = calendar.startOfDay(for: reference)
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: forward ? offset : -offset, to: start) else { continue }
            let isoWeekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
            guard weekdays.isEmpty || weekdays.contains(isoWeekday) else { continue }
            // Spring gap: the first valid local time (02:30 -> 03:00).
            // Fall overlap: the first occurrence only, never both copies.
            guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day, matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward) else { continue }
            if forward ? candidate > reference : candidate <= reference { return candidate }
        }
        throw UserAutomationError.invalid("Could not find the next calendar occurrence.")
    }
}

struct UserSchedule: Codable, Equatable, Sendable {
    let id: String
    let creationRequestID: String
    let name: String
    let prompt: String
    let kind: UserScheduleKind
    let rule: UserScheduleRule
    let timeZone: String
    let authorization: ScheduleAuthorization
    let provenance: ExplicitUserProvenance
    var state: UserScheduleState
    var revision: Int
    var nextRunAt: Date?
    let createdAt: Date
    var updatedAt: Date
    var lastChangeProvenance: ExplicitUserProvenance? = nil
    var followUp: FollowUpPolicy? = nil
}

enum UserScheduleRunState: String, Codable, Sendable {
    case claimed, enqueued, succeeded, failed, uncertain, cancelled
    var terminal: Bool { [.succeeded, .failed, .uncertain, .cancelled].contains(self) }
}
struct UserScheduleRun: Codable, Equatable, Sendable {
    let id: String
    let scheduleID: String
    let scheduleRevision: Int
    let scheduledAt: Date
    let claimedAt: Date
    let dispatchEpoch: String
    let authorization: ScheduleAuthorization
    let kind: UserScheduleKind
    let prompt: String
    var state: UserScheduleRunState
    var downstreamID: String?
    var outcomeDetail: String?
    var finishedAt: Date?
    var executionOutcome: UserScheduleRunState? = nil
    var resolutionProvenance: ExplicitUserProvenance? = nil
    var followUp: FollowUpPolicy? = nil
}
