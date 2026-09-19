import Foundation
import Darwin

/// Bounded, non-shell invocation. Output is kept in memory and never logged.
/// Used for optional onboarding tools, not for the supervised Codex process.
enum SteveProcess {
    struct Result: Sendable { let code: Int32; let output: Data }

    static func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval = 10) async throws -> Result {
        let lifetime = ProcessLifetime()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do { continuation.resume(returning: try runBlocking(executable: executable, arguments: arguments, environment: environment, timeout: timeout, lifetime: lifetime)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: { lifetime.cancel() }
    }

    private static func runBlocking(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval, lifetime: ProcessLifetime) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }
        try lifetime.launch(process)
        let output = BoundedProcessOutput()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            defer { drained.signal() }
            while let data = try? pipe.fileHandleForReading.read(upToCount: 8192), !data.isEmpty {
                if !output.append(data) { lifetime.cancel(); break }
            }
        }
        guard ended.wait(timeout: .now() + timeout) == .success else {
            lifetime.cancel()
            try? pipe.fileHandleForReading.close()
            throw RPCError(message: "The setup command timed out. Check its current status before retrying.")
        }
        guard drained.wait(timeout: .now() + 1) == .success, !output.overflowed else {
            try? pipe.fileHandleForReading.close()
            throw RPCError(message: "Setup output was incomplete or too large.")
        }
        try? pipe.fileHandleForReading.close()
        try lifetime.checkCancellation()
        return Result(code: process.terminationStatus, output: output.data)
    }
}

private final class ProcessLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    func launch(_ process: Process) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        self.process = process
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        if let process, process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    func checkCancellation() throws {
        lock.lock(); defer { lock.unlock() }
        if cancelled { throw CancellationError() }
    }
}

private final class BoundedProcessOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    private var overflow = false
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
    var overflowed: Bool { lock.lock(); defer { lock.unlock() }; return overflow }
    func append(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard storage.count + data.count <= 1_048_576 else { overflow = true; return false }
        storage.append(data); return true
    }
}

enum TailscaleSetup {
    struct NetworkStatus: Decodable {
        let BackendState: String
        let AuthURL: String?
        let TailscaleIPs: [String]?
    }

    static func executable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let candidates = [
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
            home.appendingPathComponent("Applications/Tailscale.app/Contents/MacOS/Tailscale").path,
            "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    static func check(connect: Bool = false) async -> (SteveSetupCheck, String?) {
        guard let executable = executable() else {
            return (SteveSetupCheck(name: "tailscale", state: "needs_user_action", detail: "Optional for phone browser access. Install the standalone macOS app from https://tailscale.com/download/mac, then approve its VPN setup and sign in to your own account. Install Tailscale on the phone too.", required: false), nil)
        }
        var environment = CodexComputerUseRuntime.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        environment["TAILSCALE_BE_CLI"] = "1"
        do {
            var connectCode: Int32?
            if connect {
                // No reset, account switch, auth key, ACL, Serve or Funnel changes.
                // Existing nondefault flags cause Tailscale to refuse rather than
                // silently reset them; the user can finish in its native app.
                connectCode = try await SteveProcess.run(executable: executable, arguments: ["up", "--timeout=5s"], environment: environment, timeout: 8).code
            }
            let result = try await SteveProcess.run(executable: executable, arguments: ["status", "--json"], environment: environment, timeout: 5)
            let status = try JSONDecoder().decode(NetworkStatus.self, from: result.output)
            let running = status.BackendState == "Running" && !(status.TailscaleIPs?.isEmpty ?? true)
            let detail = connectCode != nil && connectCode != 0 && !running ? "Tailscale did not finish connecting. Open its app to finish authentication or review the existing network configuration, then retry doctor." : running ? "Tailscale is connected. Phone access also needs the phone signed in and a configured private HTTPS route." : "Tailscale is \(status.BackendState). Open its app to finish VPN/account setup, or run setup --tailscale-connect. Existing account and routing settings are preserved."
            let authURL = status.AuthURL.flatMap { raw -> String? in
                guard let url = URL(string: raw), url.scheme == "https", url.host == "login.tailscale.com" else { return nil }
                return raw
            }
            return (SteveSetupCheck(name: "tailscale", state: running ? "ready" : "needs_user_action", detail: detail, required: false), authURL)
        } catch {
            return (SteveSetupCheck(name: "tailscale", state: "needs_user_action", detail: "Tailscale is installed but its service could not be checked. Open Tailscale and finish setup, then retry doctor. No settings were reset.", required: false), nil)
        }
    }
}

extension TailscaleSetup {
    struct PhoneRoute: Sendable {
        let origin: PhoneTakeoverOrigin
        let localPort: Int
        var httpsPort: Int { URL(string: origin.value)?.port ?? 443 }
        var address: String { origin.host + ":\(httpsPort)" }
        var target: String { "http://127.0.0.1:\(localPort)" }
    }

    private struct ServeConfiguration: Decodable {
        struct TCPEntry: Decodable { let HTTPS: Bool? }
        struct WebEntry: Decodable {
            struct Handler: Decodable { let Proxy: String? }
            let Handlers: [String: Handler]
        }
        let TCP: [String: TCPEntry]?
        let Web: [String: WebEntry]?
        let AllowFunnel: [String: Bool]?
    }

