import XCTest
@testable import SteveNative

final class SetupReadinessTests: XCTestCase {
    private func snapshot(workspace: String? = "/tmp", permission: String? = ":workspace-write", paired: Bool = true, paused: Bool = false, messages: Dependency = .init(name: "messages", available: true, detail: "")) -> Snapshot {
        Snapshot(
            status: .init(state: "Ready", detail: "", connected: true),
            settings: .init(displayName: "Steve", model: "gpt-5.6-luna", effort: "high", permissionProfile: permission, workspaceRoot: workspace),
            paused: paused, dependencies: [.init(name: "codex", available: true, detail: ""), messages], transportMode: "app-server",
            account: .init(account: .init(type: "chatgpt", email: nil, planType: nil, id: nil), requiresOpenaiAuth: false),
            models: [], permissions: [], usage: nil,
            trustedConversation: paired ? .init(chatGuid: "chat", senderHandle: "sender") : nil, pairing: nil
        )
    }

    func testReturnsOnlyTheFirstRequiredSetupAction() {
        XCTAssertEqual(SetupReadiness.evaluate(snapshot: snapshot(workspace: nil, permission: nil, paired: false), computerUseInstalled: false).action, .chooseWorkspace)
        XCTAssertEqual(SetupReadiness.evaluate(snapshot: snapshot(permission: nil, paired: false), computerUseInstalled: false).action, .choosePermissions)
        XCTAssertEqual(SetupReadiness.evaluate(snapshot: snapshot(paired: false), computerUseInstalled: false).action, .connectPhone)
        XCTAssertEqual(SetupReadiness.evaluate(snapshot: snapshot(), computerUseInstalled: false).action, .openComputerUseGuide)
    }

    func testConfigurationReadyKeepsLiveAcceptanceSeparate() {
        let result = SetupReadiness.evaluate(snapshot: snapshot(), computerUseInstalled: true)
        XCTAssertEqual(result.title, "Configuration ready")
        XCTAssertEqual(result.action, .copyLiveCheck)
        XCTAssertTrue(result.detail.contains("Live acceptance is separate"))
        XCTAssertEqual(SetupReadiness.evaluate(snapshot: snapshot(paused: true), computerUseInstalled: true).action, .resume)
    }

    func testMessagesPermissionFailureUsesExistingPermissionHandoff() {
        let denied = Dependency(name: "messages", available: false, detail: "authorization denied")
        XCTAssertEqual(SetupReadiness.evaluate(snapshot: snapshot(messages: denied), computerUseInstalled: true).action, .openFullDiskAccess)
        let database = Dependency(name: "messages", available: false, detail: "database disk image is malformed")
        XCTAssertEqual(SetupReadiness.evaluate(snapshot: snapshot(messages: database), computerUseInstalled: true).action, .diagnostics)
    }

    func testConfiguredAddressIsNotReportedAsConnected() {
        var waiting = snapshot(paired: false)
        waiting.ownerSetup = .init(id: "owner", address: "owner@example.com", receiveAddress: "agent@example.com", afterRowID: 0, configuredAt: Date())
        let readiness = SetupReadiness.evaluate(snapshot: waiting, computerUseInstalled: true)
        XCTAssertEqual(readiness.title, "Send your first message")
        XCTAssertTrue(readiness.detail.contains("no code"))
        let check = SteveControl.phoneCheck(waiting)
        XCTAssertEqual(check.state, "needs_user_action")
        XCTAssertTrue(check.detail.contains("owner@example.com"))
        XCTAssertTrue(check.detail.contains("agent@example.com"))
    }
}
