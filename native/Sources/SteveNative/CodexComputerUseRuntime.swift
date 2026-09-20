import Foundation

/// Discovers the Computer Use MCP client installed by the ChatGPT/Codex app.
/// Steve uses this native service for browser work instead of the private
/// Chrome extension bridge.
struct CodexComputerUseRuntime: Sendable, Equatable {
    let executablePath: String
    let codexHome: String
    let workingDirectory: String

    var appURL: URL {
        URL(fileURLWithPath: workingDirectory, isDirectory: true)
            .appendingPathComponent("Codex Computer Use.app", isDirectory: true)
    }

    var isUsable: Bool {
        FileManager.default.isExecutableFile(atPath: executablePath)
    }

    var serverConfiguration: String {
        "{command=\"\(tomlString(executablePath))\",args=[\"mcp\"],cwd=\"\(tomlString(workingDirectory))\",enabled=true,env={CODEX_HOME=\(CodexRuntimeHome.tomlString(codexHome))}}"
    }

    var environment: [String: String] {
        var values = Self.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        values["CODEX_HOME"] = codexHome
        return values
    }

    static func sanitizedEnvironment(_ environment: [String: String]) -> [String: String] {
        var values = environment
        for key in ["CODEX_APP_TOOLS_PIPE_PATH", "CODEX_SESSION_ID", "CODEX_THREAD_ID"] {
            values.removeValue(forKey: key)
        }
        return values
    }

    static func discover(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CodexComputerUseRuntime? {
        let codexHome = home.appendingPathComponent(".codex", isDirectory: true)
        let computerUseDirectory = codexHome.appendingPathComponent("computer-use", isDirectory: true)
        let executable = computerUseDirectory
            .appendingPathComponent("Codex Computer Use.app", isDirectory: true)
            .appendingPathComponent("Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient")

        let runtime = CodexComputerUseRuntime(
            executablePath: executable.path,
            codexHome: codexHome.path,
            workingDirectory: computerUseDirectory.path
        )
        guard runtime.isUsable else {
            SteveLog.write("Computer Use runtime unavailable")
            return nil
        }
        SteveLog.write("Computer Use runtime discovered")
        return runtime
    }

    private func tomlString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
