import Foundation
import IMsgCore

struct SteveInboundMessage: Codable, Sendable, Equatable {
    let guid: String
    let chatGuid: String
    let senderHandle: String
    let text: String
    let isFromMe: Bool
    let isGroup: Bool
    let attachmentPaths: [String]
    let replyToGuid: String?
    var rowID: Int64? = nil
    var approvalID: String? = nil
}

struct MessagesAccount: Sendable, Equatable {
    let address: String
    let label: String?
}

actor MessagesService {
    enum ServiceError: Error, LocalizedError {
        case database(String)
        case noChat(String)
        case permission(String)

        var errorDescription: String? {
            switch self {
            case .database(let message), .noChat(let message): return message
            case .permission: return "Steve needs Full Disk Access to read Messages. Add Steve in System Settings → Privacy & Security → Full Disk Access, then relaunch Steve."
            }
        }
    }

    private let databasePath: String
    private var messageStore: MessageStore?
    private var watcher: MessageWatcher?
    private let sender = MessageSender()

    init(databasePath: String = MessageStore.defaultPath) {
        self.databasePath = databasePath
    }

    private func openStore() throws -> MessageStore {
        if let messageStore { return messageStore }
        do {
            let value = try MessageStore(path: databasePath)
            messageStore = value
            watcher = MessageWatcher(store: value)
            return value
        } catch {
            SteveLog.write("Messages database open failed path=\(databasePath) error=\(error.localizedDescription)")
            throw ServiceError.database(error.localizedDescription)
        }
    }

    static func normalizedAccountAddress(_ raw: String) -> String {
        var address = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("E:") || address.hasPrefix("P:") { address = String(address.dropFirst(2)) }
        return address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func discoverAccounts() throws -> [MessagesAccount] {
        // Account database rows can be historical. Prefer the signed-in iCloud identity.
        let current = discoverICloudAccount().map(Self.normalizedAccountAddress)
        let database = try openStore().localAccounts().map { MessagesAccount(address: Self.normalizedAccountAddress($0.login), label: $0.accountID) }
        var seen = Set<String>()
        let preferred = current.flatMap { $0.isEmpty ? nil : MessagesAccount(address: $0, label: "iCloud") }
        return ([preferred].compactMap { $0 } + database).filter { !$0.address.isEmpty && seen.insert($0.address.lowercased()).inserted }
    }

    func searchPairingMessage(code: String) throws -> SteveInboundMessage? {
        let command = "/pair \(code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())"
        for message in try openStore().searchMessages(query: command, match: "exact", limit: 20) {
            guard !message.isFromMe, message.text.caseInsensitiveCompare(command) == .orderedSame else { continue }
            guard let chat = try openStore().chatInfo(chatID: message.chatID), !chat.guid.isEmpty else { continue }
            let participants = try openStore().participants(chatID: message.chatID)
            let group = chat.guid.contains(";+;") || participants.count > 1
            guard !group, !message.sender.isEmpty else { continue }
            return inbound(from: message, chatGuid: chat.guid, isGroup: false, store: try openStore())
        }
        return nil
    }

    func currentRowID() throws -> Int64 { try openStore().maxRowID() }

    func watchMessages(sinceRowID: Int64?) throws -> AsyncThrowingStream<SteveInboundMessage, Error> {
        let store = try openStore()
        let watcher = self.watcher ?? MessageWatcher(store: store)
        self.watcher = watcher
        // The vendored watcher treats zero as "start now". -1 correctly resumes
        // an initially empty database without skipping its first incoming row.
        let cursor = sinceRowID == 0 ? -1 : sinceRowID
        let stream = watcher.stream(sinceRowID: cursor, configuration: MessageWatcherConfiguration(
            debounceInterval: 0.25, fallbackPollInterval: 5, batchLimit: 100,
            bufferLimit: 256, includeReactions: false
        ))
        return AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await message in stream {
                        try Task.checkCancellation()
                        guard let chat = try store.chatInfo(chatID: message.chatID), !chat.guid.isEmpty else { continue }
                        let participants = try store.participants(chatID: message.chatID)
                        continuation.yield(self.inbound(from: message, chatGuid: chat.guid, isGroup: chat.guid.contains(";+;") || participants.count > 1, store: store))
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }

    func sendText(chatGUID: String, recipient: String, text: String, replyTo: String? = nil) throws {
        try Task.checkCancellation()
        if replyTo != nil {
            SteveLog.write("Messages reply metadata unavailable in IMsgCore v0.14.2; using normal message fallback")
        }
        do {
            try sender.send(MessageSendOptions(
                recipient: recipient,
                text: text,
                service: .auto,
                chatGUID: chatGUID,
                allowSMSFallback: false
            ))
        } catch {
            // Transport errors may echo the text, including a private phone link.
            SteveLog.write("Messages text send failed")
            throw error
        }
    }

    func sendAttachment(chatGUID: String, recipient: String, path: String, caption: String, replyTo: String? = nil) throws {
        try Task.checkCancellation()
        if replyTo != nil { SteveLog.write("Attachment reply metadata unavailable; using normal message fallback") }
        do {
            try sender.send(MessageSendOptions(
                recipient: recipient,
                text: caption,
                attachmentPath: path,
                service: .auto,
                chatGUID: chatGUID,
                allowSMSFallback: false
            ))
        } catch {
            SteveLog.write("Messages attachment send failed chat=\(chatGUID) path=\(path) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func setWatcher(_ value: MessageWatcher) { watcher = value }

    private func inbound(from message: Message, chatGuid: String, isGroup: Bool, store: MessageStore) -> SteveInboundMessage {
        let attachmentPaths = (try? store.attachments(for: message.rowID))?.compactMap { attachment -> String? in
            guard !attachment.missing else { return nil }
            let path = attachment.convertedPath ?? attachment.originalPath
            return path.isEmpty ? nil : path
        } ?? []
        if !attachmentPaths.isEmpty {
            SteveLog.write("Messages inbound media discovered count=\(attachmentPaths.count)")
        }
        return SteveInboundMessage(
            guid: message.guid.isEmpty ? "rowid:\(message.rowID)" : message.guid,
            chatGuid: chatGuid,
            senderHandle: message.sender,
            text: message.text,
            isFromMe: message.isFromMe,
            isGroup: isGroup,
            attachmentPaths: attachmentPaths,
            replyToGuid: message.replyToGUID,
            rowID: message.rowID
        )
    }

    private func discoverICloudAccount() -> String? {
        // Read the native preference directly. Waiting for a defaults process
        // before draining its pipe can hang onboarding on a large account list.
        let accounts = UserDefaults(suiteName: "MobileMeAccounts")?.array(forKey: "Accounts") as? [[String: Any]] ?? []
        return accounts.compactMap { $0["AccountID"] as? String }
            .map { Self.normalizedAccountAddress($0).lowercased() }
            .first { $0.contains("@") }
    }
}
