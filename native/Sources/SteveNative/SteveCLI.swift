import Foundation

enum SteveCLI {
    static let help = """
    Usage: steve setup|doctor|status|start|stop [--json] [--non-interactive]
      steve approval [--json]
      steve approve|deny APPROVAL_ID [--json]
      steve phone [--disconnect] [--json]
      steve video start --demonstration --display ID [--audio] [--seconds 30] [--max-mib 24] [--json]
      steve video stop RECORDING_ID [--json]
      steve video cancel [--json]
      setup [--workspace /absolute/path] [--permission PROFILE]
            [--model ID] [--effort EFFORT] [--service-tier standard|fast] [--login] [--pair] [--tailscale-connect] [--phone-access]

    Open Steve.app first. Commands use the running app's permissions and session.
    setup applies only explicit choices. --login returns the official sign-in URL;
    --pair returns a one-time code to send in Messages. Neither bypasses human login
    or macOS permission prompts. --non-interactive never waits for terminal input.
    start resumes the operator; stop pauses and cancels it. It does not quit the app.
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
            guard arguments.count > 1, ["start", "stop", "cancel"].contains(arguments[1]) else { throw RPCError(message: "Choose video start, stop, or cancel.") }
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
            case "--demonstration", "--audio":
                guard command == "video", request.options["action"] == "start" else { throw RPCError(message: "\(arg) is a video start option.") }
                request.options[String(arg.dropFirst(2))] = "true"
            case "--display", "--seconds", "--max-mib":
                guard command == "video", request.options["action"] == "start", index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw RPCError(message: "\(arg) requires a value on video start.") }
                index += 1
                request.options[String(arg.dropFirst(2))] = arguments[index]
            case "--disconnect":
                guard command == "phone" else { throw RPCError(message: "--disconnect is a phone option.") }
                request.options["disconnect"] = "true"
            case "--login", "--pair", "--tailscale-connect", "--phone-access":
                guard command == "setup" else { throw RPCError(message: "\(arg) is a setup option.") }
                request.options[String(arg.dropFirst(2))] = "true"
            case "--workspace", "--permission", "--model", "--effort", "--service-tier":
                guard command == "setup", index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else { throw RPCError(message: "\(arg) requires a value on setup.") }
                index += 1
                request.options[String(arg.dropFirst(2))] = arguments[index]
            default: throw RPCError(message: "Unknown option: \(arg)")
            }
            index += 1
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