    private static func command(_ arguments: [String]) async throws -> SteveProcess.Result {
        guard let executable = executable() else { throw RPCError(message: "Install and sign in to the standalone Tailscale app first.") }
        var environment = CodexComputerUseRuntime.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        environment["TAILSCALE_BE_CLI"] = "1"
        return try await SteveProcess.run(executable: executable, arguments: arguments, environment: environment, timeout: 12)
    }

    static func phoneRoute(existingOrigin: String?, existingPort: Int?) async throws -> PhoneRoute {
        struct Status: Decodable {
            struct Device: Decodable { let DNSName: String }
            let BackendState: String
            let device: Device?
            enum CodingKeys: String, CodingKey { case BackendState; case device = "Self" }
        }
        let statusResult = try await command(["status", "--json"])
        let status = try JSONDecoder().decode(Status.self, from: statusResult.output)
        guard statusResult.code == 0, status.BackendState == "Running", let name = status.device?.DNSName else {
            throw RPCError(message: "Connect Tailscale on this Mac and your phone, then retry setup --phone-access.")
        }
        let host = name.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
        guard host.hasSuffix(".ts.net") else { throw RPCError(message: "Tailscale has no private HTTPS hostname. Enable MagicDNS and HTTPS in your tailnet, then retry.") }
        let state = try await command(["serve", "status", "--json"])
        guard state.code == 0 else { throw RPCError(message: "Could not inspect Tailscale Serve. Existing routes were preserved.") }
        return try selectPhoneRoute(host: host, serveJSON: state.output, existingOrigin: existingOrigin, existingPort: existingPort)
    }

    static func selectPhoneRoute(host: String, serveJSON: Data, existingOrigin: String?, existingPort: Int?) throws -> PhoneRoute {
        let config = try JSONDecoder().decode(ServeConfiguration.self, from: serveJSON)
        let localPort = existingPort ?? 19887
        guard (1024...65535).contains(localPort) else { throw RPCError(message: "The saved phone access port is invalid.") }
        if let existingOrigin {
            let origin = try PhoneTakeoverOrigin(existingOrigin)
            guard origin.host == host else { throw RPCError(message: "The Tailscale account or hostname changed. Review phone access on the Mac before reconfiguring it.") }
            let route = PhoneRoute(origin: origin, localPort: localPort)
            try requireAvailableOrOwned(route, config: config)
            return route
        }
        for port in [8443, 10000] {
            let route = PhoneRoute(origin: try PhoneTakeoverOrigin("https://\(host):\(port)"), localPort: localPort)
            if config.TCP?[String(port)] == nil, config.Web?[route.address] == nil, config.AllowFunnel?[route.address] != true { return route }
        }
        throw RPCError(message: "Tailscale ports 8443 and 10000 are already in use. Existing routes were preserved; free one of these ports before configuring Steve.")
    }

    private static func requireAvailableOrOwned(_ route: PhoneRoute, config: ServeConfiguration) throws {
        guard config.AllowFunnel?[route.address] != true else { throw RPCError(message: "Phone access requires private Tailscale Serve. Funnel is enabled for this address; review it in Tailscale before continuing.") }
        if config.TCP?[String(route.httpsPort)] == nil, config.Web?[route.address] == nil { return }
        guard config.TCP?[String(route.httpsPort)]?.HTTPS == true,
              let handlers = config.Web?[route.address]?.Handlers, handlers.count == 1,
              handlers["/"]?.Proxy == route.target else {
            throw RPCError(message: "Another service owns this Tailscale address. Existing routes were preserved.")
        }
    }

    static func verifyPhoneRoute(_ route: PhoneRoute) async throws {
        let state = try await command(["serve", "status", "--json"])
        guard state.code == 0 else { throw RPCError(message: "Could not inspect the private phone route.") }
        let config = try JSONDecoder().decode(ServeConfiguration.self, from: state.output)
        try requireAvailableOrOwned(route, config: config)
        guard config.Web?[route.address]?.Handlers["/"]?.Proxy == route.target else {
            throw RPCError(message: "The phone route is not configured. Run setup --phone-access to configure it.")
        }
    }

    static func enablePhoneRoute(_ route: PhoneRoute) async throws {
        // Recheck immediately before the scoped mutation. Never reset Serve,
        // alter an existing unrelated path, or turn on public Funnel.
        let before = try await command(["serve", "status", "--json"])
        guard before.code == 0 else { throw RPCError(message: "Could not inspect Tailscale Serve.") }
        let config = try JSONDecoder().decode(ServeConfiguration.self, from: before.output)
        try requireAvailableOrOwned(route, config: config)
        if config.Web?[route.address]?.Handlers["/"]?.Proxy != route.target {
            let result = try await command(["serve", "--bg", "--yes", "--https=\(route.httpsPort)", route.target])
            guard result.code == 0 else { throw RPCError(message: "Tailscale could not enable private HTTPS. Finish HTTPS setup in Tailscale, then retry. Existing routes were preserved.") }
        }
        try await verifyPhoneRoute(route)
    }
}
