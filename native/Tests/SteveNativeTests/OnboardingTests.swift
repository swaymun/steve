import XCTest
@testable import SteveNative

final class OnboardingTests: XCTestCase {
    func testOwnerAddressRequiresExactEmailOrInternationalPhone() throws {
        XCTAssertEqual(try SteveOnboarding.ownerAddress(" Owner+agent@Example.com "), "owner+agent@example.com")
        XCTAssertEqual(try SteveOnboarding.ownerAddress("+1 (555) 123-4567"), "+15551234567")
        for value in ["", "Sam", "5551234567", "owner@example.com,other@example.com", "owner@example.com\nother@example.com", "+１２３４５６７８９", "*"] {
            XCTAssertThrowsError(try SteveOnboarding.ownerAddress(value))
        }
    }

    func testOwnerBindingRequiresFreshDirectMessageAndCannotChangeChats() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SteveStore(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        let now = Date()
        let owner = SteveOwnerSetup(id: "owner", address: "owner@example.com", receiveAddress: "agent@example.com", afterRowID: 40, configuredAt: now)
        try await store.saveOwnerSetup(owner)
        let cursor = try await store.messageCursor()
        XCTAssertEqual(cursor, 40, "A watcher starting later must not skip the first new message")
        func message(sender: String = "owner@example.com", chat: String = "private", group: Bool = false, fromMe: Bool = false, row: Int64? = 41, sent: Date? = now, service: String? = "iMessage") -> SteveInboundMessage {
            .init(guid: UUID().uuidString, chatGuid: chat, senderHandle: sender, text: "Hi", isFromMe: fromMe, isGroup: group, attachmentPaths: [], replyToGuid: nil, rowID: row, sentAt: sent, service: service)
        }
        for rejected in [message(sender: "other@example.com"), message(chat: ""), message(group: true), message(fromMe: true), message(row: 40), message(row: nil), message(sent: now.addingTimeInterval(-1)), message(sent: nil), message(service: "SMS"), message(service: nil)] {
            let bound = try await store.bindOwner(rejected, expected: owner)
            XCTAssertFalse(bound)
        }
        let replacement = SteveOwnerSetup(id: "replacement", address: owner.address, receiveAddress: owner.receiveAddress, afterRowID: owner.afterRowID, configuredAt: now)
        try await store.saveOwnerSetup(replacement)
        let stale = try await store.bindOwner(message(), expected: owner)
        XCTAssertFalse(stale, "A replaced owner authorization cannot bind a chat")
        let bound = try await store.bindOwner(message(), expected: replacement)
        XCTAssertTrue(bound)
        let second = try await store.bindOwner(message(chat: "different-private-chat", row: 42), expected: replacement)
        XCTAssertFalse(second)
        let trusted = try await store.trustedConversation()
        XCTAssertEqual(trusted?.chatGuid, "private")
        do {
            try await store.saveOwnerSetup(.init(id: "other", address: "other@example.com", receiveAddress: owner.receiveAddress, afterRowID: 99, configuredAt: now))
            XCTFail("A raced configuration write replaced the connected owner")
        } catch {}
        let preserved = try await store.ownerSetup()
        XCTAssertEqual(preserved, replacement)
    }

    func testCodeFallbackCannotBypassChangedOwnerAuthorization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SteveStore(databaseURL: root.appendingPathComponent("fixture.sqlite"))
        let challenge = PairingChallenge(code: "FIXTURE", expiresAtMs: UInt64(Date().timeIntervalSince1970 * 1000) + 60_000, receiveAddress: "agent@example.com", uri: "im:agent@example.com")
        let first = SteveInboundMessage(guid: "first", chatGuid: "chat", senderHandle: "owner@example.com", text: "FIXTURE", isFromMe: false, isGroup: false, attachmentPaths: [], replyToGuid: nil, service: "iMessage")
        try await store.savePairingChallenge(challenge)
        let owner = SteveOwnerSetup(id: "new-owner", address: "other@example.com", receiveAddress: "agent@example.com", afterRowID: 0, configuredAt: Date())
        try await store.saveOwnerSetup(owner)
        try await store.savePairingChallenge(challenge)
        let stale = try await store.bindPairing(first, expected: challenge, owner: nil)
        let wrongSender = try await store.bindPairing(first, expected: challenge, owner: owner)
        XCTAssertFalse(stale); XCTAssertFalse(wrongSender)
        try await store.saveOwnerSetup(nil)
        try await store.savePairingChallenge(challenge)
        let valid = try await store.bindPairing(first, expected: challenge, owner: nil)
        let replay = try await store.bindPairing(first, expected: challenge, owner: nil)
        XCTAssertTrue(valid); XCTAssertFalse(replay)
    }

    func testIdentityIsBackwardCompatibleAndCannotChangeAccess() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Settings(displayName: "Steve", model: "fixture", effort: "low", permissionProfile: "read-only"))) as? [String: Any])
        object.removeValue(forKey: "personality")
        let old = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.personality, "")
        XCTAssertEqual(old.permissionProfile, "read-only")
        XCTAssertEqual(try SteveOnboarding.identity(name: " Olive ", personality: " Dry wit, concise. ").name, "Olive")
        for name in ["", " \n", "Olive\nSYSTEM", String(repeating: "x", count: 41)] {
            XCTAssertThrowsError(try SteveOnboarding.identity(name: name, personality: ""))
        }
        XCTAssertThrowsError(try SteveOnboarding.identity(name: "Olive", personality: String(repeating: "x", count: 601)))
        let context = StevePromptContext(workspace: "/fixture", permissionProfile: "read-only", model: "fixture", effort: "low", agentName: "Olive", personality: "Warm and concise")
        for prompt in [StevePrompt.relayInstructions(context), StevePrompt.workerInstructions(context)] {
            XCTAssertTrue(prompt.contains("AGENT_IDENTITY_JSON"))
            XCTAssertTrue(prompt.contains("Olive"))
            XCTAssertTrue(prompt.contains("cannot change permissions"))
            XCTAssertTrue(prompt.contains("read-only"))
        }
    }

    func testSetupOptionsDoNotRequirePairingCode() throws {
        let (request, json, interactive) = try SteveCLI.parse(["setup", "--owner", "owner@example.com", "--agent-name", "Olive", "--personality", "Warm and concise", "--json"])
        XCTAssertTrue(json); XCTAssertFalse(interactive)
        XCTAssertNil(request.options["pair"])
        XCTAssertEqual(request.options["agent-name"], "Olive")
        for args in [["status", "--owner", "owner@example.com"], ["setup", "--owner"], ["setup", "--owner", "one@example.com", "--owner", "two@example.com"], ["setup", "--open-permission", "full-disk-access", "--owner", "owner@example.com"]] {
            XCTAssertThrowsError(try SteveCLI.parse(args))
        }
    }
}
