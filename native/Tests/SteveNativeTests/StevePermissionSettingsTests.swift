import XCTest
import IMsgCore
import SQLite
@testable import SteveNative

final class StevePermissionSettingsTests: XCTestCase {
    private func fixtureApp(_ name: String) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test." + UUID().uuidString, "CFBundleName": name, "CFBundleDisplayName": name + " Display", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        return app
    }

    @MainActor
    func testPermissionTargetsOpenCorrectPaneAndRevealCorrectOwner() throws {
        let steve = try fixtureApp("Steve Fixture"), computer = try fixtureApp("Native Computer Fixture")
        let cases: [(StevePermissionTarget, URL, String)] = [
            (.fullDiskAccess, steve, "Privacy_AllFiles"), (.messagesAutomation, steve, "Privacy_Automation"),
            (.computerUseScreenRecording, computer, "Privacy_ScreenCapture"), (.computerUseAccessibility, computer, "Privacy_Accessibility"),
            (.steveScreenRecording, steve, "Privacy_ScreenCapture"), (.steveAccessibility, steve, "Privacy_Accessibility")
        ]
        for (target, app, pane) in cases {
            var opened: [URL] = [], revealed: [URL] = []
            let result = StevePermissionSettings.open(target, steveAppURL: steve, computerUseAppURL: computer,
                openURL: { opened.append($0); return true }, revealApp: { revealed.append($0) })
            XCTAssertEqual(opened.map(\.absoluteString), ["x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?" + pane])
            XCTAssertEqual(revealed, target == .messagesAutomation ? [] : [app])
            XCTAssertEqual(result.values["appPath"], app.path)
            XCTAssertEqual(result.values["appName"], app.deletingPathExtension().lastPathComponent + " Display")
            XCTAssertEqual(result.values["settingsOpened"], "true")
            XCTAssertEqual(result.state, "needs_user_action", "Opening Settings must never claim a grant")
            let decoded = try JSONDecoder().decode(SteveControlResponse.self, from: JSONEncoder().encode(result))
            XCTAssertEqual(decoded.values, result.values)
        }
    }

    @MainActor
    func testSettingsFallbackAndCompleteOpeningFailureRetainHumanInstructions() throws {
        let app = try fixtureApp("Steve")
        for succeedsOnLegacy in [true, false] {
            var opened: [URL] = []
            let result = StevePermissionSettings.open(.fullDiskAccess, steveAppURL: app, computerUseAppURL: nil,
                openURL: { opened.append($0); return succeedsOnLegacy && opened.count == 2 }, revealApp: { _ in })
            XCTAssertEqual(opened.count, 2)
            XCTAssertTrue(opened[1].absoluteString.contains("com.apple.preference.security?Privacy_AllFiles"))
            XCTAssertEqual(result.values["settingsOpened"], String(succeedsOnLegacy))
            XCTAssertEqual(result.state, "needs_user_action")
            XCTAssertTrue(result.summary.contains("Privacy & Security"))
            XCTAssertTrue(result.values["nextStep"]!.contains("relaunch Steve"))
        }
    }

    @MainActor
    func testMissingComputerUseNeverRevealsSteveOrOpensWrongSettings() throws {
        let result = StevePermissionSettings.open(.computerUseAccessibility, steveAppURL: try fixtureApp("Steve"), computerUseAppURL: nil,
            openURL: { _ in XCTFail("Opened without Computer Use installed"); return true },
            revealApp: { _ in XCTFail("Revealed the wrong permission owner") })
        XCTAssertEqual(result.values["settingsOpened"], "false")
        XCTAssertNil(result.values["appPath"])
        XCTAssertTrue(result.summary.contains("native Computer Use"))
    }

    func testPermissionCLIRequiresOneExplicitSupportedTarget() throws {
        for target in StevePermissionTarget.allCases {
            let (request, json, interactive) = try SteveCLI.parse(["setup", "--open-permission", target.rawValue, "--json", "--non-interactive"])
            XCTAssertEqual(request.options, ["open-permission": target.rawValue])
            XCTAssertTrue(json); XCTAssertFalse(interactive)
        }
        for args in [["setup", "--open-permission"], ["setup", "--open-permission", "unknown"],
                     ["doctor", "--open-permission", "full-disk-access"],
                     ["setup", "--open-permission", "full-disk-access", "--pair"],
                     ["setup", "--open-permission", "full-disk-access", "--open-permission", "steve-accessibility"]] {
            XCTAssertThrowsError(try SteveCLI.parse(args))
        }
        for command in ["setup", "doctor", "status"] {
            let (request, _, _) = try SteveCLI.parse([command, "--non-interactive", "--json"])
            XCTAssertTrue(request.options.isEmpty)
        }
    }

    func testInstalledComputerUseDoesNotBlockOnUnverifiableExternalPermissions() {
        let installed = SteveControl.computerUseChecks(installed: true)
        XCTAssertEqual(SteveControl.readiness(installed), "ready")
        XCTAssertEqual(installed.first?.state, "ready")
        XCTAssertEqual(installed.last?.state, "unverified")
        XCTAssertEqual(installed.last?.required, false)
        XCTAssertEqual(SteveControl.readiness(SteveControl.computerUseChecks(installed: false)), "needs_user_action")
        XCTAssertEqual(SteveControl.readiness(installed + [SteveSetupCheck(name: "messages", state: "blocked", detail: "fixture")]), "blocked")
    }

    func testMessagesDiagnosticsPreserveFailureAndDistinguishAccountAndPermission() {
        let permission = MessagesService.databaseError(IMsgError.permissionDenied(path: "/fixture/chat.db", underlying: SQLite.Result.error(message: "authorization denied", code: 23, statement: nil)))
        let denied = SteveControl.messagesCheck(accounts: .failure(permission), watcher: nil)
        XCTAssertEqual(denied.state, "needs_user_action")
        XCTAssertTrue(denied.detail.contains("--open-permission full-disk-access"))
        let database = MessagesService.databaseError(IMsgError.permissionDenied(path: "/fixture/missing.db", underlying: SQLite.Result.error(message: "unable to open database file", code: 14, statement: nil)))
        if case .permission = database { XCTFail("A missing file is not proof of a permission denial") }
        let failed = SteveControl.messagesCheck(accounts: .failure(database), watcher: nil)
        XCTAssertEqual(failed.state, "blocked")
        XCTAssertTrue(failed.detail.contains("unable to open database file"))
        let corrupt = MessagesService.databaseError(SQLite.Result.error(message: "database disk image is malformed", code: 11, statement: nil))
        XCTAssertTrue(SteveControl.messagesCheck(accounts: .failure(corrupt), watcher: nil).detail.contains("database disk image is malformed"))
        let empty = SteveControl.messagesCheck(accounts: .success([]), watcher: nil)
        XCTAssertEqual(empty.state, "needs_user_action")
        XCTAssertTrue(empty.detail.contains("sign in"))
        let accounts = [MessagesAccount(address: "fixture@example.test", label: nil)]
        let stopped = SteveControl.messagesCheck(accounts: .success(accounts), watcher: Dependency(name: "messages", available: false, detail: "fixture watcher failure"))
        XCTAssertEqual(stopped.state, "blocked"); XCTAssertTrue(stopped.detail.contains("fixture watcher failure"))
        XCTAssertEqual(SteveControl.messagesCheck(accounts: .success(accounts), watcher: nil).state, "ready")
    }
}
