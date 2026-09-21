import XCTest
import SQLite
@testable import SteveNative

final class SteveControlTests: XCTestCase {
    func testPermissionHandoffRunsOnlyExplicitlyAndRejectsChangesBeforeOpening() async throws {
        let (root, store, runtime, _) = try await settingsRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try await store.getSettings()
        let response = await SteveControl.handle(.init(command: "setup", options: ["open-permission": "full-disk-access"]), runtime: runtime) { target in
            XCTAssertEqual(target, .fullDiskAccess)
            return SteveControlResponse(state: "needs_user_action", summary: "fixture permission handoff", values: ["settingsOpened": "true"])
        }
        XCTAssertEqual(response.summary, "fixture permission handoff")
        for options in [["open-permission": "unknown", "workspace": "/tmp/should-not-be-created"],
                        ["open-permission": "full-disk-access", "permission": "danger-full-access"],
                        ["workspace": root.path, "max-operators": "5"],
                        ["workspace": root.path, "max-helpers": "-1"],
                        ["workspace": "/tmp/should-not-be-created", "max-workers": "5"],
                        ["workspace": "/tmp/should-not-be-created", "worker-model": "unknown"],
                        ["workspace": "/tmp/should-not-be-created", "coordinator-effort": "unknown"],
                        ["workspace": "/tmp/should-not-be-created", "max-workers": "2", "max-operators": "2"],
                        ["workspace": "/tmp/should-not-be-created", "worker-model": "one", "model": "two"],
                        ["workspace": root.path, "relay-model": "unavailable-model"]] {
            let rejected = await SteveControl.handle(.init(command: "setup", options: options), runtime: runtime) { _ in
                XCTFail("Opened Settings for an invalid or mixed request")
                return SteveControlResponse(state: "ready", summary: "unexpected")
            }
            XCTAssertEqual(rejected.state, "failed")
        }
        _ = await SteveControl.handle(.init(command: "status"), runtime: runtime) { _ in
            XCTFail("Ordinary status opened Settings")
            return SteveControlResponse(state: "ready", summary: "unexpected")
        }
        let after = try await store.getSettings()
        XCTAssertEqual(after?.workspaceRoot, before?.workspaceRoot)
        XCTAssertEqual(after?.permissionProfile, before?.permissionProfile)
    }

    func testStatusKeepsLegacyKeysAndAddsPublicModelCatalog() async throws {
        let (root, _, runtime, _) = try await settingsRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        let response = await SteveControl.handle(.init(command: "status"), runtime: runtime)
        for (current, legacy) in [("coordinatorModel", "relayModel"), ("coordinatorEffort", "relayEffort"),
                                  ("coordinatorServiceTier", "relayServiceTier"), ("workerModel", "operatorModel"),
                                  ("workerEffort", "operatorEffort"), ("workerServiceTier", "operatorServiceTier"),
                                  ("maxWorkers", "maxOperators"), ("maxHelpersPerWorker", "maxHelpers")] {
            XCTAssertNotNil(response.values[current])
            XCTAssertEqual(response.values[current], response.values[legacy])
        }
        XCTAssertEqual(response.models?.count, 0, "An unavailable catalog must not invent supported models")
        let oldJSON = Data(#"{"state":"ready","summary":"fixture","checks":[],"values":{}}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(SteveControlResponse.self, from: oldJSON).models)
        var withCatalog = response
        withCatalog.models = [.init(id: "fixture", model: "fixture", displayName: "Fixture", description: nil,
                                   supportedReasoningEfforts: [.init(reasoningEffort: "high", description: nil)], isDefault: true)]
        let encoded = try JSONEncoder().encode(withCatalog)
        let decoded = try JSONDecoder().decode(SteveControlResponse.self, from: encoded)
        XCTAssertEqual(decoded.models?.first?.supportedReasoningEfforts.first?.reasoningEffort, "high")
        XCTAssertEqual(decoded.values, response.values)
    }

    private func settingsRuntime() async throws -> (URL, SteveStore, SteveRuntime, Connection) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = try SteveStore(databaseURL: root.appendingPathComponent("fixture.sqlite3"))
        try await store.saveSettings(Settings(displayName: "Fixture", model: "fixture-model", effort: "high", permissionProfile: ":workspace-write", workspaceRoot: root.path))
        let connection = CodexRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/true"), arguments: [], responseTimeout: 0.2)
        let runtime = try SteveRuntime(store: store, messages: MessagesService(databasePath: root.appendingPathComponent("no-messages.sqlite3").path), codex: CodexAppServerClient(connection: connection))
        return (root, store, runtime, try Connection(store.databaseURL.path))
    }

