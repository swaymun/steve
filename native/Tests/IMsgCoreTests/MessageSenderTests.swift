import XCTest
@testable import IMsgCore

final class MessageSenderTests: XCTestCase {
    func testMessageSenderStagesArbitraryFileWithOriginalName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steve-messages-\(UUID().uuidString)")
        let source = root.appendingPathComponent("quarterly report.xlsx")
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("spreadsheet fixture".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: root) }

        var capturedArguments: [String] = []
        let sender = MessageSender(
            runner: { _, arguments in capturedArguments = arguments },
            attachmentsSubdirectoryProvider: { staging }
        )
        try sender.send(MessageSendOptions(
            recipient: "someone@example.com",
            text: "Here is the file.",
            attachmentPath: source.path,
            service: .imessage,
            chatGUID: "chat-guid",
            allowSMSFallback: false
        ))

        XCTAssertEqual(capturedArguments.count, 10)
        XCTAssertEqual(capturedArguments[1], "Here is the file.")
        XCTAssertEqual(capturedArguments[4], "1")
        let staged = URL(fileURLWithPath: capturedArguments[3])
        XCTAssertEqual(staged.lastPathComponent, "quarterly report.xlsx")
        XCTAssertEqual(try Data(contentsOf: staged), Data("spreadsheet fixture".utf8))
    }
}
