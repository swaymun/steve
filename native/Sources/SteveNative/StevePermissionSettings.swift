import AppKit
import Foundation

enum StevePermissionTarget: String, CaseIterable, Sendable {
    case fullDiskAccess = "full-disk-access"
    case messagesAutomation = "messages-automation"
    case computerUseScreenRecording = "computer-use-screen-recording"
    case computerUseAccessibility = "computer-use-accessibility"
    case steveScreenRecording = "steve-screen-recording"
    case steveAccessibility = "steve-accessibility"

    var isComputerUse: Bool { self == .computerUseScreenRecording || self == .computerUseAccessibility }
    var pane: String {
        switch self {
        case .fullDiskAccess: return "Privacy_AllFiles"
        case .messagesAutomation: return "Privacy_Automation"
        case .computerUseScreenRecording, .steveScreenRecording: return "Privacy_ScreenCapture"
        case .computerUseAccessibility, .steveAccessibility: return "Privacy_Accessibility"
        }
    }
    var paneName: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .messagesAutomation: return "Automation"
        case .computerUseScreenRecording, .steveScreenRecording: return "Screen Recording (Screen & System Audio Recording on newer macOS)"
        case .computerUseAccessibility, .steveAccessibility: return "Accessibility"
        }
    }
}

enum StevePermissionSettings {
    /// Runs inside the installed app, never a separate CLI permission owner.
    /// Opening Settings requests a human handoff; it does not grant access.
    @MainActor
    static func open(
        _ target: StevePermissionTarget,
        steveAppURL: URL = Bundle.main.bundleURL,
        computerUseAppURL: URL? = CodexComputerUseRuntime.discover()?.appURL,
        openURL: (URL) -> Bool = { NSWorkspace.shared.open($0) },
        revealApp: (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    ) -> SteveControlResponse {
        let appURL = target.isComputerUse ? computerUseAppURL : steveAppURL
        guard let appURL, let bundle = Bundle(url: appURL), appURL.pathExtension == "app" else {
            let next = target.isComputerUse
                ? "Install and enable native Computer Use through Codex, then retry this command. No Chrome extension is needed."
                : "Install and launch Steve.app, then use its installed CLI."
            return SteveControlResponse(state: "needs_user_action", summary: next, values: ["permissionTarget": target.rawValue, "settingsOpened": "false", "nextStep": next])
        }
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent
        let next: String
        if target == .messagesAutomation {
            next = "In Automation, enable Messages under \(appName). If it is not listed, finish iMessage pairing and allow the macOS prompt for Steve's pairing reply. This command does not send a message."
        } else {
            next = "Enable \(appName) in \(target.paneName). If it is missing, use + to add \(appURL.path). Relaunch \(appName) if macOS requests it\(target == .fullDiskAccess ? "; relaunch Steve after granting Full Disk Access" : ""), then run steve doctor --json."
            revealApp(appURL)
        }
        let urls = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(target.pane)",
            "x-apple.systempreferences:com.apple.preference.security?\(target.pane)"
        ]
        let opened = urls.contains { openURL(URL(string: $0)!) }
        let navigation = "System Settings → Privacy & Security → \(target.paneName)"
        return SteveControlResponse(
            state: "needs_user_action",
            summary: (opened ? "Requested opening \(navigation). " : "Open \(navigation) manually. ") + next,
            values: ["permissionTarget": target.rawValue, "appName": appName, "appPath": appURL.path,
                     "settingsOpened": String(opened), "nextStep": next]
        )
    }
}
