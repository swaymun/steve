import AppKit
import ApplicationServices
import Darwin
import Foundation

struct SteveControlRequest: Codable, Sendable {
    let command: String
    var options: [String: String] = [:]
}

struct SteveSetupCheck: Codable, Sendable {
    let name: String
    let state: String
    let detail: String
    var required: Bool = true
}

struct SteveControlResponse: Codable, Sendable {
    let state: String
    let summary: String
    var checks: [SteveSetupCheck] = []
    var values: [String: String] = [:]
    var tasks: [OperatorTaskSummary]? = nil
}

/// Local CLI requests execute inside the user-session app, which owns TCC
/// permissions and the single gateway. The CLI never opens the Messages DB.
enum SteveControl {
    static func handle(_ request: SteveControlRequest, runtime: SteveRuntime,
                       openPermission: @MainActor (StevePermissionTarget) -> SteveControlResponse = { StevePermissionSettings.open($0) }) async -> SteveControlResponse {
        var applied: [String] = []
        do {
            var values: [String: String] = [:]
            switch request.command {
            case "status": break
            case "doctor": try await runtime.refresh()
            case "approval":
                if let approval = await runtime.pendingApproval() {
                    return SteveControlResponse(state: "needs_user_action", summary: approval.message, values: [
                        "approvalID": approval.id,
                        "originHost": approval.originHost ?? "",
                        "connector": approval.connector ?? "",
                        "tool": approval.tool ?? "",
                        "expiresAt": ISO8601DateFormatter().string(from: approval.expiresAt)
                    ])
                }
                return SteveControlResponse(state: "ready", summary: "No approval is pending.")
            case "approve", "deny":
                guard let id = request.options["id"], request.options.count == 1 else { throw RPCError(message: "Specify the current approval ID from the approval command.") }
                try await runtime.resolveApproval(id: id, decision: request.command == "approve" ? .accept : .decline)
            case "start": try await runtime.setPaused(false)
            case "stop": try await runtime.setPaused(true)
            case "setup":
                let agentOptions: Set<String> = ["model", "effort", "service-tier", "relay-model", "relay-effort", "relay-service-tier", "max-operators", "max-helpers"]
                let allowed = Set(["workspace", "permission", "login", "pair", "tailscale-connect", "phone-access", "open-permission"])
                    .union(agentOptions)
                guard Set(request.options.keys).isSubset(of: allowed) else {
                    throw RPCError(message: "Unknown setup option; no changes were applied.")
                }
                if let name = request.options["open-permission"] {
                    guard let target = StevePermissionTarget(rawValue: name), request.options.count == 1 else {
                        throw RPCError(message: "Use one supported --open-permission target separately from other setup options; no changes were applied.")
                    }
                    return await openPermission(target)
                }
                // Validate configuration choices before applying them. Account
                // sign-in and pairing are resumable steps, not one transaction.
                let snapshot = await runtime.snapshot()
                if let value = request.options["permission"], !["read-only", "workspace-write", "danger-full-access"].contains(value) {
                    throw RPCError(message: "Choose read-only, workspace-write, or danger-full-access.")
                }
                if let value = request.options["model"], !snapshot.models.contains(where: { $0.id == value }) {
                    throw RPCError(message: "Model is not in the signed-in account's current catalog.")
                }
                if let value = request.options["service-tier"], SteveServiceTier(rawValue: value) == nil {
                    throw RPCError(message: "Choose standard or fast for service tier.")
                }
                let selected = request.options["model"] ?? snapshot.settings.model
                if let value = request.options["effort"], !snapshot.models.contains(where: { $0.id == selected && $0.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == value }) }) {
                    throw RPCError(message: "Reasoning effort is not supported by the selected model.")
                }
                if let value = request.options["relay-model"], value != "auto", !snapshot.models.contains(where: { $0.id == value }) {
                    throw RPCError(message: "Relay model is not in the signed-in account's current catalog.")
                }
                if let value = request.options["relay-service-tier"], SteveServiceTier(rawValue: value) == nil {
                    throw RPCError(message: "Choose standard or fast for relay service tier.")
                }
                let requestedRelay = request.options["relay-model"]
                let relaySelected = requestedRelay == "auto" ? nil : (requestedRelay ?? snapshot.settings.relayModel)
                let relayEffective = relaySelected ?? (snapshot.models.contains(where: { $0.id == "gpt-5.6-luna" }) ? "gpt-5.6-luna" : selected)
                if let value = request.options["relay-effort"], !snapshot.models.contains(where: { $0.id == relayEffective && $0.supportedReasoningEfforts.contains(where: { $0.reasoningEffort == value }) }) {
                    throw RPCError(message: "Relay reasoning effort is not supported by the selected relay model.")
                }
                if let value = request.options["max-operators"], Int(value).map({ (1...4).contains($0) }) != true {
                    throw RPCError(message: "Maximum operators must be an integer from 1 through 4.")
                }
                if let value = request.options["max-helpers"], Int(value).map({ (0...2).contains($0) }) != true {
                    throw RPCError(message: "Maximum helpers must be an integer from 0 through 2.")
                }
                if let value = request.options["workspace"] {
                    guard value.hasPrefix("/"), !value.contains("\0") else { throw RPCError(message: "Workspace must be an absolute path.") }
                }
                if let value = request.options["workspace"] { try await runtime.configureWorkspace(value); applied.append("workspace") }
                if let value = request.options["permission"] { try await runtime.selectPermission(value); applied.append("permission") }
                let requestedAgentOptions = request.options.filter { agentOptions.contains($0.key) }
                if !requestedAgentOptions.isEmpty {
                    try await runtime.configureAgentSettings(options: requestedAgentOptions)
                    applied.append(contentsOf: requestedAgentOptions.keys.sorted())
                }
                if request.options["login"] == "true" {
                    let login = try await runtime.loginStart()
                    values["authURL"] = login.authURL
                }
                if request.options["pair"] == "true" {
                    let pair = try await runtime.createPairing()
                    values["pairingCode"] = pair.challenge?.code
                    values["messagesURL"] = pair.challenge?.messageURI
                    values["receiveAddress"] = pair.challenge?.receiveAddress
                }
            default: throw RPCError(message: "Unsupported control command.")
            }
            let snapshot = await runtime.snapshot()
            var checks = [
                SteveSetupCheck(name: "codex_account", state: snapshot.status.connected ? "ready" : "needs_user_action", detail: snapshot.status.connected ? "Codex account connected." : "Run setup --login, then finish the returned URL in your browser."),
                SteveSetupCheck(name: "workspace", state: snapshot.settings.workspaceRoot == nil ? "needs_user_action" : "ready", detail: snapshot.settings.workspaceRoot ?? "Choose a workspace with setup --workspace /absolute/path."),
                SteveSetupCheck(name: "permissions", state: snapshot.settings.permissionProfile == nil ? "needs_user_action" : "ready", detail: snapshot.settings.permissionProfile ?? "Choose setup --permission read-only, workspace-write, or danger-full-access."),
                SteveSetupCheck(name: "phone", state: snapshot.trustedConversation == nil ? "needs_user_action" : "ready", detail: snapshot.trustedConversation == nil ? "Run setup --pair and send the displayed code from the phone." : "An exact private Messages conversation is paired."),
                SteveSetupCheck(name: "operator", state: snapshot.paused ? "blocked" : "ready", detail: snapshot.paused ? "Paused. Run start to resume." : "Enabled.")
            ]
            let diagnostics = request.command == "doctor" || request.command == "setup"
            for dependency in snapshot.dependencies where !diagnostics || dependency.name != "messages" {
                checks.append(SteveSetupCheck(name: dependency.name, state: dependency.available ? "ready" : "blocked", detail: dependency.detail))
            }
            if snapshot.status.state != "Ready", !snapshot.paused,
               !checks.contains(where: { $0.detail == snapshot.status.detail }),
               !(diagnostics && snapshot.dependencies.contains(where: { $0.name == "messages" && $0.detail == snapshot.status.detail })) {
                checks.append(SteveSetupCheck(name: "runtime", state: "needs_user_action", detail: snapshot.status.detail))
            }
            if diagnostics {
                let network = await TailscaleSetup.check(connect: request.options["tailscale-connect"] == "true")
                checks.append(network.0)
                values["tailscaleAuthURL"] = network.1
                checks.append(contentsOf: computerUseChecks(installed: CodexComputerUseRuntime.discover() != nil))
                let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") != nil
                checks.append(SteveSetupCheck(name: "chrome", state: chrome ? "ready" : "needs_user_action", detail: chrome ? "Google Chrome installed; its existing profile is used." : "Install Google Chrome for browser tasks."))
                checks.append(SteveSetupCheck(name: "steve_screen_recording", state: CGPreflightScreenCaptureAccess() ? "ready" : "needs_user_action", detail: "Steve's own Screen Recording grant is optional for video evidence and phone takeover. This does not check Computer Use's separate grant. Open with setup --open-permission steve-screen-recording.", required: false))
                checks.append(SteveSetupCheck(name: "steve_accessibility", state: AXIsProcessTrusted() ? "ready" : "needs_user_action", detail: "Steve's own Accessibility grant is optional for phone input. This does not check the native Computer Use app's grant. Open with setup --open-permission steve-accessibility.", required: false))
                let accounts: Result<[MessagesAccount], Error>
                do { accounts = .success(try await runtime.messages.discoverAccounts()) }
                catch { accounts = .failure(error) }
                checks.append(messagesCheck(accounts: accounts, watcher: snapshot.dependencies.first { $0.name == "messages" }))
            }
            let state = readiness(checks)
            values.merge([
                "relayModel": snapshot.settings.relayModel ?? "auto",
                "relayEffort": snapshot.settings.relayEffort,
                "relayServiceTier": snapshot.settings.relayServiceTier.rawValue,
                "operatorModel": snapshot.settings.model,
                "operatorEffort": snapshot.settings.effort,
                "operatorServiceTier": snapshot.settings.serviceTier.rawValue,
                "maxOperators": String(snapshot.settings.maxConcurrentOperators),
                "maxHelpers": String(snapshot.settings.maxHelpersPerOperator),
                "nativeHelpers": snapshot.nativeHelpersAvailable.map { $0 ? "available" : "unavailable" } ?? "unverified"
            ]) { _, current in current }
            return SteveControlResponse(state: state, summary: snapshot.status.detail.isEmpty ? (snapshot.paused ? "Steve is paused." : "Steve is running.") : snapshot.status.detail, checks: checks, values: values, tasks: snapshot.tasks)
        } catch {
            return SteveControlResponse(state: "failed", summary: error.localizedDescription, values: applied.isEmpty ? [:] : ["applied": applied.joined(separator: ","), "nextStep": "These settings were saved before the later step failed. Run status and resume the remaining setup step."])
        }
    }

    static func readiness(_ checks: [SteveSetupCheck]) -> String {
        checks.contains(where: { $0.required && $0.state == "blocked" }) ? "blocked" :
            checks.contains(where: { $0.required && $0.state != "ready" }) ? "needs_user_action" : "ready"
    }

    static func computerUseChecks(installed: Bool) -> [SteveSetupCheck] {
        [SteveSetupCheck(name: "computer_use", state: installed ? "ready" : "needs_user_action",
                         detail: installed ? "Native Computer Use is installed. Its permissions and live session are checked separately."
                            : "Install and enable native Computer Use through Codex. No Chrome extension is needed."),
         SteveSetupCheck(name: "computer_use_live", state: "unverified",
                         detail: "Steve cannot inspect another app's permissions. After pairing, enable Computer Use's Screen Recording and Accessibility, then ask Steve: Open example.com and tell me the heading. Verify the actual browser result; repeating doctor will not verify this check.", required: false)]
    }

    static func messagesCheck(accounts: Result<[MessagesAccount], Error>, watcher: Dependency?) -> SteveSetupCheck {
        switch accounts {
        case .success(let accounts):
            if accounts.isEmpty {
                return SteveSetupCheck(name: "messages", state: "needs_user_action", detail: "Open Messages and sign in on Steve's Mac using the separate Messages account described in guide/setup.md.")
            }
            if let watcher, !watcher.available {
                return SteveSetupCheck(name: "messages", state: "blocked", detail: "The Messages database is readable, but its watcher is unavailable: \(watcher.detail) Relaunch Steve, then run doctor again.")
            }
            return SteveSetupCheck(name: "messages", state: "ready", detail: "Messages database is readable and a local account was discovered. Confirm the receiving account in Messages. Sending Automation permission is verified by your pairing reply or another authorized live reply.")
        case .failure(let error):
            if case MessagesService.ServiceError.permission = error {
                return SteveSetupCheck(name: "messages", state: "needs_user_action", detail: "Run setup --open-permission full-disk-access, enable Steve, then relaunch it and run doctor again.")
            }
            return SteveSetupCheck(name: "messages", state: "blocked", detail: "Messages database could not be read: \(error.localizedDescription) Open Messages and check its account, then run doctor again. If macOS denied access, use setup --open-permission full-disk-access.")
        }
    }
}

