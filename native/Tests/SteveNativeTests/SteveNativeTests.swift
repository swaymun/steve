import XCTest
@testable import SteveNative

final class SteveNativeTests: XCTestCase {
    func testMessageSplittingPreservesHomePathsAndQueryURLs() {
        XCTAssertEqual(StevePrompt.plainText("I can work in ~/.steve-workspace. Send me a task."), ["I can work in ~/.steve-workspace. Send me a task."])
        XCTAssertEqual(StevePrompt.plainText("See https://example.com/search?q=one. Finished."), ["See https://example.com/search?q=one. Finished."])
    }

    func testPairingChallengeDecodesWithoutWebviewQRMarkup() throws {
        let data = #"{"code":"ABC12345","expiresAtMs":123,"receiveAddress":"me@example.com","uri":"im:me%40example.com"}"#.data(using: .utf8)!
        let challenge = try JSONDecoder().decode(PairingChallenge.self, from: data)
        XCTAssertEqual(challenge.code, "ABC12345")
        XCTAssertEqual(challenge.uri, "im:me%40example.com")
    }

    func testSettingsPreserveRustWireShape() throws {
        let settings = Settings(displayName: "Steve", model: "gpt-5.6-sol", effort: "low")
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as! [String: Any]
        XCTAssertEqual(object["displayName"] as? String, "Steve")
        XCTAssertEqual(object["model"] as? String, "gpt-5.6-sol")
    }

    func testLoginSnapshotDecodesRustCamelCaseKeys() throws {
        let data = #"{"authUrl":"https://auth.openai.com/login","loginId":"login-1"}"#.data(using: .utf8)!
        let login = try JSONDecoder().decode(LoginSnapshot.self, from: data)
        XCTAssertEqual(login.authURL, "https://auth.openai.com/login")
        XCTAssertEqual(login.loginID, "login-1")
    }

