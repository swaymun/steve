import XCTest
import SQLite
@testable import SteveNative

final class SteveStoreContentionTests: XCTestCase {
    private func fixture() throws -> SteveStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try SteveStore(databaseURL: root.appendingPathComponent("store.sqlite"))
    }

    /// A second connection reserves the writer exactly as automation does.
    /// It commits after a brief delay, without occupying Swift's actor executor.
    private func withContendingWriter(_ store: SteveStore, operation: () async throws -> Void) async throws {
        let connection = try Connection(store.databaseURL.path)
        try connection.execute("BEGIN IMMEDIATE")
        let released = expectation(description: "second writer committed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            do {
                try connection.run("INSERT OR REPLACE INTO metadata(key, value) VALUES ('contention_fixture', 'committed')")
                try connection.execute("COMMIT")
            } catch { XCTFail("Fixture writer failed: \(error)") }
            released.fulfill()
        }
        do { try await operation() }
        catch {
            await fulfillment(of: [released], timeout: 5)
            throw error
        }
        await fulfillment(of: [released], timeout: 5)
    }

    private func message() -> SteveInboundMessage {
        .init(guid: "contended", chatGuid: "chat", senderHandle: "fixture@example.test", text: "Fixture", isFromMe: false, isGroup: false, attachmentPaths: [], replyToGuid: nil, rowID: 42)
    }

    func testInboundWaitsForWriterAndDuplicateIsNotReenqueued() async throws {
        let store = try fixture(), message = message()
        try await withContendingWriter(store) {
            let inserted = try await store.acceptInbound(message)
            XCTAssertTrue(inserted)
        }
        let duplicate = try await store.acceptInbound(message)
        let inbox = try await store.pendingInbox(), cursor = try await store.messageCursor()
        XCTAssertFalse(duplicate)
        XCTAssertEqual(inbox.map(\.guid), [message.guid]); XCTAssertEqual(cursor, 42)
    }

    func testDeliveryStageAndQuarantineReserveWriterBeforeReading() async throws {
        let store = try fixture(), message = message()
        try await store.saveGatewayEpoch("epoch")
        _ = try await store.acceptInbound(message)
        _ = try await store.claimInbox([message.guid])
        let part = SteveStore.OutboundPart(id: "part", chatGuid: "chat", recipient: message.senderHandle, replyTo: message.guid, inboxGUIDs: [message.guid], text: "Fixture response", attachmentPath: nil, workspace: nil, permission: nil)
        // Both operations read before writing. Deferred transactions would read
        // an old WAL snapshot, then fail their lock upgrade despite busyTimeout.
        try await withContendingWriter(store) {
            try await store.stageDelivery([part], inboxGUIDs: [message.guid], expectedEpoch: "epoch")
        }
        let pending = try await store.pendingOutbox()
        XCTAssertEqual(pending.map(\.id), [part.id])
        try await withContendingWriter(store) {
            try await store.failOutboundPart(part)
        }
        let state = try await store.queueState("inbound:" + message.guid)
        let outbound = try await store.queueState(part.id)
        XCTAssertEqual(state, "failed"); XCTAssertEqual(outbound, "failed")
    }
}
