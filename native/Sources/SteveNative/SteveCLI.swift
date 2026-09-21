import Foundation

/// Public names map to the existing storage and control protocol keys.
enum SteveSetupOptions {
    static let aliases = [
        "coordinator-model": "relay-model", "coordinator-effort": "relay-effort",
        "coordinator-service-tier": "relay-service-tier", "worker-model": "model",
        "worker-effort": "effort", "worker-service-tier": "service-tier",
        "max-workers": "max-operators"
    ]

    static func canonical(_ key: String) -> String { aliases[key] ?? key }

    static func normalize(_ options: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for key in options.keys.sorted() {
            let name = canonical(key)
            guard result[name] == nil else {
                throw RPCError(message: "Specify each setup choice only once, including legacy aliases; no changes were applied.")
            }
            result[name] = options[key]
        }
        return result
    }
}

enum SteveCLI {
    static let help = """
    Usage: steve setup|doctor|status|start|stop [--json] [--non-interactive]
      steve approval [--json]
      steve approve|deny APPROVAL_ID [--json]
      steve phone [--disconnect] [--json]
      steve video windows --app BUNDLE_ID [--json]
      steve video start --demonstration --window ID --app BUNDLE_ID [--seconds 30] [--max-mib 24] [--json]
      steve video start --demonstration --display ID [--audio] [--seconds 30] [--max-mib 24] [--json]
      steve video stop RECORDING_ID [--json]
      steve video cancel [--json]
      setup [--workspace /absolute/path] [--permission PROFILE]
            [--owner ADDRESS] [--agent-name NAME] [--personality TEXT]
            [--worker-model ID] [--worker-effort EFFORT] [--worker-service-tier standard|fast]
            [--coordinator-model auto|ID] [--coordinator-effort EFFORT] [--coordinator-service-tier standard|fast]
            [--max-workers 1...4] [--max-helpers 0...2]
            [--login] [--pair] [--tailscale-connect] [--phone-access]
      setup --open-permission TARGET [--json] [--non-interactive]
        TARGET: full-disk-access, messages-automation,
                computer-use-screen-recording, computer-use-accessibility,
                steve-screen-recording, steve-accessibility

    Open Steve.app first. Commands use the running app's permissions and session.
    setup applies only explicit choices. --login returns the official sign-in URL;
    --owner ADDRESS allows one owner's iMessage address; send a normal message to connect.
    --agent-name NAME and --personality TEXT customize the assistant (optional).
    --pair is the legacy one-time-code fallback. These do not bypass human login
    or macOS permission prompts. --non-interactive never waits for terminal input.
    --open-permission opens Settings for a human grant; use it separately from
    other setup options. Ordinary setup and doctor do not open Settings.
    --max-helpers sets research helpers per eligible worker. Only one worker controls
    the visible Mac at a time. setup/doctor/status JSON includes the model catalog.
    Legacy --model, --effort, --service-tier, --relay-* and --max-operators flags
    remain supported. Do not combine aliases for the same choice.
    start resumes work; stop pauses and cancels it. It does not quit the app.
    JSON states: ready, needs_user_action, blocked, failed. Exit: 0 ready, 2 attention,
    1 error. Do not share setup output containing a live pairing code.
    """