enum SteveControlSocket {
    static var directory: URL { StevePaths.dataDirectory.appendingPathComponent("control", isDirectory: true) }
    static var path: String { directory.appendingPathComponent("socket").path }
    static let maxBytes = 65_536

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RPCError(message: "Local control socket path is too long.") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func configure(_ fd: Int32) {
        var timeout = timeval(tv_sec: 75, tv_usec: 0)
        withUnsafePointer(to: &timeout) {
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var enabled: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    static func read(_ fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count == 0 { return result }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw RPCError(message: "Local request timed out or disconnected. A requested change may have completed; check status before retrying.")
            }
            guard result.count + count <= maxBytes else { throw RPCError(message: "Local request exceeded the size limit.") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func write(_ data: Data, fd: Int32) throws {
        guard data.count <= maxBytes else { throw RPCError(message: "Local response exceeded the size limit.") }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { if errno == EINTR { continue }; throw RPCError(message: "Local connection closed.") }
                offset += count
            }
        }
    }

    static func request(_ request: SteveControlRequest, path: String = path) throws -> SteveControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RPCError(message: "Could not open local control socket.") }
        defer { close(fd) }
        configure(fd)
        var address = try address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw RPCError(message: "Steve is not running. Open the installed Steve.app, then retry. CLI commands use its permissions and existing session.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw RPCError(message: "Local control peer is not the current user.") }
        try write(JSONEncoder().encode(request), fd: fd)
        shutdown(fd, SHUT_WR)
        return try JSONDecoder().decode(SteveControlResponse.self, from: read(fd))
    }
}

