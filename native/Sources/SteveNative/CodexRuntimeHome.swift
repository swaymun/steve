import Foundation

/// Reuse Codex setup, never its desktop task index or session storage.
/// Authentication files are linked, not read or copied by Steve.
struct CodexRuntimeHome: Sendable {
    let root: URL
    let shared: URL

    static var live: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let configured = ProcessInfo.processInfo.environment["CODEX_HOME"]
        return Self(root: StevePaths.dataDirectory.appendingPathComponent("runtime", isDirectory: true),
                    shared: configured.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
                        ?? home.appendingPathComponent(".codex", isDirectory: true))
    }

    func prepare() throws {
        let fm = FileManager.default
        let source = shared.resolvingSymlinksInPath().standardizedFileURL
        let destination = root.resolvingSymlinksInPath().standardizedFileURL
        guard destination != source, !destination.path.hasPrefix(source.path + "/"),
              !source.path.hasPrefix(destination.path + "/") else {
            throw RPCError(message: "Steve's private runtime must be separate from the desktop Codex home.")
        }
        try privateDirectory(root)
        for name in ["sessions", "archived_sessions", "logs", "memories", "tmp"] {
            try privateDirectory(root.appendingPathComponent(name, isDirectory: true))
        }
        // An old/manual storage link must not redirect history into the desktop.
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey])
            where file.lastPathComponent.contains(".sqlite") || file.lastPathComponent == "history.jsonl" {
            let attributes = try fm.attributesOfItem(atPath: file.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
                throw RPCError(message: "Steve runtime storage is linked outside its private directory. Remove the storage link before starting Steve.")
            }
        }
        var names = ["config.toml", "auth.json", ".credentials.json", "plugins", "skills", "rules", "agents", "AGENTS.md", "AGENTS.override.md"]
        if fm.fileExists(atPath: shared.path) {
            names += try fm.contentsOfDirectory(atPath: shared.path).filter { $0.hasSuffix(".config.toml") }
        }
        for name in names {
            let source = shared.appendingPathComponent(name)
            let target = root.appendingPathComponent(name)
            // Preserve private settings and existing (including dangling) links.
            guard fm.fileExists(atPath: source.path), (try? fm.attributesOfItem(atPath: target.path)) == nil else { continue }
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }

    var configurationArguments: [String] {
        ["-c", "sqlite_home=" + Self.tomlString(root.path),
         "-c", "log_dir=" + Self.tomlString(root.appendingPathComponent("logs").path)]
    }

    func environment(_ inherited: [String: String]) -> [String: String] {
        var values = CodexComputerUseRuntime.sanitizedEnvironment(inherited)
        values["CODEX_HOME"] = root.path
        values["CODEX_SQLITE_HOME"] = root.path
        return values
    }

    /// Lazy upgrade of one Steve-owned thread, only after private resume reports
    /// missing history. Never import the desktop database or unrelated chats.
    func importLegacyThread(_ id: String) throws -> URL? {
        guard UUID(uuidString: id) != nil else { return nil }
        try prepare()
        if let existing = try rollout(id, under: root) { return existing }
        guard let source = try rollout(id, under: shared) else { return nil }
        let folder = root.appendingPathComponent("sessions", isDirectory: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent)
        let temporary = folder.appendingPathComponent(UUID().uuidString + ".importing")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try FileManager.default.moveItem(at: temporary, to: destination)
        return destination.resolvingSymlinksInPath()
    }

    private func rollout(_ id: String, under home: URL) throws -> URL? {
        let fm = FileManager.default
        for name in ["sessions", "archived_sessions"] {
            let directory = home.appendingPathComponent(name).resolvingSymlinksInPath()
            guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in files where file.lastPathComponent.hasSuffix("-" + id + ".jsonl") {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      file.resolvingSymlinksInPath().path.hasPrefix(directory.path + "/") else { continue }
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 1_048_576) ?? Data()
                guard let end = data.firstIndex(of: 10),
                      let meta = try JSONSerialization.jsonObject(with: data.prefix(upTo: end)) as? [String: Any],
                      meta["type"] as? String == "session_meta",
                      let payload = meta["payload"] as? [String: Any], payload["id"] as? String == id,
                      payload["originator"] as? String == "steve" else { continue }
                return file.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    private func privateDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw RPCError(message: "Steve's private runtime contains a linked or invalid storage directory.")
            }
        }
        try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func tomlString(_ value: String) -> String {
        // JSON basic strings are compatible with TOML for filesystem paths.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return String(decoding: try! encoder.encode(value), as: UTF8.self)
    }
}
