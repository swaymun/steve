import Foundation

struct SetupReadiness: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case refresh, signIn, chooseWorkspace, choosePermissions, openFullDiskAccess
        case connectPhone, openComputerUseGuide, resume, copyLiveCheck, diagnostics
    }

    let title: String
    let detail: String
    let actionTitle: String
    let action: Action

    static func evaluate(snapshot: Snapshot?, computerUseInstalled: Bool) -> SetupReadiness {
        guard let snapshot else {
            return .init(title: "Checking setup", detail: "Reading the current configuration.", actionTitle: "Refresh", action: .refresh)
        }
        if snapshot.dependencies.first(where: { $0.name == "codex" })?.available == false {
            return .init(title: "Codex unavailable", detail: "Open diagnostics to inspect the installed Codex connection.", actionTitle: "Open Diagnostics", action: .diagnostics)
        }
        if snapshot.account?.account == nil || !snapshot.status.connected {
            return .init(title: "Finish Codex sign-in", detail: "Steve uses the Codex account on this Mac.", actionTitle: "Sign In", action: .signIn)
        }
        if snapshot.settings.workspaceRoot == nil {
            return .init(title: "Choose a workspace", detail: "Select the folder Steve may use for task files.", actionTitle: "Choose Workspace", action: .chooseWorkspace)
        }
        if snapshot.settings.permissionProfile == nil {
            return .init(title: "Choose access", detail: "Select how much access Steve should have for tasks.", actionTitle: "Choose Permissions", action: .choosePermissions)
        }
        if let messages = snapshot.dependencies.first(where: { $0.name == "messages" }), !messages.available {
            let permissionFailure = messages.detail.localizedCaseInsensitiveContains("permission") || messages.detail.localizedCaseInsensitiveContains("denied")
            return permissionFailure
                ? .init(title: "Allow Messages access", detail: "Grant Steve Full Disk Access, then relaunch it.", actionTitle: "Open Full Disk Access", action: .openFullDiskAccess)
                : .init(title: "Messages needs attention", detail: "Open diagnostics for the current Messages error.", actionTitle: "Open Diagnostics", action: .diagnostics)
        }
        if snapshot.trustedConversation == nil {
            if let owner = snapshot.ownerSetup {
                return .init(title: "Send your first message", detail: "From \(owner.address), text \(owner.receiveAddress). A greeting or a task connects you; no code is needed.", actionTitle: "Connection Details", action: .connectPhone)
            }
            return .init(title: "Choose your iMessage address", detail: "Only this owner will be allowed to send tasks.", actionTitle: "Connect iMessage", action: .connectPhone)
        }
        if !computerUseInstalled {
            return .init(title: "Enable Computer Use", detail: "Install native Computer Use through Codex for browser and app tasks.", actionTitle: "Open Setup Guide", action: .openComputerUseGuide)
        }
        if snapshot.paused {
            return .init(title: "Steve is paused", detail: "Configuration is complete. Resume when you want Steve to accept tasks.", actionTitle: "Resume Steve", action: .resume)
        }
        return .init(
            title: "Configuration ready",
            detail: "Live acceptance is separate. Send the browser check from the paired conversation and verify the observed result.",
            actionTitle: "Copy Browser Check",
            action: .copyLiveCheck
        )
    }
}
