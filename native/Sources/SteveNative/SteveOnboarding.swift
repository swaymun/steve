import Foundation

/// Local authorization for one owner. The first fresh direct message binds the
/// exact chat; an address alone never authorizes other chats or group messages.
struct SteveOwnerSetup: Codable, Equatable, Sendable {
    let id: String
    let address: String
    let receiveAddress: String
    let afterRowID: Int64
    let configuredAt: Date

    func accepts(_ message: SteveInboundMessage) -> Bool {
        !message.isFromMe && !message.isGroup && !message.chatGuid.isEmpty
            && message.service?.caseInsensitiveCompare("iMessage") == .orderedSame
            && normalizeHandle(message.senderHandle) == address
            && (message.rowID ?? -1) > afterRowID
            && message.sentAt.map { $0 >= configuredAt } == true
    }
}

enum SteveOnboarding {
    static func ownerAddress(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil {
            return value.lowercased()
        }
        let phone = value.filter { !" ()-".contains($0) }
        if phone.range(of: #"^\+[1-9][0-9]{7,14}$"#, options: .regularExpression) != nil { return phone }
        throw RPCError(message: "Enter the owner's iMessage email or phone number with country code, such as +15551234567.")
    }

    static func identity(name: String, personality: String) throws -> (name: String, personality: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let personality = personality.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RPCError(message: "Choose an agent name between 1 and 40 characters on one line.")
        }
        guard personality.count <= 600, !personality.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.newlines).contains($0) }) else {
            throw RPCError(message: "Keep the personality description under 600 characters.")
        }
        return (name, personality)
    }
}
