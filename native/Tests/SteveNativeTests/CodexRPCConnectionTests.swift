import Foundation
import XCTest
@testable import SteveNative

private actor TurnProgressRecorder {
    private var events: [CodexTurnEvent] = []
    func append(_ event: CodexTurnEvent) { events.append(event) }
    func recorded() -> [CodexTurnEvent] { events }
}

final class CodexRPCConnectionTests: XCTestCase {
    func testConnectionSetupRequiresOfficialTypedMetadataAndTrustedURLs() throws {
        var params: [String: Any] = ["mode": "url", "serverName": "codex_apps", "url": "https://chatgpt.com/auth?token=secret", "_meta": ["_codex_apps": ["connector_auth_failure": ["is_auth_failure": true, "connector_id": "calendar", "connector_name": "Google Calendar", "install_url": "https://chatgpt.com/plugins?token=secret"]]]]
        XCTAssertEqual(CodexConnectionSetup.parse(params)?.connectorName, "Google Calendar")
        let validRPC = try nativeApprovalEchoConnection(params: params)
        defer { validRPC.stop() }
        validRPC.setApprovalHandler { request in
            XCTAssertEqual(request.connectionSetup?.connectorName, "Google Calendar")
            return .accept // A generic handler cannot assert OAuth completion.
        }
        let validEcho = try XCTUnwrap(try validRPC.request(method: "fixture") as? [String: Any])
        let validResult = try XCTUnwrap(validEcho["result"] as? [String: Any])
        XCTAssertEqual(String(decoding: try JSONSerialization.data(withJSONObject: validResult, options: [.sortedKeys]), as: UTF8.self), #"{"action":"cancel"}"#)

        for url in ["http://chatgpt.com/auth", "https://chatgpt.com.evil.test/auth", "https://user:pass@chatgpt.com/auth", "https://chatgpt.com:444/auth"] {
            var invalid = params; invalid["url"] = url
            XCTAssertNil(CodexConnectionSetup.parse(invalid))
        }
        params["_meta"] = ["_codex_apps": ["connector_auth_failure": ["is_auth_failure": 1, "connector_id": "calendar", "connector_name": "Google Calendar", "install_url": "https://chatgpt.com/plugins"]]]
        XCTAssertNil(CodexConnectionSetup.parse(params))
        params["_meta"] = ["_codex_apps": ["connector_auth_failure": ["is_auth_failure": true, "connector_id": "calendar", "connector_name": "Calendar https://secret.invalid", "install_url": "https://chatgpt.com/plugins"]]]
        XCTAssertNil(CodexConnectionSetup.parse(params))
        let rpc = try nativeApprovalEchoConnection(params: params)
        defer { rpc.stop() }
        rpc.setApprovalHandler { _ in XCTFail("Malformed connector setup reached generic approval"); return .accept }
        let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
        let result = try XCTUnwrap(echo["result"] as? [String: Any])
        XCTAssertEqual(result["action"] as? String, "cancel")
    }

    func testBrowserOriginApprovalRequiresAnEmptyObjectSchema() {
        XCTAssertTrue(CodexApprovalRequest.isEmptyOriginSchema(["type": "object", "properties": [:], "additionalProperties": false]))
        XCTAssertTrue(CodexApprovalRequest.isEmptyOriginSchema(["type": "object", "properties": [:], "required": []]))
        let numericFlag = try! JSONSerialization.jsonObject(with: Data(#"{"type":"object","properties":{},"additionalProperties":0}"#.utf8))
        XCTAssertFalse(CodexApprovalRequest.isEmptyOriginSchema(numericFlag))
        for value: Any in [NSNull(), ["type": "object"], ["type": "object", "properties": ["secret": ["type": "string"]]], ["type": "object", "properties": [:], "required": ["approval"]], ["type": "object", "properties": [:], "additionalProperties": true], ["type": "object", "properties": [:], "allOf": []]] {
            XCTAssertFalse(CodexApprovalRequest.isEmptyOriginSchema(value))
        }
    }

    private func nativeApprovalParams() -> [String: Any] {
        ["threadId": "t", "turnId": "u", "serverName": "computer-use", "mode": "form",
         "message": "Allow Codex to use TextEdit?",
         "requestedSchema": ["type": "object", "properties": [String: Any](), "additionalProperties": false],
         "_meta": ["connector_id": "computer-use", "tool_name": "get_app_state", "persist": ["always"], "tool_params": ["app": "TextEdit"]]]
    }

    func testNativeAppApprovalRequiresExactEmptyFormAndMatchingMetadata() {
        let valid = nativeApprovalParams()
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: valid), "TextEdit")
        var chatGPT = valid
        chatGPT["message"] = "Allow ChatGPT to use TextEdit?"
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: chatGPT), "TextEdit")
        for (key, value): (String, Any) in [("mode", "url"), ("serverName", "other"), ("message", "Allow Codex to use TextEdit? extra"), ("message", "Allow Codex to use Text\nEdit?"), ("message", "Allow Codex to use ?"), ("unknown", true), ("requestedSchema", ["type": "object", "properties": ["secret": ["type": "string"]]])] {
            var invalid = valid; invalid[key] = value
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: invalid), "Unexpected acceptance for " + key)
        }
        for (key, value): (String, Any) in [("connector_id", "other"), ("tool_name", "click"), ("persist", ["session"]), ("persist", "always"), ("persist", ["always", "forever"]), ("persist", [String]()), ("persist", ["session"]), ("persist", NSNull()),
            ("tool_params", ["app": "TextEdit", "command": "fixture"]),
            ("tool_params_display", [["name": "app", "value": "TextEdit"], ["name": "command", "value": "fixture"]]),
            ("tool_params", ["app": "Terminal"]), ("tool_params", ["app": "TextEdit", "command": "unsafe"])] {
            var invalid = valid
            var meta = invalid["_meta"] as! [String: Any]
            meta[key] = value; invalid["_meta"] = meta
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: invalid), "Unexpected metadata acceptance for " + key)
        }
        var ambiguous = valid
        ambiguous["meta"] = valid["_meta"]
        XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: ambiguous))
    }

    func testOfficialRawNativeAppFallbackWithoutSynthesizedMetadata() throws {
        var raw = nativeApprovalParams()
        raw["_meta"] = ["persist": ["always"]]
        raw["requestedSchema"] = ["$schema": NSNull(), "type": "object", "properties": [String: Any](), "required": NSNull()]
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: raw), "TextEdit")
        for missing in ["threadId", "turnId"] {
            var unbound = raw; unbound.removeValue(forKey: missing)
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: unbound))
        }
        let rpc = try nativeApprovalEchoConnection(params: raw)
        defer { rpc.stop() }
        rpc.setApprovalHandler { request in
            XCTAssertEqual(request.nativeAppName, "TextEdit")
            XCTAssertNil(request.connector)
            XCTAssertNil(request.tool)
            return .accept
        }
        let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
        let result = try XCTUnwrap(echo["result"] as? [String: Any])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertEqual(encoded, #"{"_meta":{"persist":"session"},"action":"accept","content":{}}"#)
    }

    func testLegacyNativeOpaqueMetadataPreservesExactGrantBoundary() throws {
        var raw = nativeApprovalParams()
        raw["message"] = "Allow ChatGPT to use Google Chrome?"
        raw["_meta"] = ["persist": ["always"], "opaque_extension": "fixture-private", "opaque_extension_two": ["action": "always"]]
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: raw), "Google Chrome")
        // Opaque metadata is not an action payload and never changes scope.
        let rpc = try nativeApprovalEchoConnection(params: raw)
        defer { rpc.stop() }
        rpc.setApprovalHandler { request in XCTAssertEqual(request.nativeAppName, "Google Chrome"); return .accept }
        let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
        let result = try XCTUnwrap(echo["result"] as? [String: Any])
        XCTAssertEqual(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self), #"{"_meta":{"persist":"session"},"action":"accept","content":{}}"#)
        for (key, value): (String, Any) in [("serverName", "browser-use"), ("message", "Allow ChatGPT to access https://example.invalid?"), ("mode", "url"), ("requestedSchema", ["type": "object", "properties": ["url": ["type": "string"]]])] {
            var invalid = raw; invalid[key] = value
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: invalid))
        }
        for (key, value): (String, Any) in [("codex_approval_kind", "unknown"), ("connector_id", "browser-use"), ("tool_name", "access_browser_origin"), ("tool_params", ["app": "Other App"]), ("tool_params_display", [["name": "app", "value": "Other App"]])] {
            var invalid = raw; var meta = raw["_meta"] as! [String: Any]
            meta[key] = value; invalid["_meta"] = meta
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: invalid))
        }
        for missing in ["threadId", "turnId"] {
            var invalid = raw; invalid.removeValue(forKey: missing)
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: invalid))
        }
    }

    private func modernNativeApprovalParams() -> [String: Any] {
        ["threadId": "t", "turnId": "u", "mode": "form", "message": "Native tool needs approval",
         "requestedSchema": ["$schema": NSNull(), "type": "object", "properties": [String: Any](), "required": NSNull()],
         "_meta": ["codex_approval_kind": "mcp_tool_call", "codex_request_type": "approval_request",
                   "connector_id": "connector_Computer_Use_fixture", "connector_name": "Computer Use",
                   "tool_name": "get_app_state", "tool_title": "Get app state", "tool_params": ["app": "TextEdit"],
                   "tool_params_display": [["name": "app", "display_name": "App", "value": "TextEdit"]], "persist": ["always"]]]
    }

    func testModernNativeMetadataDoesNotRequireLegacyServerOrMessageAndUsesSessionWire() throws {
        let params = modernNativeApprovalParams()
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: params), "TextEdit")
        var minimal = params
        minimal.removeValue(forKey: "message")
        minimal["_meta"] = ["codex_approval_kind": "mcp_tool_call", "connector_id": "computer-use", "tool_params": ["app": "TextEdit"], "persist": ["always"]]
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: minimal), "TextEdit")
        var displayOnly = params
        var meta = displayOnly["_meta"] as! [String: Any]
        meta["tool_params"] = [String: Any]()
        displayOnly["_meta"] = meta
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: displayOnly), "TextEdit")
        let rpc = try nativeApprovalEchoConnection(params: params)
        defer { rpc.stop() }
        rpc.setApprovalHandler { request in XCTAssertEqual(request.nativeAppName, "TextEdit"); return .accept }
        let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
        let result = try XCTUnwrap(echo["result"] as? [String: Any])
        XCTAssertEqual(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self), #"{"_meta":{"persist":"session"},"action":"accept","content":{}}"#)
    }

    func testModernNativeRejectsConflictingIdentitiesUnsupportedToolsAndNonAppRequests() {
        let valid = modernNativeApprovalParams()
        for (key, value): (String, Any) in [
            ("codex_approval_kind", "other"), ("codex_request_type", "other"), ("connector_id", "browser-use"),
            ("connector_id", "computer-useful"), ("tool_name", "run_script"), ("persist", ["forever"]),
            ("persist", [String]()), ("persist", ["session"]), ("persist", NSNull()),
            ("tool_params", ["app": "TextEdit", "command": "fixture"]),
            ("tool_params_display", [["name": "app", "value": "TextEdit"], ["name": "command", "value": "fixture"]]),
            ("tool_params", ["app": "Terminal"]), ("tool_params", ["app": 42]),
            ("tool_params_display", [["name": "app", "value": "Terminal"]]),
            ("tool_params_display", [["name": "app", "value": "TextEdit"], ["name": "app", "value": "TextEdit"]]),
            ("tool_params_display", [["name": "app", "value": ["secret": "fixture"]]]),
            ("tool_params_display", [["name": "app", "value": "TextEdit", "unexpected": true]])
        ] {
            var invalid = valid
            var meta = invalid["_meta"] as! [String: Any]
            meta[key] = value; invalid["_meta"] = meta
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: invalid), "Unexpected acceptance for " + key)
        }
        var noPersist = valid
        var noPersistMeta = valid["_meta"] as! [String: Any]
        noPersistMeta.removeValue(forKey: "persist"); noPersist["_meta"] = noPersistMeta
        XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: noPersist))
        var nonApp = valid
        nonApp["_meta"] = ["codex_approval_kind": "mcp_tool_call", "connector_id": "computer-use", "tool_params": ["url": "https://example.invalid"]]
        XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: nonApp))
        for missing in ["threadId", "turnId"] {
            var invalid = valid; invalid.removeValue(forKey: missing)
            XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: invalid))
        }
        var form = valid
        form["requestedSchema"] = ["type": "object", "properties": ["password": ["type": "string"]]]
        XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: form))
    }

    func testModernNativeBundleDisplayIdentityRequiresExactInstalledMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let app = root.appendingPathComponent("Fixture.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info: [String: Any] = ["CFBundleIdentifier": "com.apple.TextEdit", "CFBundleName": "TextEdit", "CFBundleDisplayName": "Localized TextEdit", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        var params = modernNativeApprovalParams()
        var meta = params["_meta"] as! [String: Any]
        meta["tool_params"] = ["app": "com.apple.TextEdit"]
        meta["opaque_extension"] = ["private": "never reflect this"]
        params["_meta"] = meta
        let resolver: (String) -> URL? = { id in XCTAssertEqual(id, "com.apple.TextEdit"); return app }
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: params, resolveApplication: resolver), "TextEdit")
        XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: params, resolveApplication: { _ in nil }))
        meta["tool_params_display"] = [["name": "app", "value": "Localized TextEdit"]]
        params["_meta"] = meta
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: params, resolveApplication: resolver), "Localized TextEdit")
        meta["tool_params_display"] = [["name": "app", "value": "Other App"]]
        params["_meta"] = meta
        XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: params, resolveApplication: resolver))
        meta["tool_params"] = ["app": "com.other.TextEdit"]
        meta["tool_params_display"] = [["name": "app", "value": "TextEdit"]]
        params["_meta"] = meta
        XCTAssertNil(CodexApprovalRequest.validatedNativeAppName(in: params, resolveApplication: { _ in app }))
    }

    func testModernNativeUnknownMetadataHasNoResponseAuthority() throws {
        var params = modernNativeApprovalParams()
        var meta = params["_meta"] as! [String: Any]
        meta["opaque_extension"] = ["action": "always", "secret": "fixture-private"]
        meta["opaque_extension_two"] = "fixture-private-two"
        params["_meta"] = meta
        XCTAssertEqual(CodexApprovalRequest.validatedNativeAppName(in: params), "TextEdit")
        let rpc = try nativeApprovalEchoConnection(params: params)
        defer { rpc.stop() }
        rpc.setApprovalHandler { request in XCTAssertEqual(request.nativeAppName, "TextEdit"); return .accept }
        let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
        let result = try XCTUnwrap(echo["result"] as? [String: Any])
        XCTAssertEqual(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self), #"{"_meta":{"persist":"session"},"action":"accept","content":{}}"#)
    }

    func testNativeApprovalShapeDiagnosticsExcludeArbitraryValuesAndBoundOutput() {
        var params = modernNativeApprovalParams()
        params["message"] = "private prompt https://secret.invalid/token"
        var meta = params["_meta"] as! [String: Any]
        meta["connector_name"] = "private connector"
        meta["sensitive_identifier_shaped_key"] = "private key value"
        meta["tool_params"] = ["app": "com.apple.TextEdit", "command": "private command", "token": "private token"]
        meta["tool_params_display"] = [["name": "app", "value": "TextEdit"], ["name": "private display name", "value": "private display value"]]
        params["_meta"] = meta
        let shape = CodexApprovalRequest.nativeApprovalShape(in: params)
        XCTAssertTrue(shape.contains("tool=get_app_state"))
        XCTAssertTrue(shape.contains("parameterApp=string"))
        XCTAssertTrue(shape.contains("app=string"))
        XCTAssertTrue(shape.contains("appIdentitiesMatch=false"))
        XCTAssertTrue(shape.contains("command:string"))
        XCTAssertFalse(shape.contains("TextEdit"))
        XCTAssertFalse(shape.contains("private"))
        XCTAssertFalse(shape.contains("secret.invalid"))
        XCTAssertFalse(shape.contains("sensitive_identifier_shaped_key"))
        meta["tool_name"] = "https://secret.invalid/token"
        meta["tool_params_display"] = Array(repeating: ["name": "app", "value": "sensitive"], count: 200)
        params["_meta"] = meta
        let bounded = CodexApprovalRequest.nativeApprovalShape(in: params)
        XCTAssertFalse(bounded.contains("secret"))
        XCTAssertFalse(bounded.contains("sensitive"))
        XCTAssertLessThan(bounded.utf8.count, 2500)
        XCTAssertTrue(bounded.contains("displayCount=99"))
    }

    private func nativeApprovalEchoConnection(params: [String: Any], approvalTimeout: TimeInterval = 1) throws -> CodexRPCConnection {
        let request = ["id": "approval", "method": "mcpServer/elicitation/request", "params": params] as [String: Any]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]), as: UTF8.self)
        let quoted = "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let script = """
        read -r first
        printf '%s\\n' \(quoted)
        read -r answer
        printf '{"id":1,"result":%s}\\n' "$answer"
        read -r hold
        """
        return CodexRPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], responseTimeout: 2, eventTimeout: 2, approvalTimeout: approvalTimeout)
    }

    func testAcceptedNativeAppApprovalWritesExactSessionOnlyWireResponse() throws {
        let rpc = try nativeApprovalEchoConnection(params: nativeApprovalParams())
        defer { rpc.stop() }
        rpc.setApprovalHandler { request in
            XCTAssertEqual(request.nativeAppName, "TextEdit")
            XCTAssertEqual(request.threadID, "t")
            XCTAssertEqual(request.turnID, "u")
            return .accept
        }
        let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
        let result = try XCTUnwrap(echo["result"] as? [String: Any])
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
        XCTAssertEqual(encoded, #"{"_meta":{"persist":"session"},"action":"accept","content":{}}"#)
        XCTAssertFalse(encoded.contains("always"))
    }

    func testNativeAutomaticTimeoutAndMissingHandlerCancelWithoutPersistence() throws {
        for withHandler in [false, true] {
            let rpc = try nativeApprovalEchoConnection(params: nativeApprovalParams(), approvalTimeout: 0.05)
            defer { rpc.stop() }
            if withHandler {
                rpc.setApprovalHandler { _ in
                    try? await Task.sleep(for: .seconds(1))
                    return .accept
                }
            }
            let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
            let result = try XCTUnwrap(echo["result"] as? [String: String])
            XCTAssertEqual(result, ["action": "cancel"])
        }
    }

    func testUnknownNativeFormCannotBecomeGrantFromGenericAcceptHandler() throws {
        var params = nativeApprovalParams()
        params["requestedSchema"] = ["type": "object", "properties": ["password": ["type": "string"]]]
        let rpc = try nativeApprovalEchoConnection(params: params)
        defer { rpc.stop() }
        rpc.setApprovalHandler { request in XCTAssertNil(request.nativeAppName); return .accept }
        let echo = try XCTUnwrap(try rpc.request(method: "fixture") as? [String: Any])
        XCTAssertEqual(echo["result"] as? [String: String], ["action": "cancel"])
    }

    private func connection(_ script: String, timeout: TimeInterval = 1) -> CodexRPCConnection {
        CodexRPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], responseTimeout: timeout, eventTimeout: timeout)
    }

    private func instructionRefreshFixture(rejectFirstInjection: Bool = false, returnedID: String = "existing", sandbox: String = "readOnly") throws -> (CodexRPCConnection, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("requests.jsonl")
        let quotedLog = "'" + log.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let rpc = connection(#"""
        loaded=1
        injections=0
        while IFS= read -r line; do
          printf '%s\n' "$line" >> \#(quotedLog)
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          [ -n "$id" ] || continue
          method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr -d '\\')
          result='{}'
          case "$method" in
            thread/loaded/list) if [ "$loaded" = 1 ]; then result='{"data":["existing"]}'; else result='{"data":[]}'; fi ;;
            thread/read) result='{"thread":{"id":"existing","turns":[{"id":"earlier-turn","status":"completed"}]}}' ;;
            thread/unsubscribe) loaded=0 ;;
            thread/resume) loaded=1; result='{"thread":{"id":"\#(returnedID)"},"sandbox":{"type":"\#(sandbox)"},"serviceTier":"default"}' ;;
            thread/inject_items)
              injections=$((injections + 1))
              if [ '\#(rejectFirstInjection)' = true ] && [ "$injections" = 1 ]; then
                printf '{"id":%s,"error":{"code":-32601,"message":"unsupported injection"}}\n' "$id"
                continue
              fi ;;
            turn/start) result='{"turn":{"id":"turn"}}' ;;
          esac
          printf '{"id":%s,"result":%s}\n' "$id" "$result"
          if [ "$method" = turn/start ]; then
            printf '%s\n' '{"method":"item/completed","params":{"threadId":"existing","turnId":"turn","item":{"id":"answer","type":"agentMessage","phase":"final_answer","text":"Done."}}}' '{"method":"turn/completed","params":{"threadId":"existing","turn":{"id":"turn","status":"completed"}}}'
          fi
        done
        """#, timeout: 2)
        return (rpc, log)
    }

    private func recordedRequests(_ log: URL) throws -> [[String: Any]] {
        try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    func testResumedInstructionRefreshPreservesThreadAndDoesNotRepeatUnchangedConfig() async throws {
        let (rpc, log) = try instructionRefreshFixture()
        defer { rpc.stop() }
        let client = CodexAppServerClient(connection: rpc)
        for instructions in ["Current worker contract", "Current worker contract", "Updated worker contract", "Updated worker contract"] {
            try await client.resumeThread(threadID: "existing", cwd: "/fixture", permissionProfile: "read-only", model: "fixture", developerInstructions: instructions)
        }
        let requests = try recordedRequests(log)
        let injections = requests.filter { $0["method"] as? String == "thread/inject_items" }
        XCTAssertEqual(injections.count, 2)
        for (request, instructions) in zip(injections, ["Current worker contract", "Updated worker contract"]) {
            let params = try XCTUnwrap(request["params"] as? [String: Any])
            XCTAssertEqual(params["threadId"] as? String, "existing")
            let items = try XCTUnwrap(params["items"] as? [[String: Any]])
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?["role"] as? String, "developer")
            let content = try XCTUnwrap(items.first?["content"] as? [[String: String]])
            XCTAssertEqual(content.first?["type"], "input_text")
            XCTAssertTrue(content.first?["text"]?.hasSuffix("\n\n" + instructions) == true)
        }
        let methods = requests.compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "thread/resume" }.count, 4)
        XCTAssertEqual(methods.filter { $0 == "thread/unsubscribe" }.count, 2)
        XCTAssertTrue(Set(methods).isDisjoint(with: ["thread/start", "thread/fork", "thread/rollback", "turn/start"]))
    }

    func testInstructionInjectionFailurePreventsExecutionAndIsNotCached() async throws {
        let (rpc, log) = try instructionRefreshFixture(rejectFirstInjection: true)
        defer { rpc.stop() }
        let client = CodexAppServerClient(connection: rpc)
        do {
            try await client.resumeThread(threadID: "existing", cwd: "/fixture", permissionProfile: "read-only", model: "fixture", developerInstructions: "Current contract")
            _ = try await client.runTurn(threadID: "existing", text: "Continue", model: "fixture", effort: "low")
            XCTFail("Execution continued after instruction refresh failed")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("-32601"))
            XCTAssertFalse(CodexSessionRecovery.shouldReplaceResumedThread(for: error))
        }
        for _ in 0..<2 {
            try await client.resumeThread(threadID: "existing", cwd: "/fixture", permissionProfile: "read-only", model: "fixture", developerInstructions: "Current contract")
        }
        let methods = try recordedRequests(log).compactMap { $0["method"] as? String }
        XCTAssertEqual(methods.filter { $0 == "thread/inject_items" }.count, 2)
        XCTAssertFalse(methods.contains("turn/start"))
    }

    func testInstructionRefreshRequiresMatchingThreadAndVerifiedSandbox() async throws {
        for (id, sandbox) in [("different", "readOnly"), ("existing", "dangerFullAccess")] {
            let (rpc, log) = try instructionRefreshFixture(returnedID: id, sandbox: sandbox)
            defer { rpc.stop() }
            let client = CodexAppServerClient(connection: rpc)
            do {
                try await client.resumeThread(threadID: "existing", cwd: "/fixture", permissionProfile: "read-only", model: "fixture", developerInstructions: "Current contract")
                XCTFail("Unverified task accepted")
            } catch {}
            let methods = try recordedRequests(log).compactMap { $0["method"] as? String }
            XCTAssertFalse(methods.contains("thread/inject_items"))
            XCTAssertFalse(methods.contains("turn/start"))
        }
    }

    func testLateControlResponseIsReadAfterTurnCompletion() async throws {
        let rpc = connection(#"""
        read -r first
        printf '%s\n' '{"id":1,"result":{}}' '{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"completed"}}}'
        read -r control
        printf '%s\n' '{"id":2,"result":{"acknowledged":true}}'
        read -r hold
        """#)
        defer { rpc.stop() }
        _ = try rpc.request(method: "fixture")
        _ = try await rpc.waitForTurn(threadID: "t", turnID: "u")
        let response = try rpc.requestWhileStreaming(method: "turn/interrupt") as? [String: Bool]
        XCTAssertEqual(response?["acknowledged"], true)
    }

    func testTurnProgressReportsOnlyCompletedCommentary() async throws {
        let rpc = connection(#"""
        read -r first
        printf '%s\n' '{"id":1,"result":{}}' '{"method":"item/agentMessage/delta","params":{"threadId":"t","turnId":"u","itemId":"commentary","delta":"Working"}}' '{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"id":"tool","type":"commandExecution","status":"completed"}}}' '{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"id":"commentary","type":"agentMessage","phase":"commentary","text":"Working safely."}}}' '{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"id":"final","type":"agentMessage","phase":"final_answer","text":"Done."}}}' '{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"completed"}}}'
        read -r hold
        """#)
        defer { rpc.stop() }
        _ = try rpc.request(method: "fixture")
        let recorder = TurnProgressRecorder()
        let result = try await rpc.waitForTurn(threadID: "t", turnID: "u") { event in
            await recorder.append(event)
        }
        let events = await recorder.recorded()
        XCTAssertEqual(events, [.init(phase: .commentary, text: "Working safely.")])
        XCTAssertEqual(result.text, "Done.")
    }

    func testCancellingOneWaitWakesItWithoutStoppingAnotherTurn() async throws {
        let rpc = connection(#"""
        read -r first
        printf '%s\n' '{"id":1,"result":{}}'
        read -r second
        printf '%s\n' '{"id":2,"result":{}}' '{"method":"turn/completed","params":{"threadId":"other","turn":{"id":"v","status":"completed"}}}'
        read -r hold
        """#)
        defer { rpc.stop() }
        _ = try rpc.request(method: "fixture")
        let waiting = Task { try await rpc.waitForTurn(threadID: "cancelled", turnID: "u") }
        rpc.cancelWait(threadID: "cancelled", turnID: "u")
        do { _ = try await waiting.value; XCTFail("Cancelled wait must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(rpc.isRunning)
        _ = try rpc.requestWhileStreaming(method: "fixture")
        _ = try await rpc.waitForTurn(threadID: "other", turnID: "v")
        XCTAssertTrue(rpc.isRunning)
    }

    func testUnownedHelperEventsCannotExhaustParentEventBuffer() async throws {
        let rpc = CodexRPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"""
        read -r first
        printf '%s\n' '{"id":1,"result":{}}'
        i=0
        while [ "$i" -lt 21000 ]; do
          printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"helper","turnId":"child-turn","itemId":"i","delta":"x"}}'
          i=$((i+1))
        done
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"parent","turn":{"id":"u","status":"completed"}}}'
        read -r hold
        """#], responseTimeout: 2, eventTimeout: 10, filterUnownedEvents: true)
        defer { rpc.stop() }
        _ = try rpc.request(method: "turn/start", params: ["threadId": "parent"])
        _ = try await rpc.waitForTurn(threadID: "parent", turnID: "u")
        XCTAssertTrue(rpc.isRunning)
    }

    func testFailedTurnCannotReturnPriorAgentTextAsSuccess() async throws {
        let rpc = connection(#"""
        read -r first
        printf '%s\n' '{"id":1,"result":{}}' '{"method":"item/completed","params":{"threadId":"t","turnId":"u","item":{"id":"i","type":"agentMessage","phase":"final_answer","text":"done"}}}' '{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"u","status":"failed","error":{"message":"sensitive provider detail"}}}}'
        read -r hold
        """#)
        defer { rpc.stop() }
        _ = try rpc.request(method: "fixture")
        do {
            _ = try await rpc.waitForTurn(threadID: "t", turnID: "u")
            XCTFail("A failed protocol turn must throw")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("failed"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive"))
        }
    }

    func testEOFSettlesPendingRequest() {
        let rpc = connection("read -r first\nexit 0", timeout: 2)
        defer { rpc.stop() }
        let start = Date()
        XCTAssertThrowsError(try rpc.request(method: "fixture"))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testMissingRolloutClassificationSurvivesSanitizationWithoutServerDetails() {
        let rpc = connection(#"""
        read -r first
        printf '%s\n' '{"id":1,"error":{"code":-32600,"message":"no rollout found for thread id private-thread https://private.invalid/?token=secret"}}'
        """#)
        defer { rpc.stop() }
        XCTAssertThrowsError(try rpc.request(method: "thread/resume")) { error in
            XCTAssertEqual(error.localizedDescription, "Codex App Server request failed (-32600): no rollout found")
            XCTAssertTrue(CodexSessionRecovery.shouldReplaceResumedThread(for: error))
        }
    }

    func testEOFSettlesTurnWaiter() async throws {
        let rpc = connection(#"""
        read -r first
        printf '%s\n' '{"id":1,"result":{}}'
        exit 0
        """#)
        defer { rpc.stop() }
        _ = try rpc.request(method: "fixture")
        do {
            _ = try await rpc.waitForTurn(threadID: "t", turnID: "u")
            XCTFail("EOF must fail an unfinished turn")
        } catch { XCTAssertTrue(error.localizedDescription.contains("exited")) }
    }

    func testRequestDeadlineIsBounded() {
        let rpc = connection("read -r first\nread -r hold", timeout: 0.1)
        defer { rpc.stop() }
        let start = Date()
        XCTAssertThrowsError(try rpc.request(method: "fixture")) { error in
            XCTAssertTrue(error.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testStopWakesBlockedRequestAndControlCannotRestartIt() async {
        let rpc = connection("read -r first\nread -r hold", timeout: 5)
        let began = expectation(description: "request began")
        let ended = expectation(description: "request ended")
        DispatchQueue.global().async {
            began.fulfill()
            do {
                _ = try rpc.request(method: "fixture")
                XCTFail("Stopped request should fail")
            } catch { }
            ended.fulfill()
        }
        await fulfillment(of: [began], timeout: 1)
        // Wait for launch, rather than depending on a fixed sleep.
        let deadline = Date().addingTimeInterval(1)
        while !rpc.isRunning && Date() < deadline { await Task.yield() }
        XCTAssertTrue(rpc.isRunning)
        rpc.stop()
        await fulfillment(of: [ended], timeout: 1)
        XCTAssertThrowsError(try rpc.requestWhileStreaming(method: "turn/interrupt"))
        XCTAssertFalse(rpc.isRunning)
    }

    func testUnpresentedElicitationsCancelWithoutSavingAUserDenial() throws {
        for metadata in [#""mode":"url","url":"https://example.invalid/authorize""#,
                         #""mode":"form","_meta":{"connector_id":"computer-use","tool_name":"click"}"#] {
            let script = """
            read -r first
            printf '%s\\n' '{"id":"approval","method":"mcpServer/elicitation/request","params":{\(metadata)}}'
            read -r answer
            case "$answer" in
              *cancel*) printf '%s\\n' '{"id":1,"result":{"declined":true}}' ;;
              *) printf '%s\\n' '{"id":1,"result":{"declined":false}}' ;;
            esac
            read -r hold
            """
            let rpc = connection(script)
            defer { rpc.stop() }
            let result = try rpc.request(method: "fixture") as? [String: Bool]
            XCTAssertEqual(result?["declined"], true)
        }
    }

    func testApprovalHookCannotBlockRPCReader() throws {
        let rpc = connection(#"""
        read -r first
        printf '%s\n' '{"id":"approval","method":"mcpServer/elicitation/request","params":{"threadId":"t","turnId":"u","mode":"url","url":"https://example.invalid/auth"}}' '{"id":1,"result":{"responsive":true}}'
        read -r answer
        read -r hold
        """#)
        defer { rpc.stop() }
        rpc.setApprovalHandler { request in
            XCTAssertEqual(request.threadID, "t")
            XCTAssertEqual(request.turnID, "u")
            return .decline
        }
        let result = try rpc.request(method: "fixture") as? [String: Bool]
        XCTAssertEqual(result?["responsive"], true)
    }

    func testEnvironmentDoesNotInheritAnotherTaskRouting() {
        let clean = CodexComputerUseRuntime.sanitizedEnvironment([
            "CODEX_APP_TOOLS_PIPE_PATH": "stale", "CODEX_SESSION_ID": "stale",
            "CODEX_THREAD_ID": "stale", "PATH": "/usr/bin", "CODEX_HOME": "/fixture/.codex"
        ])
        XCTAssertNil(clean["CODEX_APP_TOOLS_PIPE_PATH"])
        XCTAssertNil(clean["CODEX_SESSION_ID"])
        XCTAssertNil(clean["CODEX_THREAD_ID"])
        XCTAssertEqual(clean["PATH"], "/usr/bin")
        XCTAssertEqual(clean["CODEX_HOME"], "/fixture/.codex")
    }

    func testStructuredEmptyArtifactsNeverSelectAnOldWorkspaceFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("unrelated".utf8).write(to: root.appendingPathComponent("old.pdf"))
        let text = #"{"schemaVersion":1,"kind":"worker_result","status":"blocked","summary":"No report produced","artifacts":[]}"#
        let result = CodexTurnResult(text: text, attachmentPaths: [])
            .resolvingWorkspaceFiles(in: root.path)
            .resolvingRequestedWorkspaceFile(in: root.path, request: "send me the PDF")
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.attachments.isEmpty)
    }

    func testInlineMediaMaterializesInsideWorkspaceAndRejectsSymlinkRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let url = "data:audio/wav;base64," + Data("audio fixture".utf8).base64EncodedString()
        let path = try XCTUnwrap(CodexTurnResult.materializeDataURL(url, workspace: root.path))
        XCTAssertTrue(path.hasPrefix(root.path + "/.steve-artifacts/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("audio fixture".utf8))
        try FileManager.default.removeItem(at: root.appendingPathComponent(".steve-artifacts"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent(".steve-artifacts"), withDestinationURL: outside)
        XCTAssertNil(CodexTurnResult.materializeDataURL(url, workspace: root.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    func testStructuredDataURLIsNotRemovedFromJSON() {
        let text = #"{"kind":"worker_result","summary":"data:image/png;base64,YQ==","artifacts":[]}"#
        XCTAssertEqual(CodexTurnResult(text: text, attachmentPaths: []).text, text)
    }
    func testRelayOutgoingConfigDisablesDiscoveredToolsWithoutChangingWorker() async throws {
        let overrides = CodexAppServerClient.relayToolOverrides(effectiveConfig: [
            "mcp_servers": ["computer-use": [:], "custom.service": [:]],
            "plugins": ["fixture@local": [:]],
            "apps": ["fixture-app": [:]]
        ])
        let client = CodexAppServerClient()
        let relay = try await client.threadParams(cwd: "/fixture", permissionProfile: "read-only", model: "fixture", developerInstructions: "relay", toolOverrides: overrides)
        let relayConfig = try XCTUnwrap(relay["config"] as? [String: Any])
        XCTAssertEqual(((relayConfig["mcp_servers"] as? [String: Any])?["computer-use"] as? [String: Bool])?["enabled"], false)
        XCTAssertEqual(((relayConfig["mcp_servers"] as? [String: Any])?["custom.service"] as? [String: Bool])?["enabled"], false)
        XCTAssertEqual(((relayConfig["plugins"] as? [String: Any])?["fixture@local"] as? [String: Bool])?["enabled"], false)
        XCTAssertEqual(((relayConfig["apps"] as? [String: Any])?["fixture-app"] as? [String: Bool])?["enabled"], false)
        XCTAssertEqual(relayConfig["features.shell_tool"] as? Bool, false)
        XCTAssertEqual(relayConfig["web_search"] as? String, "disabled")
        let worker = try await client.threadParams(cwd: "/fixture", permissionProfile: "workspace-write", model: "fixture", developerInstructions: "worker")
        let workerConfig = try XCTUnwrap(worker["config"] as? [String: Any])
        XCTAssertNil(workerConfig["mcp_servers"])
        XCTAssertNil(workerConfig["features.shell_tool"])
        XCTAssertEqual(worker["approvalPolicy"] as? String, "on-request")
    }

    func testCommandAndFileApprovalsDeclineWithoutProtocolFailure() throws {
        for method in ["item/commandExecution/requestApproval", "item/fileChange/requestApproval"] {
            let rpc = connection("""
            read -r first
            printf '%s\\n' '{"id":"approval","method":"\(method)","params":{"threadId":"t","turnId":"u"}}'
            read -r answer
            case "$answer" in
              *decision*decline*) printf '%s\\n' '{"id":1,"result":{"declined":true}}' ;;
              *) printf '%s\\n' '{"id":1,"result":{"declined":false}}' ;;
            esac
            read -r hold
            """)
            defer { rpc.stop() }
            let response = try rpc.request(method: "fixture") as? [String: Bool]
            XCTAssertEqual(response?["declined"], true)
        }
    }

}
