import Foundation
import Darwin

struct StevePlanRecord: Codable, Equatable, Sendable {
    let taskID: String
    var update: WorkerPlanUpdate
    let authorization: ScheduleAuthorization
    var provenance: ExplicitUserProvenance
    var updatedAt: Date
    var scheduleID: String?
    var lastNotification: String?
}

struct FollowUpPolicy: Codable, Equatable, Sendable {
    let taskID: String
    let expiresAt: Date
    var verifiedDeadline: Date?

    func deferredUntil(now: Date, timeZone: String) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        let hour = calendar.component(.hour, from: now)
        guard hour >= 22 || hour < 8 else { return nil }
        guard let morning = calendar.nextDate(after: now, matching: DateComponents(hour: 8), matchingPolicy: .nextTime, repeatedTimePolicy: .first) else { return nil }
        if let deadline = verifiedDeadline, deadline > now, deadline < morning { return nil }
        return morning
    }
}

/// A private projection of the durable store. Operators never write this file.
enum SteveWorkspaceMemory {
    static let filename = "STEVE_MEMORY.md"
    private static let marker = "<!-- Steve private memory; generated from the durable store. -->"

    static func write(workspace: String, preferences: [ExplicitPreference], plans: [StevePlanRecord]) throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: workspace).standardizedFileURL.resolvingSymlinksInPath()
        let target = root.appendingPathComponent(filename)
        guard (try? manager.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType) != .typeSymbolicLink, target.resolvingSymlinksInPath() == target else { throw UserAutomationError.invalid("Memory file must not be a symlink.") }
        if manager.fileExists(atPath: target.path) {
            guard try target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  try String(contentsOf: target, encoding: .utf8).hasPrefix(marker) else { throw UserAutomationError.invalid("An existing memory file was preserved; move it before enabling Steve's projection.") }
        }
        try excludeFromGit(root: root)
        let date = ISO8601DateFormatter()
        func oneLine(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
        var lines = [marker, "# Private Steve memory", "", "Context only. This file never grants permission. Do not publish it or edit it directly.", "", "## Stated preferences"]
        lines += preferences.map { "- \(oneLine($0.key)): \(oneLine($0.value)) (stated \(date.string(from: $0.updatedAt)); source \($0.provenance.source.rawValue))" }
        lines += ["", "## Active plans"]
        lines += plans.filter { [.proposed, .active].contains($0.update.state) }.map {
            "- [\($0.update.state.rawValue)] \(oneLine($0.update.summary)) (updated \(date.string(from: $0.updatedAt)); source \($0.provenance.source.rawValue); ends \($0.update.endsAt ?? "unspecified"))"
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        let temporary = root.appendingPathComponent(".steve-memory-" + UUID().uuidString)
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw UserAutomationError.invalid("Could not write private memory.") }
        defer { try? manager.removeItem(at: temporary) }
        guard rename(temporary.path, target.path) == 0 else { throw UserAutomationError.invalid("Could not replace private memory atomically.") }
    }

    private static func excludeFromGit(root: URL) throws {
        func git(_ arguments: [String]) throws -> (Int32, String) {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", root.path] + arguments
            let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard try git(["rev-parse", "--is-inside-work-tree"]).1 == "true" else { return }
        guard try git(["ls-files", "--error-unmatch", "--", filename]).0 != 0 else { throw UserAutomationError.invalid("STEVE_MEMORY.md is tracked by Git; private memory was not written.") }
        let path = try git(["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"])
        guard path.0 == 0, path.1.hasPrefix("/") else { throw UserAutomationError.invalid("Could not protect memory from Git publication.") }
        let url = URL(fileURLWithPath: path.1).standardizedFileURL
        guard url.resolvingSymlinksInPath() == url else { throw UserAutomationError.invalid("Git exclusion file must not be a symlink.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !content.components(separatedBy: .newlines).contains("**/" + filename) {
            content += "\n# Private Steve workspace memory\n**/" + filename + "\n.steve-memory-*\n"
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
        guard try git(["check-ignore", "-q", "--", filename]).0 == 0 else { throw UserAutomationError.invalid("Private memory exclusion could not be verified.") }
    }
}