final class SteveLocalControlServer: @unchecked Sendable {
    private let listener: Int32
    private let ownership: Int32
    private let path: String

    init(path: String = SteveControlSocket.path, handler: @escaping @Sendable (SteveControlRequest) async -> SteveControlResponse) throws {
        self.path = path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: parent.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700 else {
            throw RPCError(message: "Local control directory must be owned by this user with permissions 0700.")
        }
        ownership = open(parent.appendingPathComponent("lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard ownership >= 0 else { throw RPCError(message: "Could not lock local control endpoint.") }
        guard flock(ownership, LOCK_EX | LOCK_NB) == 0 else { close(ownership); throw RPCError(message: "Steve is already running for this user.") }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { close(ownership); throw RPCError(message: "Could not create local control endpoint.") }
        do {
            var address = try SteveControlSocket.address(path)
            unlink(path)
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else { throw RPCError(message: "Could not listen on local control endpoint.") }
        } catch { close(listener); close(ownership); throw error }
        let fd = listener
        DispatchQueue(label: "steve.local-control").async {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { if errno == EINTR { continue }; return }
                SteveControlSocket.configure(client)
                var uid: uid_t = 0, gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
                // Serialize reads with a deadline, then let actor isolation handle
                // execution. No shell commands or arbitrary paths are dispatched.
                do {
                    let request = try JSONDecoder().decode(SteveControlRequest.self, from: SteveControlSocket.read(client))
                    Task {
                        defer { close(client) }
                        let response = await handler(request)
                        if let data = try? JSONEncoder().encode(response) { try? SteveControlSocket.write(data, fd: client) }
                    }
                } catch { close(client) }
            }
        }
    }

    deinit { shutdown(listener, SHUT_RDWR); close(listener); unlink(path); close(ownership) }
}