    func testPromptUsesTheImessageContractAndPlainTextLimits() {
        let context = StevePromptContext(
            workspace: "~/.steve/workspace",
            permissionProfile: "workspace-write",
            model: "gpt-5.6-luna",
            effort: "medium"
        )
        let relay = StevePrompt.relayInstructions(context)
        let worker = StevePrompt.workerInstructions(context)
        XCTAssertTrue(relay.contains("relay_request"))
        XCTAssertTrue(relay.contains("workerPrompt"))
        XCTAssertTrue(relay.contains("You have no execution tools"))
        XCTAssertTrue(relay.contains("TASKS_JSON is the authoritative task index"))
        XCTAssertTrue(relay.contains("Safety gate"))
        XCTAssertTrue(relay.contains("workerContextAction"))
        XCTAssertTrue(relay.contains("RECOVERY_ATTEMPTED"))
        XCTAssertTrue(relay.contains("~/.steve/workspace"))
        XCTAssertFalse(relay.contains("node_repl"))
        XCTAssertTrue(worker.contains("worker_result"))
        XCTAssertTrue(worker.contains("Use the installed official Computer Use tool"))
        XCTAssertTrue(worker.contains("never switch tools, surfaces, or profiles to evade it"))
        XCTAssertTrue(worker.contains("Do not import private browser bridges"))
        XCTAssertTrue(worker.contains("Do not send iMessages yourself"))
        XCTAssertTrue(worker.contains("readable, verified files"))
        XCTAssertFalse(worker.contains("systemPrompt"))
        XCTAssertFalse(worker.contains("—"))

        let parts = StevePrompt.plainText("**Done.** See https://example.com.\nA third sentence.")
        XCTAssertEqual(parts, ["Done. See https://example.com.", "A third sentence."])
        XCTAssertEqual(StevePrompt.plainText("I'm working on that.\nDone."), ["Done."])
        XCTAssertEqual(StevePrompt.plainText("Top pick—fully vegan. Quiet option — historic sound levels."), ["Top pick, fully vegan. Quiet option, historic sound levels."])
        XCTAssertFalse(StevePrompt.markdownRequested(in: ["Send me a guide."]))
        XCTAssertTrue(StevePrompt.markdownRequested(in: ["Send it as Markdown."]))
        XCTAssertTrue(StevePrompt.markdownRequested(in: ["Send me guide.md."]))
        XCTAssertFalse(StevePrompt.markdownRequested(in: ["Don't send Markdown."]))
        XCTAssertFalse(StevePrompt.markdownRequested(in: ["Send it as Markdown.", "Actually, a PDF."]))
        XCTAssertFalse(StevePrompt.markdownRequested(in: ["Read README.md and send me a PDF."]))
        XCTAssertFalse(StevePrompt.markdownRequested(in: ["Why Markdown? I wanted a PDF."]))
        XCTAssertFalse(StevePrompt.markdownRequested(in: ["Read README.md."]))
        XCTAssertTrue(StevePrompt.markdownRequested(in: ["Use Markdown, not PDF."]))
        XCTAssertEqual(StevePrompt.readableDocumentExtension(in: ["An editable Word document, please."]), "docx")
        XCTAssertEqual(StevePrompt.readableDocumentExtension(in: ["An editable Word document.", "Actually a PDF."]), "pdf")
        XCTAssertEqual(StevePrompt.readableDocumentExtension(in: ["Summarize the Word document."]), "pdf")
        XCTAssertEqual(StevePrompt.readableDocumentExtension(in: ["Make a PDF from this Word document."]), "pdf")
        XCTAssertTrue(StevePrompt.markdownRequested(in: ["Send the PDF as Markdown."]))
        XCTAssertFalse(StevePrompt.markdownRequested(in: ["Send it as Markdown.", "Actually, a Word document."]))
        XCTAssertEqual(StevePrompt.readableDocumentExtension(in: ["Send the guide as Word, not PDF."]), "docx")
        XCTAssertNil(ConversationProgress.safeMessage("I'm using the web-game development skill."))
        XCTAssertNil(ConversationProgress.safeMessage("The local server is running."))
        XCTAssertFalse(relay.contains("Progress updates"))
        XCTAssertTrue(StevePrompt.isClarification("Where should I fly from?"))
        XCTAssertFalse(StevePrompt.isClarification("The PDF is ready. Where should I fly from?"))
    }

