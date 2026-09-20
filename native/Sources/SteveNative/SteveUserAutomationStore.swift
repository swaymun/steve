import Foundation
import SQLite
import CryptoKit

/// This actor only persists explicit user data and claims work. It never sends
/// Messages or executes a scheduled action. Open it on the existing protected
/// Steve database after SteveStore.openDefault() has secured the path.
actor SteveUserAutomationStore {
    private let connection: Connection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL) throws {
        connection = try Connection(databaseURL.path)
        connection.busyTimeout = 5
        try connection.execute("PRAGMA foreign_keys = ON")
        try Self.migrate(connection)
    }

    static func migrate(_ connection: Connection) throws {
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS task_plans (task_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS explicit_preferences (
                key TEXT PRIMARY KEY, payload_json TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS user_schedules (
                id TEXT PRIMARY KEY, creation_request_id TEXT NOT NULL UNIQUE,
                state TEXT NOT NULL, next_run_at REAL, payload_json TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS user_schedules_due ON user_schedules(state, next_run_at);
            CREATE TABLE IF NOT EXISTS user_schedule_runs (
                id TEXT PRIMARY KEY, schedule_id TEXT NOT NULL REFERENCES user_schedules(id),
                occurrence_key TEXT NOT NULL, state TEXT NOT NULL, payload_json TEXT NOT NULL,
                UNIQUE(schedule_id, occurrence_key)
            );
            CREATE INDEX IF NOT EXISTS user_schedule_runs_pending ON user_schedule_runs(schedule_id, state);
            """)
    }

    func plans(authorization: ScheduleAuthorization) throws -> [StevePlanRecord] {
        try connection.prepare("SELECT payload_json FROM task_plans ORDER BY task_id")
            .map { try decode(StevePlanRecord.self, raw: $0[0]) }.filter { $0.authorization == authorization }
    }

    func projectMemory(workspace: String, authorization: ScheduleAuthorization) throws {
        guard URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath().path == authorization.workspace else { throw UserAutomationError.boundaryChanged }
        try SteveWorkspaceMemory.write(workspace: workspace, preferences: preferences(), plans: plans(authorization: authorization))
    }

    func savePlan(taskID: String, update: WorkerPlanUpdate, authorization: ScheduleAuthorization, provenance: ExplicitUserProvenance, timeZone: String, now: Date, expectedEpoch: String) throws {
        try update.validate(); try provenance.validate(); try authorization.validate()
        guard TimeZone(identifier: timeZone) != nil else { throw UserAutomationError.invalid("A plan requires a valid timezone.") }
        guard provenance.statement.contains(update.userQuote) else { throw UserAutomationError.invalid("Plan scope needs the original user's words.") }
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            let old = try optional(StevePlanRecord.self, sql: "SELECT payload_json FROM task_plans WHERE task_id = ?", argument: taskID)
            guard old == nil || old?.authorization == authorization else { throw UserAutomationError.boundaryChanged }
            // Late results cannot resurrect a plan the user handed back.
            if old?.update.state == .cancelled { return }
            if old?.update == update && old?.provenance.sourceID == provenance.sourceID { return }
            if let id = old?.scheduleID, var schedule = try schedule(id: id) {
                schedule.state = .cancelled; schedule.nextRunAt = nil; schedule.revision += 1
                try writeSchedule(schedule)
            }
            var value = StevePlanRecord(taskID: taskID, update: update, authorization: authorization, provenance: provenance, updatedAt: now, scheduleID: nil, lastNotification: old?.lastNotification)
            if update.state == .active, let end = WorkerPlanUpdate.date(update.endsAt), end > now {
                let rule: UserScheduleRule = .calendar(hour: 9, minute: 0, weekdays: [])
                let next = try WorkerPlanUpdate.date(update.nextCheckAt).flatMap { $0 > now ? $0 : nil } ?? rule.firstOccurrence(now: now, timeZone: timeZone)
                if next < end {
                    let policy = FollowUpPolicy(taskID: taskID, expiresAt: end, verifiedDeadline: update.deadlineVerified == true ? WorkerPlanUpdate.date(update.deadline) : nil)
                    let prompt = "Check this adopted plan using authorized read-only sources. Notify only of a verified meaningful change, deadline, blocker or needed decision; otherwise return notifyUser=false. Do not send, book, buy or change accounts. Plan: " + update.summary
                    let schedule = UserSchedule(id: UUID().uuidString, creationRequestID: "plan:" + taskID + ":" + UUID().uuidString, name: "Follow up: " + String(update.summary.prefix(120)), prompt: prompt, kind: .task, rule: rule, timeZone: timeZone, authorization: authorization, provenance: provenance, state: .active, revision: 1, nextRunAt: next, createdAt: now, updatedAt: now, followUp: policy)
                    try insertSchedule(schedule); value.scheduleID = schedule.id
                }
            }
            try connection.run("INSERT INTO task_plans(task_id, payload_json) VALUES (?, ?) ON CONFLICT(task_id) DO UPDATE SET payload_json = excluded.payload_json", taskID, try encode(value))
        }
    }

    func cancelPlan(taskID: String, provenance: ExplicitUserProvenance, now: Date, expectedEpoch: String) throws {
        try provenance.validate()
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            guard var value = try optional(StevePlanRecord.self, sql: "SELECT payload_json FROM task_plans WHERE task_id = ?", argument: taskID) else { return }
            value.update = WorkerPlanUpdate(summary: value.update.summary, state: .cancelled, userQuote: provenance.statement)
            value.provenance = provenance; value.updatedAt = now
            if let id = value.scheduleID, var schedule = try schedule(id: id) {
                schedule.state = .cancelled; schedule.nextRunAt = nil; schedule.revision += 1
                try writeSchedule(schedule)
            }
            try connection.run("UPDATE task_plans SET payload_json = ? WHERE task_id = ?", try encode(value), taskID)
        }
    }

    /// Reserve once before staging, so a crash cannot send the same finding twice.
    func reservePlanNotification(taskID: String, summary: String, expectedEpoch: String) throws -> Bool {
        var reserved = false
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            guard var plan = try optional(StevePlanRecord.self, sql: "SELECT payload_json FROM task_plans WHERE task_id = ?", argument: taskID), plan.update.state == .active else { return }
            let digest = SHA256.hash(data: Data(summary.trimmingCharacters(in: .whitespacesAndNewlines).utf8)).map { String(format: "%02x", $0) }.joined()
            guard plan.lastNotification != digest else { return }
            plan.lastNotification = digest
            try connection.run("UPDATE task_plans SET payload_json = ? WHERE task_id = ?", try encode(plan), taskID)
            reserved = true
        }
        return reserved
    }

    func preferences() throws -> [ExplicitPreference] {
        try connection.prepare("SELECT payload_json FROM explicit_preferences ORDER BY key").map { try decode(ExplicitPreference.self, raw: $0[0]) }
    }

    func preference(key: String) throws -> ExplicitPreference? {
        try optional(ExplicitPreference.self, sql: "SELECT payload_json FROM explicit_preferences WHERE key = ?", argument: try PreferenceSafety.key(key))
    }

    @discardableResult
    func savePreference(key rawKey: String, value: String, provenance: ExplicitUserProvenance, now: Date = Date(), expectedEpoch: String? = nil) throws -> ExplicitPreference {
        let key = try PreferenceSafety.key(rawKey)
        try provenance.validate()
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2000 else { throw UserAutomationError.invalid("Preference values must contain 1 to 2000 characters.") }
        try PreferenceSafety.rejectCredentials(in: value)
        var result: ExplicitPreference!
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            let existing = try preference(key: key)
            // The same authenticated user event cannot silently acquire a new meaning.
            if let existing, existing.provenance.source == provenance.source, existing.provenance.sourceID == provenance.sourceID {
                guard existing.value == value else { throw UserAutomationError.conflict }
                result = existing
                return
            }
            result = ExplicitPreference(key: key, value: value, provenance: provenance, createdAt: existing?.createdAt ?? now, updatedAt: now)
            try connection.run("INSERT INTO explicit_preferences(key, payload_json) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET payload_json = excluded.payload_json", key, try encode(result))
        }
        return result
    }

    /// Delete both value and its stored source statement. There is deliberately
    /// no history table retaining a forgotten preference or previous values.
    @discardableResult
    func forgetPreference(key: String, provenance: ExplicitUserProvenance, expectedEpoch: String? = nil) throws -> Bool {
        try provenance.validate()
        var removed = false
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            try connection.run("DELETE FROM explicit_preferences WHERE key = ?", try PreferenceSafety.key(key))
            removed = connection.changes == 1
        }
        return removed
    }

    func schedules() throws -> [UserSchedule] {
        try connection.prepare("SELECT payload_json FROM user_schedules ORDER BY COALESCE(next_run_at, 1e30), id").map { try decode(UserSchedule.self, raw: $0[0]) }
    }
    func schedule(id: String) throws -> UserSchedule? {
        try optional(UserSchedule.self, sql: "SELECT payload_json FROM user_schedules WHERE id = ?", argument: id)
    }
    func runs(scheduleID: String) throws -> [UserScheduleRun] {
        try connection.prepare("SELECT payload_json FROM user_schedule_runs WHERE schedule_id = ? ORDER BY rowid", scheduleID).map { try decode(UserScheduleRun.self, raw: $0[0]) }
    }
    func run(id: String) throws -> UserScheduleRun? {
        try optional(UserScheduleRun.self, sql: "SELECT payload_json FROM user_schedule_runs WHERE id = ?", argument: id)
    }

    @discardableResult
    func createSchedule(requestID: String, name: String, prompt: String, kind: UserScheduleKind, rule: UserScheduleRule, timeZone: String, authorization: ScheduleAuthorization, provenance: ExplicitUserProvenance, now: Date = Date(), expectedEpoch: String? = nil) throws -> UserSchedule {
        try validateScheduleInput(name: name, prompt: prompt, rule: rule, timeZone: timeZone, authorization: authorization, provenance: provenance)
        guard !requestID.isEmpty, requestID.count <= 200 else { throw UserAutomationError.invalid("A stable creation request ID is required.") }
        var result: UserSchedule!
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            if let existing = try optional(UserSchedule.self, sql: "SELECT payload_json FROM user_schedules WHERE creation_request_id = ?", argument: requestID) {
                guard existing.name == name, existing.prompt == prompt, existing.kind == kind, existing.rule == rule, existing.timeZone == timeZone,
                      existing.authorization == authorization, existing.provenance == provenance else { throw UserAutomationError.conflict }
                result = existing
                return
            }
            result = UserSchedule(id: UUID().uuidString, creationRequestID: requestID, name: name, prompt: prompt, kind: kind, rule: rule, timeZone: timeZone, authorization: authorization, provenance: provenance, state: .active, revision: 1, nextRunAt: try rule.firstOccurrence(now: now, timeZone: timeZone), createdAt: now, updatedAt: now)
            try insertSchedule(result)
        }
        return result
    }

    /// An update is a new explicit authorization. Existing run identities and
    /// outcomes are retained; an update never reruns an already claimed slot.
    @discardableResult
    func updateSchedule(id: String, name: String, prompt: String, kind: UserScheduleKind, rule: UserScheduleRule, timeZone: String, authorization: ScheduleAuthorization, provenance: ExplicitUserProvenance, now: Date = Date(), expectedEpoch: String? = nil) throws -> UserSchedule {
        try validateScheduleInput(name: name, prompt: prompt, rule: rule, timeZone: timeZone, authorization: authorization, provenance: provenance)
        var result: UserSchedule!
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            guard let existing = try schedule(id: id) else { throw UserAutomationError.notFound }
            result = UserSchedule(id: id, creationRequestID: existing.creationRequestID, name: name, prompt: prompt, kind: kind, rule: rule, timeZone: timeZone, authorization: authorization, provenance: provenance, state: .active, revision: existing.revision + 1, nextRunAt: try rule.firstOccurrence(now: now, timeZone: timeZone), createdAt: existing.createdAt, updatedAt: now)
            try writeSchedule(result)
        }
        return result
    }

    func setSchedulePaused(id: String, paused: Bool, provenance: ExplicitUserProvenance, now: Date = Date(), expectedEpoch: String? = nil) throws {
        try provenance.validate()
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            guard var value = try schedule(id: id) else { throw UserAutomationError.notFound }
            guard value.state != .blocked, value.nextRunAt != nil else { throw UserAutomationError.invalid("Update this schedule with fresh authorization before enabling it.") }
            value.state = paused ? .paused : .active
            value.lastChangeProvenance = provenance
            value.revision += 1
            value.updatedAt = now
            try writeSchedule(value)
        }
    }

    /// Cancel future occurrences without erasing the outcomes of prior runs.
    /// An already enqueued action remains owned by Gateway; stopping that action
    /// requires the ordinary runtime stop/cancellation boundary.
    func cancelSchedule(id: String, provenance: ExplicitUserProvenance, now: Date = Date(), expectedEpoch: String? = nil) throws {
        try provenance.validate()
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            guard var value = try schedule(id: id) else { throw UserAutomationError.notFound }
            if value.state == .cancelled { return }
            value.state = .cancelled; value.nextRunAt = nil; value.revision += 1
            value.updatedAt = now; value.lastChangeProvenance = provenance
            try writeSchedule(value)
        }
    }

    /// Atomic across multiple actor instances/processes. One latest missed slot
    /// is claimed per schedule, and next_run_at advances in the same transaction.
    /// Unfinished or uncertain runs block subsequent automatic runs of that schedule.
    func claimDue(now: Date, authorization: ScheduleAuthorization, dispatchEpoch: String, limit: Int = 20) throws -> [UserScheduleRun] {
        try authorization.validate()
        try UserScheduleRule.validateDate(now)
        guard !dispatchEpoch.isEmpty, (1...100).contains(limit) else { throw UserAutomationError.invalid("A live dispatch epoch and a claim limit between 1 and 100 are required.") }
        var claimed: [UserScheduleRun] = []
        try connection.transaction(.immediate) {
            let due = try connection.prepare("SELECT payload_json FROM user_schedules WHERE state = 'active' AND next_run_at <= ? ORDER BY next_run_at, id", now.timeIntervalSince1970).map { try decode(UserSchedule.self, raw: $0[0]) }
            for var schedule in due {
                guard claimed.count < limit else { break }
                guard schedule.authorization == authorization else {
                    schedule.state = .blocked
                    schedule.revision += 1
                    schedule.updatedAt = now
                    try writeSchedule(schedule)
                    continue
                }
                if let policy = schedule.followUp {
                    if now >= policy.expiresAt {
                        schedule.state = .exhausted; schedule.nextRunAt = nil; schedule.updatedAt = now
                        try writeSchedule(schedule); continue
                    }
                    if let morning = policy.deferredUntil(now: now, timeZone: schedule.timeZone) {
                        schedule.nextRunAt = morning; try writeSchedule(schedule); continue
                    }
                }
                let outstanding = try connection.scalar("SELECT COUNT(*) FROM user_schedule_runs WHERE schedule_id = ? AND state IN ('claimed', 'enqueued', 'uncertain')", schedule.id) as? Int64 ?? 0
                guard outstanding == 0, let next = schedule.nextRunAt else { continue }
                let occurrence: (due: Date, next: Date?)
                if let policy = schedule.followUp {
                    // A known check or quiet-hours deferral need not fall at 9 AM.
                    // After it, at most one fallback check on the next local day.
                    var calendar = Calendar(identifier: .gregorian)
                    calendar.timeZone = TimeZone(identifier: schedule.timeZone)!
                    let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
                    let future = try schedule.rule.firstOccurrence(now: tomorrow, timeZone: schedule.timeZone)
                    occurrence = (next, future < policy.expiresAt ? future : nil)
                } else {
                    occurrence = try schedule.rule.coalescedOccurrence(next: next, now: now, timeZone: schedule.timeZone)
                }
                let key = String(Int64((occurrence.due.timeIntervalSince1970 * 1000).rounded(.down)))
                let run = UserScheduleRun(id: UUID().uuidString, scheduleID: schedule.id, scheduleRevision: schedule.revision, scheduledAt: occurrence.due, claimedAt: now, dispatchEpoch: dispatchEpoch, authorization: authorization, kind: schedule.kind, prompt: schedule.prompt, state: .claimed, downstreamID: nil, outcomeDetail: nil, finishedAt: nil, followUp: schedule.followUp)
                try connection.run("INSERT OR IGNORE INTO user_schedule_runs(id, schedule_id, occurrence_key, state, payload_json) VALUES (?, ?, ?, 'claimed', ?)", run.id, schedule.id, key, try encode(run))
                let inserted = connection.changes == 1
                schedule.nextRunAt = occurrence.next
                if occurrence.next == nil { schedule.state = .exhausted }
                schedule.updatedAt = now
                try writeSchedule(schedule)
                if inserted { claimed.append(run) }
            }
        }
        return claimed
    }

    /// A deliberate settings or pairing change revokes old automatic authority,
    /// even when the same address/workspace is later selected again.
    func revokeScheduleAuthorization(now: Date = Date()) throws {
        try connection.transaction(.immediate) {
            for var value in try schedules() where [.active, .paused, .exhausted].contains(value.state) {
                value.state = .blocked; value.revision += 1; value.updatedAt = now
                try writeSchedule(value)
            }
        }
    }

    func validateFollowUpDelivery(id: String, authorization: ScheduleAuthorization, now: Date) throws -> Bool {
        guard let run = try run(id: id), run.authorization == authorization, run.state != .cancelled,
              let policy = run.followUp, now < policy.expiresAt,
              let schedule = try schedule(id: run.scheduleID), schedule.revision == run.scheduleRevision,
              schedule.authorization == authorization, [.active, .exhausted].contains(schedule.state) else { return false }
        return true
    }

    func validateEnqueued(id: String, authorization: ScheduleAuthorization) throws -> Bool {
        guard let run = try run(id: id), run.state == .enqueued, run.authorization == authorization,
              let value = try schedule(id: run.scheduleID), value.revision == run.scheduleRevision,
              value.authorization == authorization, [.active, .exhausted].contains(value.state) else { return false }
        return true
    }

    /// Check a claim before dispatch; Gateway checks the epoch again atomically on admission.
    func validateClaim(id: String, authorization: ScheduleAuthorization, dispatchEpoch: String) throws -> Bool {
        try authorization.validate()
        guard let run = try run(id: id), run.state == .claimed,
              run.authorization == authorization, run.dispatchEpoch == dispatchEpoch,
              let schedule = try schedule(id: run.scheduleID), schedule.revision == run.scheduleRevision,
              schedule.authorization == authorization, [.active, .exhausted].contains(schedule.state) else { return false }
        return true
    }

    /// Enqueue acknowledgment is not task/reminder success. Preserve the exact
    /// downstream identity so restart reconciliation inspects it instead of dispatching again.
    func markEnqueued(id: String, downstreamID: String) throws {
        guard !downstreamID.isEmpty else { throw UserAutomationError.invalid("A durable downstream identity is required.") }
        try connection.transaction(.immediate) {
            guard var run = try run(id: id) else { throw UserAutomationError.notFound }
            if run.state == .enqueued, run.downstreamID == downstreamID { return }
            guard run.state == .claimed else { throw UserAutomationError.conflict }
            run.state = .enqueued; run.downstreamID = downstreamID
            try writeRun(run)
        }
    }

    /// Persist the worker's verified result, but do not call the run successful
    /// until Gateway also confirms delivery through its durable inbox/outbox.
    func recordExecutionOutcome(id: String, outcome: UserScheduleRunState) throws {
        guard [.succeeded, .failed].contains(outcome) else { throw UserAutomationError.invalid("Unsupported execution outcome.") }
        try connection.transaction(.immediate) {
            guard var run = try run(id: id), run.state == .enqueued else { throw UserAutomationError.conflict }
            if let existing = run.executionOutcome, existing != outcome { throw UserAutomationError.conflict }
            run.executionOutcome = outcome
            try writeRun(run)
        }
    }

    /// Used by SteveStore inside the same transaction that inserts a synthetic
    /// inbox message. This avoids a crash gap between enqueue and its acknowledgment.
    static func claimForEnqueue(connection: Connection, id: String, authorization: ScheduleAuthorization, epoch: String) throws -> UserScheduleRun {
        let decoder = JSONDecoder()
        guard let raw = try connection.scalar("SELECT payload_json FROM user_schedule_runs WHERE id = ?", id) as? String else { throw UserAutomationError.notFound }
        let run = try decoder.decode(UserScheduleRun.self, from: Data(raw.utf8))
        guard run.state == .claimed, run.authorization == authorization, run.dispatchEpoch == epoch,
              let scheduleRaw = try connection.scalar("SELECT payload_json FROM user_schedules WHERE id = ?", run.scheduleID) as? String else { throw UserAutomationError.boundaryChanged }
        let schedule = try decoder.decode(UserSchedule.self, from: Data(scheduleRaw.utf8))
        guard schedule.revision == run.scheduleRevision, schedule.authorization == authorization,
              [.active, .exhausted].contains(schedule.state) else { throw UserAutomationError.boundaryChanged }
        return run
    }
    static func acknowledgeEnqueue(connection: Connection, run: UserScheduleRun, downstreamID: String) throws {
        var run = run
        run.state = .enqueued; run.downstreamID = downstreamID
        let raw = String(decoding: try JSONEncoder().encode(run), as: UTF8.self)
        try connection.run("UPDATE user_schedule_runs SET state = 'enqueued', payload_json = ? WHERE id = ? AND state = 'claimed'", raw, run.id)
        guard connection.changes == 1 else { throw UserAutomationError.conflict }
    }

    func recordOutcome(id: String, state: UserScheduleRunState, detail: String, now: Date = Date()) throws {
        guard state.terminal else { throw UserAutomationError.invalid("An actual terminal outcome is required.") }
        guard detail.count <= 2000 else { throw UserAutomationError.invalid("Outcome details are too long.") }
        try PreferenceSafety.rejectCredentials(in: detail)
        try connection.transaction(.immediate) {
            guard var run = try run(id: id) else { throw UserAutomationError.notFound }
            if run.state == state { return }
            guard !run.state.terminal else { throw UserAutomationError.conflict }
            if state == .succeeded, run.state != .enqueued || run.downstreamID == nil { throw UserAutomationError.invalid("Success requires a known terminal outcome from an enqueued downstream request.") }
            run.state = state; run.outcomeDetail = detail; run.finishedAt = now
            try writeRun(run)
        }
    }

    func runsNeedingReconciliation() throws -> [UserScheduleRun] {
        try connection.prepare("SELECT payload_json FROM user_schedule_runs WHERE state IN ('claimed', 'enqueued', 'uncertain') ORDER BY rowid").map { try decode(UserScheduleRun.self, raw: $0[0]) }
    }

    func recoverInterruptedClaims(now: Date = Date()) throws {
        try connection.transaction(.immediate) {
            let runs = try connection.prepare("SELECT payload_json FROM user_schedule_runs WHERE state = 'claimed'").map { try decode(UserScheduleRun.self, raw: $0[0]) }
            for var run in runs {
                run.state = .uncertain
                run.outcomeDetail = "The process stopped before dispatch acknowledgment. Inspect the downstream request; do not replay this run."
                run.finishedAt = now
                try writeRun(run)
            }
        }
    }

    func resolveUncertainRun(id: String, state: UserScheduleRunState, provenance: ExplicitUserProvenance, now: Date = Date(), expectedEpoch: String? = nil) throws {
        try provenance.validate()
        guard [.succeeded, .failed, .cancelled].contains(state) else { throw UserAutomationError.invalid("Choose a known completed, failed, or cancelled outcome.") }
        try connection.transaction(.immediate) {
            try checkEpoch(expectedEpoch)
            guard var run = try run(id: id), run.state == .uncertain else { throw UserAutomationError.conflict }
            run.state = state
            run.resolutionProvenance = provenance
            run.outcomeDetail = "Resolved by explicit user request: " + provenance.sourceID
            run.finishedAt = now
            try writeRun(run)
        }
    }

    private func checkEpoch(_ expected: String?) throws {
        guard let expected else { return }
        guard let raw = try connection.scalar("SELECT value_json FROM settings WHERE key = 'gateway_epoch'") as? String,
              try decoder.decode(String.self, from: Data(raw.utf8)) == expected else { throw UserAutomationError.boundaryChanged }
    }

    private func validateScheduleInput(name: String, prompt: String, rule: UserScheduleRule, timeZone: String, authorization: ScheduleAuthorization, provenance: ExplicitUserProvenance) throws {
        try provenance.validate(); try authorization.validate(); try rule.validate(timeZone: timeZone)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.count <= 8000 else { throw UserAutomationError.invalid("A schedule needs a short name and a concrete task or reminder.") }
        try PreferenceSafety.rejectCredentials(in: name)
        try PreferenceSafety.rejectCredentials(in: prompt)
    }
    private func insertSchedule(_ value: UserSchedule) throws {
        try connection.run("INSERT INTO user_schedules(id, creation_request_id, state, next_run_at, payload_json) VALUES (?, ?, ?, ?, ?)", value.id, value.creationRequestID, value.state.rawValue, value.nextRunAt?.timeIntervalSince1970, try encode(value))
    }
    private func writeSchedule(_ value: UserSchedule) throws {
        try connection.run("UPDATE user_schedules SET state = ?, next_run_at = ?, payload_json = ? WHERE id = ?", value.state.rawValue, value.nextRunAt?.timeIntervalSince1970, try encode(value), value.id)
    }
    private func writeRun(_ value: UserScheduleRun) throws {
        try connection.run("UPDATE user_schedule_runs SET state = ?, payload_json = ? WHERE id = ?", value.state.rawValue, try encode(value), value.id)
    }
    private func optional<T: Decodable>(_ type: T.Type, sql: String, argument: String) throws -> T? {
        guard let raw = try connection.scalar(sql, argument) else { return nil }
        return try decode(type, raw: raw)
    }
    private func encode<T: Encodable>(_ value: T) throws -> String { String(decoding: try encoder.encode(value), as: UTF8.self) }
    private func decode<T: Decodable>(_ type: T.Type, raw: Binding?) throws -> T {
        guard let raw = raw as? String else { throw UserAutomationError.invalid("Invalid stored user data.") }
        return try decoder.decode(type, from: Data(raw.utf8))
    }
}
