import Foundation
import SQLite

/// Swift-owned persistence for the existing Steve database. The schema is kept
/// intentionally boring: the Rust implementation and this actor use the same
/// tables and JSON settings keys so an installed migration is lossless.
actor SteveStore {
    struct AgentSession: Codable, Equatable, Sendable {
        let chatGuid: String
        let threadID: String
        let relayThreadID: String?
        let relayPromptVersion: String?
        let workspacePath: String
        let permissionProfile: String
        let model: String
        let effort: String
        let lastMessageGuid: String?
        let executionState: String
        let updatedAt: Date

        init(
            chatGuid: String,
            threadID: String,
            relayThreadID: String? = nil,
            relayPromptVersion: String? = nil,
            workspacePath: String,
            permissionProfile: String,
            model: String,
            effort: String,
            lastMessageGuid: String?,
            executionState: String,
            updatedAt: Date
        ) {
            self.chatGuid = chatGuid
            self.threadID = threadID
            self.relayThreadID = relayThreadID
            self.relayPromptVersion = relayPromptVersion
            self.workspacePath = workspacePath
            self.permissionProfile = permissionProfile
            self.model = model
            self.effort = effort
            self.lastMessageGuid = lastMessageGuid
            self.executionState = executionState
            self.updatedAt = updatedAt
        }
    }

    nonisolated let databaseURL: URL
    private let connection: Connection
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    init(databaseURL: URL) throws {
        self.databaseURL = databaseURL
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        connection = try Connection(databaseURL.path)
        // Automation uses another connection to this WAL database. Wait for
        // its brief write transactions instead of losing intake or delivery.
        connection.busyTimeout = 5
        try Self.migrate(connection)
    }

    static func openDefault() throws -> SteveStore {
        let directory = StevePaths.dataDirectory
        let manager = FileManager.default
        func protect(_ url: URL, directory: Bool) throws {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            let expected: FileAttributeType = directory ? .typeDirectory : .typeRegular
            guard attributes[.type] as? FileAttributeType == expected,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw RPCError(message: "Steve's data path must be owned by the current user and cannot be a symbolic link.")
            }
            try manager.setAttributes([.posixPermissions: directory ? 0o700 : 0o600], ofItemAtPath: url.path)
        }
        if (try? manager.attributesOfItem(atPath: directory.path)) == nil {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try protect(directory, directory: true)
        let database = directory.appendingPathComponent("steve.sqlite3")
        for path in [database.path, database.path + "-wal", database.path + "-shm"] where (try? manager.attributesOfItem(atPath: path)) != nil {
            try protect(URL(fileURLWithPath: path), directory: false)
        }
        let store = try SteveStore(databaseURL: database)
        for path in [database.path, database.path + "-wal", database.path + "-shm"] where (try? manager.attributesOfItem(atPath: path)) != nil {
            try protect(URL(fileURLWithPath: path), directory: false)
        }
        return store
    }

    private static func migrate(_ connection: Connection) throws {
        try connection.execute("PRAGMA journal_mode = WAL")
        try connection.execute("PRAGMA foreign_keys = ON")
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS settings (
              key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS trusted_conversations (
              id TEXT PRIMARY KEY, chat_guid TEXT NOT NULL UNIQUE, sender_handle TEXT NOT NULL,
              payload_json TEXT NOT NULL, created_at TEXT NOT NULL, revoked_at TEXT
            );
            CREATE TABLE IF NOT EXISTS queue (
              id TEXT PRIMARY KEY, direction TEXT NOT NULL, state TEXT NOT NULL,
              payload_json TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS queue_state_created ON queue(direction, state, created_at);
            CREATE TABLE IF NOT EXISTS dedupe (identity TEXT PRIMARY KEY, first_seen_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS schedules (
              id TEXT PRIMARY KEY, thread_id TEXT NOT NULL, payload_json TEXT NOT NULL,
              next_run_at TEXT, updated_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS audit_log (
              id INTEGER PRIMARY KEY AUTOINCREMENT, event TEXT NOT NULL,
              detail_json TEXT NOT NULL, occurred_at TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS catalog_cache (
              key TEXT PRIMARY KEY, codex_version TEXT NOT NULL, account_key TEXT NOT NULL,
              workspace_root TEXT, value_json TEXT NOT NULL, updated_at_ms INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS agent_sessions (
              chat_guid TEXT PRIMARY KEY, thread_id TEXT NOT NULL, relay_thread_id TEXT,
              relay_prompt_version TEXT,
              workspace_path TEXT NOT NULL,
              permission_profile TEXT NOT NULL, model TEXT NOT NULL, effort TEXT NOT NULL,
              last_message_guid TEXT, execution_state TEXT NOT NULL, updated_at TEXT NOT NULL
            );
            INSERT INTO metadata(key, value) VALUES ('schema_version', '1')
              ON CONFLICT(key) DO UPDATE SET value = excluded.value;
            """)

        let columns = try connection.prepare("PRAGMA table_info(agent_sessions)").compactMap { row in
            row[1] as? String
        }
        if !columns.contains("relay_thread_id") {
            try connection.execute("ALTER TABLE agent_sessions ADD COLUMN relay_thread_id TEXT")
        }
        if !columns.contains("relay_prompt_version") {
            try connection.execute("ALTER TABLE agent_sessions ADD COLUMN relay_prompt_version TEXT")
        }
    }

    func getSettings() throws -> Settings? { try getJSON(Settings.self, key: "settings") }

    func saveSettings(_ settings: Settings) throws {
        try putJSON(settings, key: "settings")
    }

    func trustedConversation() throws -> TrustedConversation? {
        try getJSON(TrustedConversation.self, key: "trusted_conversation")
    }

    func pairingChallenge() throws -> PairingChallenge? {
        try getJSON(PairingChallenge.self, key: "pairing_challenge")
    }

    func savePairingChallenge(_ value: PairingChallenge?) throws {
        if let value { try putJSON(value, key: "pairing_challenge") }
        else { try connection.run("DELETE FROM settings WHERE key = ?", "pairing_challenge") }
    }

    func saveTrustedConversation(_ value: TrustedConversation?) throws {
        if let value { try putJSON(value, key: "trusted_conversation") }
        else { try connection.run("DELETE FROM settings WHERE key = ?", "trusted_conversation") }
    }

    func rememberIdentity(_ identity: String) throws -> Bool {
        try connection.run(
            "INSERT OR IGNORE INTO dedupe(identity, first_seen_at) VALUES (?, ?)",
            identity,
            Self.dateFormatter.string(from: Date())
        )
        return connection.changes == 1
    }

    func agentSession(for chatGuid: String) throws -> AgentSession? {
        let statement = try connection.prepare("""
            SELECT chat_guid, thread_id, relay_thread_id, relay_prompt_version, workspace_path,
                   permission_profile, model, effort, last_message_guid, execution_state, updated_at
            FROM agent_sessions WHERE chat_guid = ?
            """, chatGuid)
        guard let row = statement.makeIterator().next() else { return nil }
        guard let updated = row[10] as? String,
              let date = Self.dateFormatter.date(from: updated) ?? ISO8601DateFormatter().date(from: updated)
        else { return nil }
        return AgentSession(
            chatGuid: row[0] as? String ?? chatGuid,
            threadID: row[1] as? String ?? "",
            relayThreadID: row[2] as? String,
            relayPromptVersion: row[3] as? String,
            workspacePath: row[4] as? String ?? "",
            permissionProfile: row[5] as? String ?? "",
            model: row[6] as? String ?? "",
            effort: row[7] as? String ?? "",
            lastMessageGuid: row[8] as? String,
            executionState: row[9] as? String ?? "idle",
            updatedAt: date
        )
    }

    func saveAgentSession(_ session: AgentSession, expectedEpoch: String? = nil) throws {
        if let expectedEpoch, try gatewayEpoch() != expectedEpoch { throw CancellationError() }
        try connection.run("""
            INSERT INTO agent_sessions
              (chat_guid, thread_id, relay_thread_id, relay_prompt_version, workspace_path,
               permission_profile, model, effort, last_message_guid, execution_state, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(chat_guid) DO UPDATE SET
              thread_id = excluded.thread_id, relay_thread_id = excluded.relay_thread_id,
              relay_prompt_version = excluded.relay_prompt_version,
              workspace_path = excluded.workspace_path,
              permission_profile = excluded.permission_profile, model = excluded.model,
              effort = excluded.effort, last_message_guid = excluded.last_message_guid,
              execution_state = excluded.execution_state, updated_at = excluded.updated_at
            """,
            session.chatGuid, session.threadID, session.relayThreadID, session.relayPromptVersion,
            session.workspacePath, session.permissionProfile, session.model, session.effort, session.lastMessageGuid,
            session.executionState,
            Self.dateFormatter.string(from: session.updatedAt)
        )
    }

    func finishAgentSession(chatGuid: String, messageGuid: String, state: String, expectedEpoch: String) throws {
        guard try gatewayEpoch() == expectedEpoch else { throw CancellationError() }
        try connection.run("UPDATE agent_sessions SET execution_state = ?, updated_at = ? WHERE chat_guid = ? AND last_message_guid = ? AND execution_state = 'running'",
                           state, Self.dateFormatter.string(from: Date()), chatGuid, messageGuid)
    }

    func deleteAgentSession(for chatGuid: String) throws {
        try connection.run("DELETE FROM agent_sessions WHERE chat_guid = ?", chatGuid)
    }

    struct OutboundPart: Codable, Sendable, Equatable {
        let id: String
        let chatGuid: String
        let recipient: String
        let replyTo: String
        let inboxGUIDs: [String]
        let text: String
        let attachmentPath: String?
        let workspace: String?
        let permission: String?
        var isControl: Bool = false
    }

    func phoneAccessOrigin() throws -> String? { try getJSON(String.self, key: "phone_access_origin") }
    func savePhoneAccessOrigin(_ value: String?) throws {
        if let value { try putJSON(value, key: "phone_access_origin") }
        else { try connection.run("DELETE FROM settings WHERE key = 'phone_access_origin'") }
    }
    func phoneAccessPort() throws -> Int? { try getJSON(Int.self, key: "phone_access_port") }
    func savePhoneAccessPort(_ value: Int?) throws {
        if let value {
            guard (1...65535).contains(value) else { throw RPCError(message: "Phone access port must be between 1 and 65535.") }
            try putJSON(value, key: "phone_access_port")
        } else { try connection.run("DELETE FROM settings WHERE key = 'phone_access_port'") }
    }

    func gatewayEpoch() throws -> String? { try getJSON(String.self, key: "gateway_epoch") }
    func saveGatewayEpoch(_ value: String) throws { try putJSON(value, key: "gateway_epoch") }

    func paused() throws -> Bool { try getJSON(Bool.self, key: "gateway_paused") ?? false }
    func savePaused(_ value: Bool) throws { try putJSON(value, key: "gateway_paused") }

    func messageCursor() throws -> Int64? {
        guard let raw = try connection.scalar("SELECT value FROM metadata WHERE key = 'messages_cursor'") as? String else { return nil }
        return Int64(raw)
    }

    func checkpoint(_ rowID: Int64?) throws {
        guard let rowID else { return }
        let current = try messageCursor() ?? -1
        guard rowID > current else { return }
        try connection.run("INSERT INTO metadata(key, value) VALUES ('messages_cursor', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value", String(rowID))
    }

    /// Commit the payload and its identity before advancing the source cursor.
    func acceptInbound(_ message: SteveInboundMessage) throws -> Bool {
        var inserted = false
        try connection.transaction {
            inserted = try rememberIdentity(message.guid)
            if inserted { try insertQueue(id: "inbound:" + message.guid, direction: "inbound", payload: message) }
            try checkpoint(message.rowID)
        }
        return inserted
    }

    func acceptScheduledRun(id: String, expectedEpoch: String) throws -> Bool {
        var inserted = false
        try connection.transaction(.immediate) {
            guard try gatewayEpoch() == expectedEpoch, try !paused(),
                  let trusted = try trustedConversation(), let settings = try getSettings(),
                  let workspace = settings.workspaceRoot, let permission = settings.permissionProfile else { throw UserAutomationError.boundaryChanged }
            let authorization = try ScheduleAuthorization(chatGUID: trusted.chatGuid, senderHandle: trusted.senderHandle, workspace: workspace, permission: permission)
            let run = try SteveUserAutomationStore.claimForEnqueue(connection: connection, id: id, authorization: authorization, epoch: expectedEpoch)
            let guid = "schedule:" + run.id
            let message = SteveInboundMessage(guid: guid, chatGuid: authorization.chatGUID, senderHandle: authorization.senderHandle, text: run.prompt, isFromMe: false, isGroup: false, attachmentPaths: [], replyToGuid: nil)
            inserted = try rememberIdentity(guid)
            if inserted { try insertQueue(id: "inbound:" + guid, direction: "inbound", payload: message) }
            try SteveUserAutomationStore.acknowledgeEnqueue(connection: connection, run: run, downstreamID: guid)
        }
        return inserted
    }

    func pendingInbox() throws -> [SteveInboundMessage] {
        try queuePayloads(SteveInboundMessage.self, direction: "inbound", state: "pending")
    }

    func claimInbox(_ guids: [String]) throws -> Bool {
        var claimed = true
        try connection.transaction {
            for guid in guids {
                try connection.run("UPDATE queue SET state = 'running', updated_at = ? WHERE id = ? AND state = 'pending'", Self.dateFormatter.string(from: Date()), "inbound:" + guid)
                if connection.changes != 1 { claimed = false }
            }
            if !claimed { throw RPCError(message: "Inbound request is no longer pending") }
        }
        return claimed
    }

    func finishInbox(_ guids: [String], state: String) throws {
        for guid in guids {
            try connection.run("UPDATE queue SET state = ?, updated_at = ? WHERE id = ? AND state IN ('running', 'awaiting_delivery', 'interrupted')", state, Self.dateFormatter.string(from: Date()), "inbound:" + guid)
        }
    }

    func stageDelivery(_ parts: [OutboundPart], inboxGUIDs: [String], expectedEpoch: String? = nil) throws {
        try connection.transaction(.immediate) {
            if let expectedEpoch, try gatewayEpoch() != expectedEpoch { throw CancellationError() }
            for part in parts { try insertQueue(id: part.id, direction: "outbound", payload: part) }
            try finishInbox(inboxGUIDs, state: parts.isEmpty ? "completed" : "awaiting_delivery")
        }
    }

    func pendingOutbox() throws -> [OutboundPart] {
        let values = try queuePayloads(OutboundPart.self, direction: "outbound", state: "pending")
        let uncertain = try queuePayloads(OutboundPart.self, direction: "outbound", state: "uncertain")
        let blocked = Set(uncertain.flatMap(\.inboxGUIDs))
        return values.filter { blocked.isDisjoint(with: $0.inboxGUIDs) }
    }

    func beginSending(_ id: String) throws -> Bool {
        try connection.run("UPDATE queue SET state = 'sending', updated_at = ? WHERE id = ? AND state = 'pending'", Self.dateFormatter.string(from: Date()), id)
        return connection.changes == 1
    }

    func finishSending(_ part: OutboundPart, sent: Bool) throws {
        try connection.transaction {
            // Once the transport was invoked, failure is ambiguous, never an automatic retry.
            try connection.run("UPDATE queue SET state = ?, updated_at = ? WHERE id = ? AND state IN ('sending', 'uncertain')", sent ? "sent" : "uncertain", Self.dateFormatter.string(from: Date()), part.id)
            guard sent else { try finishInbox(part.inboxGUIDs, state: "uncertain"); return }
            let unfinished = try connection.prepare("SELECT payload_json FROM queue WHERE direction = 'outbound' AND state != 'sent'").compactMap { row -> OutboundPart? in
                guard let raw = row[0] as? String else { return nil }
                return try decoder.decode(OutboundPart.self, from: Data(raw.utf8))
            }
            if !unfinished.contains(where: { !Set($0.inboxGUIDs).isDisjoint(with: part.inboxGUIDs) }) {
                try finishInbox(part.inboxGUIDs, state: "completed")
            }
        }
    }

    func recoverInterruptedWork() throws {
        try connection.transaction {
            try connection.run("UPDATE queue SET state = 'uncertain' WHERE direction = 'inbound' AND state = 'running'")
            try connection.run("UPDATE queue SET state = 'uncertain' WHERE direction = 'outbound' AND state = 'sending'")
            for part in try queuePayloads(OutboundPart.self, direction: "outbound", state: "uncertain") {
                try finishInbox(part.inboxGUIDs, state: "uncertain")
            }
            try connection.run("UPDATE agent_sessions SET execution_state = 'interrupted' WHERE execution_state = 'running'")
        }
    }

    func invalidateWork(cancelQueued: Bool, epoch: String) throws {
        try connection.transaction {
            try saveGatewayEpoch(epoch)
            try connection.run("UPDATE queue SET state = 'interrupted' WHERE direction = 'inbound' AND state = 'running'")
            if cancelQueued {
                try connection.run("UPDATE queue SET state = 'cancelled' WHERE direction = 'inbound' AND state IN ('pending', 'awaiting_delivery')")
                try connection.run("UPDATE queue SET state = 'cancelled' WHERE direction = 'outbound' AND state = 'pending'")
            }
            try connection.run("UPDATE queue SET state = 'uncertain' WHERE direction = 'outbound' AND state = 'sending'")
            for part in try queuePayloads(OutboundPart.self, direction: "outbound", state: "uncertain") {
                try finishInbox(part.inboxGUIDs, state: "uncertain")
            }
            try connection.run("UPDATE agent_sessions SET execution_state = 'interrupted' WHERE execution_state = 'running'")
        }
    }

    func failOutboundPart(_ part: OutboundPart) throws {
        try connection.transaction(.immediate) {
            let pending = try queuePayloads(OutboundPart.self, direction: "outbound", state: "pending")
            for value in pending where value.id == part.id || !Set(value.inboxGUIDs).isDisjoint(with: part.inboxGUIDs) {
                try connection.run("UPDATE queue SET state = 'failed' WHERE id = ? AND state = 'pending'", value.id)
            }
            try finishInbox(part.inboxGUIDs, state: "failed")
        }
    }

    func workCounts(excludingGUID: String = "") throws -> (pending: Int, running: Int, uncertain: Int, failed: Int) {
        func count(_ state: String) throws -> Int {
            Int(try connection.scalar("SELECT COUNT(*) FROM queue WHERE direction = 'inbound' AND state = ? AND id != ?", state, "inbound:" + excludingGUID) as? Int64 ?? 0)
        }
        return (try count("pending"), try count("running"), try uncertainWorkCount(), try count("failed"))
    }

    func uncertainWorkCount() throws -> Int {
        Int(try connection.scalar("SELECT COUNT(*) FROM queue WHERE state = 'uncertain'") as? Int64 ?? 0)
    }

    func queueState(_ id: String) throws -> String? {
        try connection.scalar("SELECT state FROM queue WHERE id = ?", id) as? String
    }

    private func insertQueue<T: Encodable>(id: String, direction: String, payload: T) throws {
        let raw = String(decoding: try encoder.encode(payload), as: UTF8.self)
        let now = Self.dateFormatter.string(from: Date())
        try connection.run("INSERT INTO queue(id, direction, state, payload_json, created_at, updated_at) VALUES (?, ?, 'pending', ?, ?, ?)", id, direction, raw, now, now)
    }

    private func queuePayloads<T: Decodable>(_ type: T.Type, direction: String, state: String) throws -> [T] {
        try connection.prepare("SELECT payload_json FROM queue WHERE direction = ? AND state = ? ORDER BY created_at, rowid", direction, state).map { row in
            guard let raw = row[0] as? String else { throw RPCError(message: "Invalid persisted queue entry") }
            return try decoder.decode(type, from: Data(raw.utf8))
        }
    }

    private func getJSON<T: Decodable>(_ type: T.Type, key: String) throws -> T? {
        guard let raw = try connection.scalar("SELECT value_json FROM settings WHERE key = ?", key) as? String else {
            return nil
        }
        return try decoder.decode(type, from: Data(raw.utf8))
    }

    private func putJSON<T: Encodable>(_ value: T, key: String) throws {
        let raw = String(decoding: try encoder.encode(value), as: UTF8.self)
        try connection.run("""
            INSERT INTO settings(key, value_json, updated_at) VALUES (?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET value_json = excluded.value_json,
                                           updated_at = excluded.updated_at
            """,
            key, raw, Self.dateFormatter.string(from: Date())
        )
    }
}

enum StevePaths {
    static var dataDirectory: URL {
        let fileManager = FileManager.default
        let current = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".steve", isDirectory: true)
        let legacy = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.swaymun.steve", isDirectory: true)
        if !fileManager.fileExists(atPath: current.path), fileManager.fileExists(atPath: legacy.path) {
            do {
                try fileManager.moveItem(at: legacy, to: current)
                SteveLog.write("Migrated data directory to \(current.path)")
            } catch {
                SteveLog.write("Data directory migration failed error=\(error.localizedDescription)")
            }
        }
        return current
    }

    static var workspaceDirectory: URL {
        dataDirectory.appendingPathComponent("workspace", isDirectory: true)
    }
}