    func testAgentProtocolParsesVersionedRelayWorkerAndDeliveryEnvelopes() throws {
        let relay = try AgentEnvelopeParser.relayRequest(from: "noise {\"schemaVersion\":1,\"kind\":\"relay_request\",\"action\":\"execute\",\"workerPrompt\":\"Make the report.\",\"userMessage\":null,\"workerContextAction\":\"compact\"} trailing")
        XCTAssertEqual(relay.action, .execute)
        XCTAssertEqual(relay.workerContextAction, .compact)
        let worker = try AgentEnvelopeParser.workerResult(from: #"{"schemaVersion":1,"kind":"worker_result","status":"completed","summary":"Report verified.","userQuestion":null,"artifacts":[]}"#)
        XCTAssertEqual(worker.status, .completed)
        let plan = try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":1,"kind":"delivery_plan","status":"complete","messages":["Done."],"attachments":[]}"#)
        XCTAssertEqual(plan.messages, ["Done."])
        let recovery = try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":1,"kind":"delivery_plan","status":"failed","messages":[],"attachments":[],"recovery":{"action":"fresh","reason":"The worker history is contradictory and retryable."}}"#)
        XCTAssertEqual(recovery.recovery?.action, .fresh)
        XCTAssertThrowsError(try AgentEnvelopeParser.deliveryPlan(from: #"{"schemaVersion":1,"kind":"delivery_plan","status":"failed","messages":[],"attachments":[],"recovery":{"action":"reuse","reason":"not a recovery"}}"#))
        XCTAssertThrowsError(try AgentEnvelopeParser.workerResult(from: #"{"schemaVersion":2,"kind":"worker_result","status":"completed","summary":"Nope","userQuestion":null,"artifacts":[]}"#))
    }

    func testCodexComputerUseRuntimeBuildsAppServerConfiguration() {
        let runtime = CodexComputerUseRuntime(
            executablePath: "/Users/test/.codex/computer-use/SkyComputerUseClient",
            codexHome: "/Users/test/.codex",
            workingDirectory: "/Users/test/.codex/computer-use"
        )
        XCTAssertTrue(runtime.serverConfiguration.contains("args=[\"mcp\"]"))
        XCTAssertTrue(runtime.serverConfiguration.contains("enabled=true"))
        XCTAssertTrue(runtime.serverConfiguration.contains("env={CODEX_HOME=\"/Users/test/.codex\"}"))
        XCTAssertEqual(runtime.environment["CODEX_HOME"], "/Users/test/.codex")
    }

    func testCodexTurnAccumulatorExtractsLocalAudioPathFromToolResult() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("steve-audio-\(UUID().uuidString).m4a")
        try Data("audio fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        var accumulator = CodexTurnAccumulator(threadID: "thread-1", turnID: "turn-1")
        let completed: [String: Any] = [
            "method": "item/completed",
            "params": [
                "threadId": "thread-1",
                "turnId": "turn-1",
                "item": [
                    "id": "tool-1",
                    "type": "mcpToolCall",
                    "result": [
                        "content": [
                            ["type": "text", "filePath": file.path]
                        ]
                    ]
                ]
            ]
        ]

        XCTAssertNil(accumulator.consume(completed))
        XCTAssertEqual(accumulator.result().attachments.map(\.path), [file.path])
    }

    func testFinalResponseChunksAtTwoSentencesAnd500Characters() {
        let input = "First sentence. Second sentence. Third sentence. Fourth sentence."
        let parts = StevePrompt.plainText(input)
        XCTAssertEqual(parts, ["First sentence. Second sentence.", "Third sentence. Fourth sentence."])

        let longInput = (0..<120).map { "Word\($0)" }.joined(separator: " ")
        let longParts = StevePrompt.plainText(longInput)
        XCTAssertGreaterThan(longParts.count, 1)
        XCTAssertTrue(longParts.allSatisfy { $0.count <= 500 })
    }

    func testFinalResponsePreservesURLsPathsAndLists() {
        let parts = StevePrompt.plainText("- See https://example.com/report.pdf.\n- Use /Users/fixture/Documents/report.pdf.")
        XCTAssertEqual(parts, ["See https://example.com/report.pdf. Use /Users/fixture/Documents/report.pdf."])
    }

    func testMessageFormattingUnwrapsMarkdownWithoutChangingURLsOrFilenames() {
        let input = "**Ready.** Read the [guide](https://example.com/guide_(final)).\n*Keep* _this_ __copy__: /Users/fixture/my_file__name.pdf and https://example.com/_private_/a__b."
        XCTAssertEqual(StevePrompt.plainText("![Chart](https://example.com/chart.png)"), ["Chart (https://example.com/chart.png)"])
        XCTAssertEqual(StevePrompt.plainText(input), [
            "Ready. Read the guide (https://example.com/guide_(final)).",
            "Keep this copy: /Users/fixture/my_file__name.pdf and https://example.com/_private_/a__b."
        ])
    }

    func testCodexSessionRecoveryRecognizesStaleResumedThreadFailures() {
        XCTAssertTrue(CodexSessionRecovery.shouldReplaceResumedThread(
            for: RPCError(message: "Timed out waiting for Codex turn")
        ))
        XCTAssertTrue(CodexSessionRecovery.shouldReplaceResumedThread(
            for: RPCError(message: "App Server error -32600: thread already has an active writer")
        ))
        XCTAssertTrue(CodexSessionRecovery.shouldReplaceResumedThread(
            for: RPCError(message: "Codex App Server exited")
        ))
        XCTAssertTrue(CodexSessionRecovery.shouldReplaceResumedThread(
            for: RPCError(message: "Custom tool call output is missing for call id")
        ))
        XCTAssertTrue(CodexSessionRecovery.shouldReplaceResumedThread(
            for: RPCError(message: "App Server error -32600: no rollout found for thread id")
        ))
        XCTAssertFalse(CodexSessionRecovery.shouldReplaceResumedThread(
            for: RPCError(message: "Messages attachment send failed")
        ))
    }

    func testCodexTurnResultExtractsRequestedAttachments() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("steve-attachment-\(UUID().uuidString).m4a")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = CodexTurnResult(
            text: "Here is the result.\nATTACHMENT: \(file.path)",
            attachmentPaths: []
        )
        XCTAssertEqual(result.text, "Here is the result.")
        XCTAssertEqual(result.attachments.map(\.path), [file.path])
        XCTAssertEqual(result.attachments.first?.caption, "Here's the result.")
    }

    func testCodexTurnResultAcceptsFileURLAttachmentHandoff() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("steve-file-url-\(UUID().uuidString).pdf")
        try Data("fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let result = CodexTurnResult(
            text: "Here is the file.\nATTACHMENT: \(file.absoluteString)",
            attachmentPaths: []
        )
        XCTAssertEqual(result.attachments.map(\.path), [file.path])
        XCTAssertEqual(result.text, "Here is the file.")
    }

    func testCodexTurnResultResolvesWorkspaceFilenameForAttachment() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("steve-workspace-\(UUID().uuidString)", isDirectory: true)
        let file = workspace.appendingPathComponent("kokoro-haiku.m4a")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("audio fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = CodexTurnResult(
            text: "The audio file is saved as kokoro-haiku.m4a in the workspace.",
            attachmentPaths: []
        ).resolvingWorkspaceFiles(in: workspace.path)

        XCTAssertEqual(
            result.attachments.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
            [file.resolvingSymlinksInPath().path]
        )
    }

    func testCodexTurnResultResolvesFullLocalPathMentionedInFinalText() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("steve-full-path-\(UUID().uuidString)", isDirectory: true)
        let file = workspace.appendingPathComponent("kokoro-haiku.m4a")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("audio fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = CodexTurnResult(
            text: "The audio is ready at \(file.path).",
            attachmentPaths: []
        ).resolvingWorkspaceFiles(in: workspace.path)

        XCTAssertEqual(result.attachments.map(\.path), [file.path])
        XCTAssertEqual(result.text, "The audio is ready at \(file.path).")
    }

    func testCodexTurnResultResolvesQuotedLocalPathWithSpaces() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("steve-quoted-path-\(UUID().uuidString)", isDirectory: true)
        let file = workspace.appendingPathComponent("Kokoro haiku.m4a")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("audio fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = CodexTurnResult(
            text: "The audio is ready at \"\(file.path)\".",
            attachmentPaths: []
        ).resolvingWorkspaceFiles(in: workspace.path)

        XCTAssertEqual(result.attachments.map(\.path), [file.path])
    }