    static func parse(_ arguments: [String]) throws -> (SteveControlRequest, Bool, Bool) {
        guard let command = arguments.first, ["setup", "doctor", "status", "start", "stop", "approval", "approve", "deny", "phone", "video"].contains(command) else {
            throw RPCError(message: help)
        }
        var request = SteveControlRequest(command: command)
        var json = false, interactive = true
        var index = 1
        if command == "video" {
            guard arguments.count > 1, ["windows", "start", "stop", "cancel"].contains(arguments[1]) else { throw RPCError(message: "Choose video windows, start, stop, or cancel.") }
            request.options["action"] = arguments[1]
            index = 2
            if arguments[1] == "stop" {
                guard arguments.count > 2, UUID(uuidString: arguments[2]) != nil else { throw RPCError(message: "Specify the recording ID returned by video start.") }
                request.options["id"] = arguments[2]
                index = 3
            }
        }
        if command == "approve" || command == "deny" {
            guard arguments.count > 1, !arguments[1].hasPrefix("--") else { throw RPCError(message: "Specify the current approval ID from steve approval.") }
            request.options["id"] = arguments[1]
            index = 2
        }
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--json": json = true; interactive = false
            case "--non-interactive": interactive = false
            case "--owner", "--agent-name", "--personality":
                guard command == "setup", index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--"), request.options[String(arg.dropFirst(2))] == nil else {
                    throw RPCError(message: "\(arg) requires one value on setup.")
                }
                index += 1
                request.options[String(arg.dropFirst(2))] = arguments[index]
            case "--demonstration", "--audio":
                guard command == "video", request.options["action"] == "start" else { throw RPCError(message: "\(arg) is a video start option.") }
                request.options[String(arg.dropFirst(2))] = "true"
            case "--app":
                guard command == "video", ["windows", "start"].contains(request.options["action"] ?? ""), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw TaskVideoError.invalidOptions }
                guard request.options["app"] == nil else { throw TaskVideoError.invalidOptions }
                index += 1; request.options["app"] = arguments[index]
            case "--window", "--display", "--seconds", "--max-mib":
                guard command == "video", request.options["action"] == "start", index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw RPCError(message: "\(arg) requires a value on video start.") }
                guard request.options[String(arg.dropFirst(2))] == nil else { throw TaskVideoError.invalidOptions }
                index += 1
                request.options[String(arg.dropFirst(2))] = arguments[index]
            case "--disconnect":
                guard command == "phone" else { throw RPCError(message: "--disconnect is a phone option.") }
                request.options["disconnect"] = "true"
            case "--login", "--pair", "--tailscale-connect", "--phone-access":
                guard command == "setup" else { throw RPCError(message: "\(arg) is a setup option.") }
                request.options[String(arg.dropFirst(2))] = "true"
            case "--workspace", "--permission", "--model", "--effort", "--service-tier",
                 "--relay-model", "--relay-effort", "--relay-service-tier", "--max-operators", "--max-helpers",
                 "--coordinator-model", "--coordinator-effort", "--coordinator-service-tier",
                 "--worker-model", "--worker-effort", "--worker-service-tier", "--max-workers":
                guard command == "setup", index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw RPCError(message: "\(arg) requires a value on setup.") }
                let key = SteveSetupOptions.canonical(String(arg.dropFirst(2)))
                guard request.options[key] == nil else { throw RPCError(message: "Specify each setup choice only once, including legacy aliases.") }
                index += 1
                request.options[key] = arguments[index]
            case "--open-permission":
                guard command == "setup", index + 1 < arguments.count,
                      StevePermissionTarget(rawValue: arguments[index + 1]) != nil,
                      request.options["open-permission"] == nil else {
                    throw RPCError(message: "Choose one supported --open-permission target from steve --help.")
                }
                index += 1
                request.options["open-permission"] = arguments[index]
            default: throw RPCError(message: "Unknown option: \(arg)")
            }
            index += 1
        }
        guard request.options["open-permission"] == nil || request.options.count == 1 else {
            throw RPCError(message: "Use --open-permission separately from other setup options; no changes were applied.")
        }
        return (request, json, interactive)
    }

    static func run(_ arguments: [String]) -> Int32 {
        if arguments == ["--help"] || arguments == ["help"] { print(help); return 0 }
        let json = arguments.contains("--json")
        do {
            var (request, _, interactive) = try parse(arguments)
            if interactive && request.command == "setup" && request.options.isEmpty && isatty(STDIN_FILENO) == 1 {
                print("Steve keeps existing settings. Press Return to leave a choice unchanged.")
                print("Your iMessage email or phone with country code: ", terminator: "")
                if let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { request.options["owner"] = value }
                print("Agent name (optional): ", terminator: "")
                if let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { request.options["agent-name"] = value }
                print("Personality, such as warm and concise (optional): ", terminator: "")
                if let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { request.options["personality"] = value }
                print("Workspace (absolute path): ", terminator: "")
                if let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { request.options["workspace"] = value }
                print("Permission (read-only / workspace-write / danger-full-access): ", terminator: "")
                if let value = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty { request.options["permission"] = value }
            }
            let response = try SteveControlSocket.request(request)
            output(response, json: json)
            return response.state == "ready" ? 0 : response.state == "failed" ? 1 : 2
        } catch {
            output(SteveControlResponse(state: "failed", summary: error.localizedDescription), json: json)
            return 1
        }
    }

    private static func output(_ response: SteveControlResponse, json: Bool) {
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(response) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            print("\(response.state): \(response.summary)")
            for check in response.checks { print("\(check.name): \(check.state) — \(check.detail)") }
            for key in response.values.keys.sorted() { print("\(key): \(response.values[key]!)") }
        }
    }
}