    private func modelCatalogConnection() -> CodexRPCConnection {
        let script = #"""
        read -r initialize
        printf '%s\n' '{"jsonrpc":"2.0","id":1,"result":{}}'
        read -r initialized
        read -r list
        printf '%s\n' '{"jsonrpc":"2.0","id":2,"result":{"data":[{"id":"fixture-model","model":"fixture-model","supportedReasoningEfforts":[{"reasoningEffort":"high"}]},{"id":"fixture-next","model":"fixture-next","supportedReasoningEfforts":[{"reasoningEffort":"medium"}]}],"nextCursor":null}}'
        read -r hold
        """#
        return CodexRPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], responseTimeout: 2)
    }

    func testIdentityPreservesAccessAndDisconnectRemovesOwnerAuthorization() async throws {
        let (root, store, runtime, _) = try await settingsRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.saveGatewayEpoch("existing-boundary")
        try await store.saveOwnerSetup(.init(id: "owner", address: "owner@example.com", receiveAddress: "agent@example.com", afterRowID: 3, configuredAt: Date()))
        try await store.saveTrustedConversation(.init(chatGuid: "existing-chat", senderHandle: "owner@example.com"))
        try await runtime.configureIdentity(name: "Olive", personality: "Brief and warm")
        let configured = try await store.getSettings()
        let epoch = try await store.gatewayEpoch()
        let trusted = try await store.trustedConversation()
        XCTAssertEqual(configured?.displayName, "Olive")
        XCTAssertEqual(configured?.personality, "Brief and warm")
        XCTAssertEqual(configured?.permissionProfile, ":workspace-write")
        XCTAssertEqual(configured?.workspaceRoot, root.path)
        XCTAssertEqual(configured?.model, "fixture-model")
        XCTAssertEqual(epoch, "existing-boundary")
        XCTAssertEqual(trusted?.chatGuid, "existing-chat")
        try await runtime.disconnectPhone()
        let ownerAfter = try await store.ownerSetup()
        let trustedAfter = try await store.trustedConversation()
        XCTAssertNil(ownerAfter); XCTAssertNil(trustedAfter)
        let settingsAfter = try await store.getSettings()
        XCTAssertEqual(settingsAfter?.displayName, "Olive")
        XCTAssertEqual(settingsAfter?.workspaceRoot, root.path)
        await runtime.stop()
    }

    func testModelAndEffortChangeApplyWithoutInvalidatingPermissionBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SteveStore(databaseURL: root.appendingPathComponent("fixture.sqlite3"))
        try await store.saveSettings(Settings(displayName: "Fixture", model: "fixture-model", effort: "high", permissionProfile: ":workspace-write", workspaceRoot: root.path))
        try await store.saveGatewayEpoch("permission-boundary")
        let connection = modelCatalogConnection()
        defer { connection.stop() }
        let runtime = try SteveRuntime(store: store, messages: MessagesService(databasePath: root.appendingPathComponent("no-messages.sqlite3").path), codex: CodexAppServerClient(connection: connection))

        try await runtime.configureAgentSettings(options: ["model": "fixture-next", "effort": "medium"])

        let storedSettings = try await store.getSettings()
        let saved = try XCTUnwrap(storedSettings)
        let gatewayEpoch = try await store.gatewayEpoch()
        let boundaryActive = await runtime.boundaryChangeIsActive()
        XCTAssertEqual(saved.model, "fixture-next")
        XCTAssertEqual(saved.effort, "medium")
        XCTAssertEqual(gatewayEpoch, "permission-boundary")
        XCTAssertFalse(boundaryActive, "Model choices apply to future turns without revoking the permission boundary")
        let status = await SteveControl.handle(.init(command: "status"), runtime: runtime)
        XCTAssertEqual(status.models?.map(\.id), ["fixture-model", "fixture-next"])
        XCTAssertEqual(status.values["workerModel"], "fixture-next")
        // Switching just the model must validate its retained effort before any
        // unrelated workspace or identity setting can be applied.
        for option in ["worker-model", "coordinator-model"] {
            let rejected = await SteveControl.handle(.init(command: "setup", options: [
                "workspace": root.appendingPathComponent("must-not-be-created").path,
                option: "fixture-model"
            ]), runtime: runtime)
            XCTAssertEqual(rejected.state, "failed")
            let preserved = try await store.getSettings()
            XCTAssertEqual(preserved?.workspaceRoot, root.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-be-created").path))
        }
    }

    func testFailedSettingsSaveRestoresPreparedBoundaryAndCanRetry() async throws {
        let (root, store, runtime, database) = try await settingsRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        try database.execute("""
            CREATE TRIGGER fail_fixture_settings BEFORE INSERT ON settings
            WHEN NEW.key = 'settings'
            BEGIN SELECT RAISE(ABORT, 'fixture settings unavailable'); END;
            """)
        do { try await runtime.selectServiceTier("fast"); XCTFail("Settings write unexpectedly succeeded") } catch {}
        let settingsAfterFailedSave = try await store.getSettings()
        let snapshotAfterFailedSave = await runtime.snapshot()
        let boundaryAfterFailedSave = await runtime.boundaryChangeIsActive()
        XCTAssertEqual(settingsAfterFailedSave?.serviceTier, .standard)
        XCTAssertEqual(snapshotAfterFailedSave.settings.serviceTier, .standard)
        XCTAssertFalse(boundaryAfterFailedSave, "A prepared boundary may reopen on a failed settings save")

        try database.execute("DROP TRIGGER fail_fixture_settings")
        try await runtime.selectServiceTier("fast")
        let settingsAfterRetry = try await store.getSettings()
        let boundaryAfterRetry = await runtime.boundaryChangeIsActive()
        XCTAssertEqual(settingsAfterRetry?.serviceTier, .fast)
        XCTAssertFalse(boundaryAfterRetry)
    }

    func testAgentProfileChangeDoesNotInvalidatePermissionBoundary() async throws {
        let (root, store, runtime, database) = try await settingsRuntime()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.saveGatewayEpoch("permission-boundary")
        try database.execute("""
            CREATE TRIGGER fail_fixture_epoch BEFORE INSERT ON settings
            WHEN NEW.key = 'gateway_epoch'
            BEGIN SELECT RAISE(ABORT, 'fixture invalidation unavailable'); END;
            """)
        try await runtime.selectServiceTier("fast")
        let saved = try await store.getSettings()
        let gatewayEpoch = try await store.gatewayEpoch()
        let boundaryActive = await runtime.boundaryChangeIsActive()
        XCTAssertEqual(saved?.serviceTier, .fast)
        XCTAssertEqual(gatewayEpoch, "permission-boundary")
        XCTAssertFalse(boundaryActive, "Agent profiles apply to the next turn without changing the permission boundary")
    }

    func testRepeatedSetupPreservesPendingWorkSchedulesAndBoundary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SteveStore(databaseURL: root.appendingPathComponent("fixture.sqlite3"))
        let settings = Settings(displayName: "Fixture", model: "fixture-model", effort: "high", permissionProfile: ":workspace-write", workspaceRoot: root.path)
        try await store.saveSettings(settings)
        try await store.saveGatewayEpoch("original-boundary")
        try await store.saveTrustedConversation(.init(chatGuid: "fixture-chat", senderHandle: "user@example.test"))
        let message = SteveInboundMessage(guid: "queued", chatGuid: "fixture-chat", senderHandle: "user@example.test", text: "Read my project", isFromMe: false, isGroup: false, attachmentPaths: [], replyToGuid: nil)
        _ = try await store.acceptInbound(message)
        let automation = try SteveUserAutomationStore(databaseURL: store.databaseURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let authorization = try ScheduleAuthorization(chatGUID: message.chatGuid, senderHandle: message.senderHandle, workspace: root.path, permission: settings.permissionProfile!)
        let provenance = ExplicitUserProvenance(source: .pairedMessage, sourceID: "reminder", statement: "Remind me to stretch", explicitlyRequested: true, recordedAt: now)
        let schedule = try await automation.createSchedule(requestID: "reminder", name: "Stretch", prompt: "Stretch", kind: .reminder, rule: .once(at: now.addingTimeInterval(3600)), timeZone: "America/New_York", authorization: authorization, provenance: provenance, now: now)
        // Any accidental App Server launch touches only this fixture marker.
        let marker = root.appendingPathComponent("unexpected-codex-launch")
        let connection = CodexRPCConnection(executable: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path], responseTimeout: 0.2)
        defer { connection.stop() }
        let runtime = try SteveRuntime(store: store, messages: MessagesService(databasePath: root.appendingPathComponent("no-messages.sqlite3").path), codex: CodexAppServerClient(connection: connection))
        let alias = root.appendingPathComponent("workspace-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        try await runtime.configureWorkspace(alias.path)
        try await runtime.selectPermission("workspace-write")
        try await runtime.selectModel(settings.model)
        try await runtime.selectEffort(settings.effort)
        try await runtime.selectServiceTier(settings.serviceTier.rawValue)
        try await runtime.configureAgentSettings(options: ["service-tier": "fast", "relay-service-tier": "fast", "max-operators": "4", "max-helpers": "2"])
        let epoch = try await store.gatewayEpoch()
        let queued = try await store.queueState("inbound:queued")
        let savedSchedule = try await automation.schedule(id: schedule.id)
        let savedSettings = try await store.getSettings()
        XCTAssertEqual(epoch, "original-boundary")
        XCTAssertEqual(queued, "pending")
        XCTAssertEqual(savedSchedule, schedule)
        XCTAssertEqual(savedSettings?.permissionProfile, ":workspace-write")
        XCTAssertEqual(savedSettings?.serviceTier, .fast)
        XCTAssertEqual(savedSettings?.relayServiceTier, .fast)
        XCTAssertEqual(savedSettings?.maxConcurrentOperators, 4)
        XCTAssertEqual(savedSettings?.maxHelpersPerOperator, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testVideoWindowCLIRequiresGroundedScopedSelection() throws {
        let (inventory, json, _) = try SteveCLI.parse(["video", "windows", "--app", "com.apple.TextEdit", "--json"])
        XCTAssertEqual(inventory.options, ["action": "windows", "app": "com.apple.TextEdit"]); XCTAssertTrue(json)
        let (start, _, _) = try SteveCLI.parse(["video", "start", "--demonstration", "--window", "42", "--app", "com.apple.TextEdit", "--json"])
        XCTAssertEqual(try TaskVideoTarget.parse(start.options), .window(42, app: "com.apple.TextEdit"))
        XCTAssertThrowsError(try SteveCLI.parse(["video", "windows", "--display", "1"]))
        XCTAssertThrowsError(try SteveCLI.parse(["video", "start", "--window", "42", "--window", "43", "--app", "com.apple.TextEdit"]))
        XCTAssertThrowsError(try SteveCLI.parse(["video", "start", "--app", "com.apple.TextEdit", "--app", "com.other.App"]))
    }

    func testNonInteractiveSetupHasNoImplicitMutations() throws {
        let (request, json, interactive) = try SteveCLI.parse(["setup", "--non-interactive", "--json"])
        XCTAssertEqual(request.command, "setup")
        XCTAssertTrue(request.options.isEmpty)
        XCTAssertTrue(json)
        XCTAssertFalse(interactive)
        XCTAssertThrowsError(try SteveCLI.parse(["status", "--workspace", "/tmp"]))
        XCTAssertThrowsError(try SteveCLI.parse(["setup", "--workspace", "--json"]))
        XCTAssertThrowsError(try SteveCLI.parse(["setup", "--approve-all"]))
    }

    func testExplicitSetupOptionsRoundTrip() throws {
        let (request, _, _) = try SteveCLI.parse(["setup", "--workspace", "/tmp/a folder", "--permission", "read-only", "--login", "--pair"])
        let decoded = try JSONDecoder().decode(SteveControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.options["workspace"], "/tmp/a folder")
        XCTAssertEqual(decoded.options["permission"], "read-only")
        XCTAssertEqual(decoded.options["login"], "true")
        XCTAssertEqual(decoded.options["pair"], "true")
    }

    func testStatusJSONRoundTripsRoleProfilesAndTaskSummaries() throws {
        let task = OperatorTaskRecord(id: "task-1", chatGuid: "chat", senderHandle: "user@example.test",
            workspace: "/tmp", permission: "read-only", title: "Compare options", objective: "Compare",
            threadID: "worker-1", mode: .background, state: .running, inbound: [], runID: "run-1")
        let response = SteveControlResponse(state: "ready", summary: "Steve is ready.", values: [
            "operatorModel": "gpt-6-astra", "operatorEffort": "high", "operatorServiceTier": "standard",
            "relayModel": "gpt-5.6-luna", "relayEffort": "low", "relayServiceTier": "standard",
            "maxConcurrentOperators": "2", "maxHelpersPerOperator": "1"
        ], tasks: [OperatorTaskSummary(task)])
        let decoded = try JSONDecoder().decode(SteveControlResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(decoded.values["relayModel"], "gpt-5.6-luna")
        XCTAssertEqual(decoded.values["operatorModel"], "gpt-6-astra")
        XCTAssertEqual(decoded.values["maxConcurrentOperators"], "2")
        XCTAssertEqual(decoded.tasks?.first?.id, "task-1")
        XCTAssertEqual(decoded.tasks?.first?.state, .running)
    }

    func testSocketRejectsLongPaths() {
        XCTAssertThrowsError(try SteveControlSocket.address("/" + String(repeating: "x", count: 105)))
    }

    func testApprovalRequiresAnExplicitCurrentID() throws {
        XCTAssertThrowsError(try SteveCLI.parse(["approve", "--json"]))
        let (request, json, _) = try SteveCLI.parse(["deny", "TEST1234", "--json"])
        XCTAssertEqual(request.options, ["id": "TEST1234"])
        XCTAssertTrue(json)
        XCTAssertThrowsError(try SteveCLI.parse(["approve", "TEST1234", "second-id"]))
    }

    func testControlSocketUsesOwnerOnlyEndpointAndOneServer() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-" + UUID().uuidString.prefix(8))
        let path = directory.appendingPathComponent("socket").path
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try SteveLocalControlServer(path: path) { request in
            SteveControlResponse(state: "ready", summary: request.command)
        }
        defer { withExtendedLifetime(server) {} }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try SteveLocalControlServer(path: path) { _ in SteveControlResponse(state: "failed", summary: "duplicate") })
        let response = try SteveControlSocket.request(SteveControlRequest(command: "status"), path: path)
        XCTAssertEqual(response.summary, "status")
        XCTAssertEqual(response.state, "ready")
    }

    func testControlSocketRejectsSharedDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try SteveLocalControlServer(path: directory.appendingPathComponent("socket").path) { _ in
            SteveControlResponse(state: "ready", summary: "no")
        })
    }
}