    func testCodexTurnResultFindsRequestedAudioInWorkspaceWhenResponseOmitsPath() throws {
        let workspace = FileManager.default.temporaryDirectory.appendingPathComponent("steve-requested-audio-\(UUID().uuidString)", isDirectory: true)
        let file = workspace.appendingPathComponent("kokoro-haiku.m4a")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try Data("audio fixture".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let result = CodexTurnResult(
            text: "The direct attachment did not work.",
            attachmentPaths: []
        ).resolvingRequestedWorkspaceFile(in: workspace.path, request: "Send me the audio file you generated.")

        XCTAssertEqual(
            result.attachments.map { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path },
            [file.resolvingSymlinksInPath().path]
        )
    }

    func testCodexTurnResultMaterializesBase64AudioDataURL() throws {
        let payload = Data("audio fixture".utf8).base64EncodedString()
        let dataURL = "data:audio/mp4;base64,\(payload)"
        let result = CodexTurnResult(
            text: "Here is the audio: [Listen](\(dataURL))",
            attachmentPaths: []
        )
        guard let attachment = result.attachments.first else {
            return XCTFail("Expected the data URL to become an attachment")
        }
        do {
            let attachmentURL = URL(fileURLWithPath: attachment.path)
            defer { try? FileManager.default.removeItem(at: attachmentURL.deletingLastPathComponent()) }
            XCTAssertEqual(attachmentURL.pathExtension, "m4a")
            XCTAssertEqual(try Data(contentsOf: attachmentURL), Data("audio fixture".utf8))
            XCTAssertFalse(result.text.contains("data:"))
        }
    }

    func testCodexTurnResultSupportsCommonDataURLTypesAndLeavesRemoteLinks() throws {
        let cases = [
            ("image/png", "png"),
            ("image/jpeg", "jpg"),
            ("image/heic", "heic"),
            ("audio/mpeg", "mp3"),
            ("audio/wav", "wav"),
            ("video/quicktime", "mov"),
            ("application/pdf", "pdf"),
            ("application/epub+zip", "epub"),
            ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx"),
            ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"),
            ("text/csv", "csv"),
            ("application/zip", "zip")
        ]
        let fixture = Data("file fixture".utf8)
        let text = cases.map { mime, _ in
            "data:\(mime);base64,\(fixture.base64EncodedString())"
        }.joined(separator: "\n")
        let result = CodexTurnResult(text: text, attachmentPaths: [])
        let paths = result.attachments.map(\.path)
        defer {
            for path in paths { try? FileManager.default.removeItem(at: URL(fileURLWithPath: path).deletingLastPathComponent()) }
        }

        XCTAssertEqual(result.attachments.count, cases.count)
        XCTAssertEqual(Set(result.attachments.map { URL(fileURLWithPath: $0.path).pathExtension }), Set(cases.map(\.1)))

        let remote = CodexTurnResult(
            text: "Read more at https://example.com/report.pdf",
            attachmentPaths: []
        )
        XCTAssertTrue(remote.text.contains("https://example.com/report.pdf"))
        XCTAssertTrue(remote.attachments.isEmpty)
    }

    func testStoreKeepsAgentSessionsInTheExistingSchema() async throws {
        let database = FileManager.default.temporaryDirectory
            .appendingPathComponent("steve-test-\(UUID().uuidString)")
            .appendingPathComponent("steve.sqlite3")
        defer { try? FileManager.default.removeItem(at: database.deletingLastPathComponent()) }

        let store = try SteveStore(databaseURL: database)
        let settings = Settings(displayName: "Steve", model: "gpt-5.6-sol", effort: "low", workspaceRoot: "~/.steve/workspace")
        try await store.saveSettings(settings)
        try await store.saveAgentSession(.init(
            chatGuid: "chat-guid",
            threadID: "thread-id",
            relayThreadID: "relay-thread-id",
            relayPromptVersion: StevePrompt.relayPromptVersion,
            workspacePath: "~/.steve/workspace",
            permissionProfile: "workspace-write",
            model: "gpt-5.6-sol",
            effort: "low",
            lastMessageGuid: "message-guid",
            executionState: "idle",
            updatedAt: Date()
        ))

        let savedSettings = try await store.getSettings()
        let savedSession = try await store.agentSession(for: "chat-guid")
        let firstIdentity = try await store.rememberIdentity("message-guid")
        let duplicateIdentity = try await store.rememberIdentity("message-guid")
        XCTAssertEqual(savedSettings?.workspaceRoot, "~/.steve/workspace")
        XCTAssertEqual(savedSession?.threadID, "thread-id")
        XCTAssertEqual(savedSession?.relayThreadID, "relay-thread-id")
        XCTAssertEqual(savedSession?.relayPromptVersion, StevePrompt.relayPromptVersion)
        XCTAssertTrue(firstIdentity)
        XCTAssertFalse(duplicateIdentity)
    }
}
