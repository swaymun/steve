import Foundation
import AppKit
import Darwin
import UniformTypeIdentifiers

struct CodexAttachment: Sendable, Equatable {
    let path: String
    let caption: String
}

enum CodexMessagePhase: String, Sendable, Equatable {
    case commentary
    case finalAnswer = "final_answer"
}

struct CodexTurnEvent: Sendable, Equatable {
    let phase: CodexMessagePhase?
    let text: String
}

struct CodexTurnAccumulator {
    private let threadID: String
    private let turnID: String
    private let workspace: String?
    private var deltaTextByItem: [String: String] = [:]
    private var completedAgentItemIDs = Set<String>()
    private var finalText = ""
    private var attachmentPaths: [String] = []

    init(threadID: String, turnID: String, workspace: String? = nil) {
        self.threadID = threadID
        self.turnID = turnID
        self.workspace = workspace
    }

    mutating func consume(_ object: [String: Any]) -> CodexTurnEvent? {
        guard let method = object["method"] as? String,
              let params = object["params"] as? [String: Any],
              (params["threadId"] as? String) == threadID,
              (params["turnId"] as? String) == turnID else { return nil }

        if method == "item/agentMessage/delta",
           let itemID = params["itemId"] as? String,
           let delta = params["delta"] as? String {
            deltaTextByItem[itemID, default: ""] += delta
            return nil
        }

        guard method == "item/completed",
              let item = params["item"] as? [String: Any],
              let itemID = item["id"] as? String else { return nil }

        attachmentPaths.append(contentsOf: attachmentPaths(in: item))
        let itemType = item["type"] as? String ?? "unknown"
        guard itemType == "agentMessage" else {
            let itemName = (item["name"] as? String ?? item["toolName"] as? String ?? "")
                .filter { $0.isLetter || $0.isNumber || "_-.".contains($0) }
            SteveLog.write("Codex turn item completed type=\(itemType) name=\(itemName.isEmpty ? "-" : String(itemName.prefix(80)))")
            return nil
        }

        completedAgentItemIDs.insert(itemID)
        let text = (item["text"] as? String) ?? deltaTextByItem[itemID] ?? ""
        let phase = (item["phase"] as? String).flatMap(CodexMessagePhase.init(rawValue:))
        if phase != .commentary {
            finalText += text
        }
        SteveLog.write("Codex turn agent message completed phase=\(phase?.rawValue ?? "unknown")")
        return CodexTurnEvent(phase: phase, text: text)
    }

    func result(wasInterrupted: Bool = false) -> CodexTurnResult {
        let uncompletedDeltaText = deltaTextByItem
            .filter { !completedAgentItemIDs.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined()
        let text = finalText.isEmpty ? uncompletedDeltaText : finalText
        SteveLog.write("Codex turn final answer selected agentText=\(text.isEmpty ? 0 : 1) attachments=\(attachmentPaths.count)")
        return CodexTurnResult(text: text, attachmentPaths: attachmentPaths, wasInterrupted: wasInterrupted, workspace: workspace)
    }

    private func attachmentPaths(in item: [String: Any]) -> [String] {
        let itemType = item["type"] as? String ?? "unknown"
        var found: [String] = []
        let genericPathKeys: Set<String> = [
            "savedpath", "filepath", "attachmentpath", "localpath", "outputpath",
            "audiopath", "fileurl", "attachmenturl", "audiourl", "uri", "url", "file"
        ]
        let toolResultTypes: Set<String> = ["mcpToolCall", "dynamicToolCall", "functionCallOutput"]

        func visit(_ value: Any, key: String? = nil) {
            if let string = value as? String,
               let key,
               (genericPathKeys.contains(normalizedKey(key))
                || (normalizedKey(key) == "path" && toolResultTypes.contains(itemType))),
               let path = localAttachmentPath(string) ?? CodexTurnResult.materializeDataURL(string, workspace: workspace)
            {
                found.append(path)
                return
            }
            if let dictionary = value as? [String: Any] {
                for (childKey, childValue) in dictionary {
                    if childKey == "path", itemType == "imageView",
                       let path = childValue as? String,
                       let localPath = localAttachmentPath(path) ?? CodexTurnResult.materializeDataURL(path, workspace: workspace)
                    {
                        found.append(localPath)
                    } else {
                        visit(childValue, key: childKey)
                    }
                }
            } else if let array = value as? [Any] {
                for child in array { visit(child) }
            }
        }

        visit(item)
        var seen = Set<String>()
        return found.filter { path in
            guard seen.insert(path).inserted else { return false }
            SteveLog.write("Codex attachment discovered type=\(itemType) path=\(path)")
            return true
        }
    }

    private func normalizedKey(_ key: String) -> String {
        key.filter { $0.isLetter || $0.isNumber }.lowercased()
    }

    private func localAttachmentPath(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.contains("\n"), !candidate.contains("\r") else { return nil }

        let path: String
        if candidate.lowercased().hasPrefix("file://"),
           let url = URL(string: candidate), url.isFileURL
        {
            path = url.path
        } else if candidate == "~" || candidate.hasPrefix("~/") || candidate.hasPrefix("/") {
            path = (candidate as NSString).expandingTildeInPath
        } else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path)
        else { return nil }
        return path
    }
}

struct CodexTurnResult: Sendable, Equatable {
    let text: String
    let attachments: [CodexAttachment]
    let wasInterrupted: Bool

    init(text: String, attachmentPaths: [String], wasInterrupted: Bool = false, workspace: String? = nil) {
        // Structured envelopes are immutable protocol data, not presentation text.
        let isStructured = text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
        let extracted = isStructured ? (text: text, paths: [String]()) : Self.extractDataURLAttachments(from: text, workspace: workspace)
        var cleanedLines: [String] = []
        var paths = attachmentPaths + extracted.paths
        var captions: [String: String] = [:]
        for rawLine in extracted.text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.uppercased().hasPrefix("ATTACHMENT:") else {
                cleanedLines.append(String(rawLine))
                continue
            }
            let value = line.dropFirst("ATTACHMENT:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            let components = value.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: true)
            guard let rawPath = components.first else { continue }
            let rawValue = String(rawPath).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path = Self.localAttachmentPath(rawValue) else {
                SteveLog.write("Codex attachment path is not readable")
                continue
            }
            paths.append(path)
            if components.count > 1 {
                let caption = String(components[1]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !caption.isEmpty { captions[path] = caption }
            }
        }
        var seen = Set<String>()
        attachments = paths.compactMap { path in
            let expanded = Self.expandPath(path)
            guard !expanded.isEmpty, seen.insert(expanded).inserted,
                  FileManager.default.isReadableFile(atPath: expanded) else { return nil }
            return CodexAttachment(
                path: expanded,
                caption: captions[expanded] ?? "Here's the result."
            )
        }
        self.text = cleanedLines.joined(separator: "\n")
        self.wasInterrupted = wasInterrupted
    }

    private static func expandPath(_ path: String) -> String {
        if path == "~" { return FileManager.default.homeDirectoryForCurrentUser.path }
        if path.hasPrefix("~/") { return FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst()) }
        return path
    }

    private static func localAttachmentPath(_ value: String) -> String? {
        let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.contains("\n"), !candidate.contains("\r") else { return nil }
        let path: String
        if candidate.lowercased().hasPrefix("file://"),
           let url = URL(string: candidate), url.isFileURL
        {
            path = url.path
        } else if candidate == "~" || candidate.hasPrefix("~/") || candidate.hasPrefix("/") {
            path = expandPath(candidate)
        } else {
            return nil
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              FileManager.default.isReadableFile(atPath: path)
        else { return nil }
        return path
    }

    func resolvingWorkspaceFiles(in workspace: String) -> CodexTurnResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { return self }
        let localPaths = Self.localFileReferences(in: text)
        let workspaceFiles = Self.workspaceFileReferences(in: text)
        guard !localPaths.isEmpty || !workspaceFiles.isEmpty else { return self }
        let workspacePath = Self.expandPath(workspace)
        var paths = attachments.map(\.path)
        for path in localPaths {
            guard let resolved = Self.localAttachmentPath(path), !paths.contains(resolved) else { continue }
            paths.append(resolved)
            SteveLog.write("Codex local attachment path resolved extension=\(URL(fileURLWithPath: resolved).pathExtension.lowercased())")
        }
        for filename in workspaceFiles {
            let path = URL(fileURLWithPath: workspacePath).appendingPathComponent(filename).path
            guard let resolved = Self.localAttachmentPath(path), !paths.contains(resolved) else { continue }
            paths.append(resolved)
            SteveLog.write("Codex workspace attachment resolved extension=\(URL(fileURLWithPath: resolved).pathExtension.lowercased())")
        }
        guard paths.count > attachments.count else { return self }
        return CodexTurnResult(text: text, attachmentPaths: paths)
    }

    func resolvingRequestedWorkspaceFile(in workspace: String, request: String) -> CodexTurnResult {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") else { return self }
        guard attachments.isEmpty else { return self }
        let requestLowercased = request.lowercased()
        let deliveryLanguage = ["send", "share", "attach", "give me", "deliver"]
        let artifactLanguage = [
            "file", "audio", "image", "photo", "picture", "video", "document", "pdf",
            "epub", "spreadsheet", "report", "voice", "recording", "send it", "send that",
            "attach it", "attach that"
        ]
        guard deliveryLanguage.contains(where: requestLowercased.contains),
              artifactLanguage.contains(where: requestLowercased.contains)
        else { return self }

        let workspacePath = Self.expandPath(workspace)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        let candidates = FileManager.default.enumerator(
            at: URL(fileURLWithPath: workspacePath),
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )?.compactMap { item -> URL? in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  FileManager.default.isReadableFile(atPath: url.path),
                  Self.attachmentExtensions.contains(url.pathExtension.lowercased())
            else { return nil }
            return url
        } ?? []
        guard !candidates.isEmpty else {
            SteveLog.write("Codex requested attachment fallback found no workspace files")
            return self
        }

        let named = candidates.filter { requestLowercased.contains($0.lastPathComponent.lowercased()) }
        let scoped = candidates.filter { url in
            guard let category = Self.attachmentCategory(in: requestLowercased) else { return true }
            return category.contains(url.pathExtension.lowercased())
        }
        let pool = (named.isEmpty ? scoped : named)
        guard let selected = pool.max(by: { left, right in
            let leftDate = (try? left.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            let rightDate = (try? right.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            return (leftDate ?? .distantPast) < (rightDate ?? .distantPast)
        }) else { return self }

        SteveLog.write("Codex requested attachment fallback selected extension=(selected.pathExtension.lowercased())")
        return CodexTurnResult(text: text, attachmentPaths: [selected.path])
    }

    private static let attachmentExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aac", "ogg", "webm", "png", "jpg", "jpeg", "heic", "heif",
        "gif", "webp", "pdf", "epub", "doc", "docx", "xls", "xlsx", "csv", "txt", "rtf",
        "mp4", "mov", "m4v", "zip"
    ]

    private static func attachmentCategory(in request: String) -> Set<String>? {
        if ["audio", "voice", "recording", "sound", "m4a", "mp3", "wav", "aac", "ogg"].contains(where: request.contains) {
            return ["m4a", "mp3", "wav", "aac", "ogg", "webm"]
        }
        if ["image", "photo", "picture", "png", "jpg", "jpeg", "heic", "gif", "webp"].contains(where: request.contains) {
            return ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp"]
        }
        if ["video", "mp4", "mov", "m4v"].contains(where: request.contains) {
            return ["mp4", "mov", "m4v", "webm"]
        }
        if ["pdf", "epub", "document", "spreadsheet", "report", "docx", "xlsx", "csv"].contains(where: request.contains) {
            return ["pdf", "epub", "doc", "docx", "xls", "xlsx", "csv", "txt", "rtf"]
        }
        return nil
    }

    private static func localFileReferences(in text: String) -> [String] {
        let extensions = #"(?:m4a|mp3|wav|aac|ogg|webm|png|jpe?g|heic|heif|gif|webp|pdf|epub|doc|docx|xls|xlsx|csv|txt|rtf|mp4|mov|m4v|zip)"#
        let patterns = [
            #"(?i)(?<![A-Za-z0-9_./-])(?:file://)?(?:~|/)[^\s\r\n)\]}>\"']+\."# + extensions + #"(?![A-Za-z0-9_/-])"#,
            #"(?i)(?<![A-Za-z0-9_./-])(?:file://)?(?:~|/)[^\"'`\r\n]+\."# + extensions + #"(?=[\"'`])"#
        ]
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return patterns.flatMap { pattern -> [String] in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            return expression.matches(in: text, range: range).compactMap { match in
                guard let matchRange = Range(match.range, in: text) else { return nil }
                let value = String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                guard !value.isEmpty, seen.insert(value).inserted else { return nil }
                return value
            }
        }
    }

    private static func workspaceFileReferences(in text: String) -> [String] {
        let lower = text.lowercased()
        let cues = ["saved as", "written as", "generated as", "created as", "available as", "file is", "here is", "here's", "attached"]
        guard cues.contains(where: lower.contains) else { return [] }

        let pattern = #"(?i)(?<![A-Za-z0-9_./-])[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.(?:m4a|mp3|wav|aac|ogg|webm|png|jpe?g|heic|heif|gif|webp|pdf|epub|doc|docx|xls|xlsx|csv|txt|rtf|mp4|mov|m4v|zip)(?![A-Za-z0-9_./-])"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        return expression.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let filename = String(text[matchRange])
            guard !filename.contains(".."), seen.insert(filename).inserted else { return nil }
            return filename
        }
    }

    private static func extractDataURLAttachments(from text: String, workspace: String?) -> (text: String, paths: [String]) {
        var remaining = text
        var paths: [String] = []
        var searchStart = remaining.startIndex

        while searchStart < remaining.endIndex,
              let range = remaining.range(of: "data:", options: [.caseInsensitive], range: searchStart..<remaining.endIndex)
        {
            var end = range.upperBound
            while end < remaining.endIndex {
                let character = remaining[end]
                if character.isWhitespace || ")]}>\"'".contains(character) { break }
                end = remaining.index(after: end)
            }

            let token = String(remaining[range.lowerBound..<end])
            if let path = materializeDataURL(token, workspace: workspace) {
                paths.append(path)
                remaining.replaceSubrange(range.lowerBound..<end, with: "")
                searchStart = range.lowerBound
            } else {
                searchStart = end
            }
        }
        return (remaining, paths)
    }

    static func materializeDataURL(_ value: String, workspace: String? = nil) -> String? {
        guard value.lowercased().hasPrefix("data:"),
              let comma = value.firstIndex(of: ",")
        else { return nil }

        let metadata = value[value.index(value.startIndex, offsetBy: 5)..<comma]
        let parts = metadata.split(separator: ";", omittingEmptySubsequences: true)
        guard parts.contains(where: { $0.caseInsensitiveCompare("base64") == .orderedSame }) else {
            return nil
        }
        let mimeType = parts.first(where: {
            $0.caseInsensitiveCompare("base64") != .orderedSame && !$0.contains("=")
        })
            .map(String.init)
            ?? "application/octet-stream"
        let filenameHint = parts.first(where: { $0.lowercased().hasPrefix("name=") })
            .map { String($0.dropFirst(5)) }
        let payload = String(value[value.index(after: comma)...])
        guard payload.utf8.count <= 32 * 1024 * 1024,
              let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              !data.isEmpty,
              data.count <= 24 * 1024 * 1024
        else { return nil }

        let extensionName = fileExtension(for: mimeType)
        let root: URL
        if let workspace {
            let workspaceURL = URL(fileURLWithPath: (workspace as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            root = workspaceURL.appendingPathComponent(".steve-artifacts", isDirectory: true)
            // Never follow a pre-existing artifact-directory symlink outside the workspace.
            guard root.resolvingSymlinksInPath().path == root.path else { return nil }
        } else {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("SteveAttachments", isDirectory: true)
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = safeFilename(filenameHint, fallbackExtension: extensionName)
        let file = directory.appendingPathComponent(filename)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            SteveLog.write("Codex data URL materialized mime=\(mimeType) bytes=\(data.count)")
            return file.path
        } catch {
            SteveLog.write("Codex data URL materialization failed mime=\(mimeType)")
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "audio/mp4", "audio/x-m4a", "audio/m4a": return "m4a"
        case "audio/mpeg": return "mp3"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac": return "aac"
        case "audio/ogg": return "ogg"
        case "audio/webm": return "webm"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/webp": return "webp"
        case "application/pdf": return "pdf"
        case "application/epub+zip": return "epub"
        case "application/msword": return "doc"
        case "application/vnd.openxmlformats-officedocument.wordprocessingml.document": return "docx"
        case "application/vnd.ms-excel": return "xls"
        case "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": return "xlsx"
        case "text/plain": return "txt"
        case "text/csv": return "csv"
        case "application/rtf", "text/rtf": return "rtf"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/x-m4v": return "m4v"
        case "application/zip": return "zip"
        default: return UTType(mimeType: mimeType)?.preferredFilenameExtension ?? "bin"
        }
    }

    private static func safeFilename(_ hint: String?, fallbackExtension: String) -> String {
        guard let hint, !hint.isEmpty else { return "attachment.\(fallbackExtension)" }
        let basename = URL(fileURLWithPath: hint).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
        let sanitized = String(basename.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        guard !sanitized.isEmpty else { return "attachment.\(fallbackExtension)" }
        return URL(fileURLWithPath: sanitized).pathExtension.isEmpty
            ? "\(sanitized).\(fallbackExtension)"
            : sanitized
        }
    }

/// Auth URLs remain ephemeral inside the privileged request; never encode this
/// into status, chat, worker context, or persistent storage.
struct CodexConnectionSetup: Sendable, Equatable {
    let connectorName: String
    let url: URL

    static func parse(_ params: [String: Any]) -> Self? {
        guard params["mode"] as? String == "url", params["serverName"] as? String == "codex_apps",
              let meta = params["_meta"] as? [String: Any],
              let apps = meta["_codex_apps"] as? [String: Any],
              let failure = apps["connector_auth_failure"] as? [String: Any],
              let flag = failure["is_auth_failure"] as? NSNumber,
              CFGetTypeID(flag) == CFBooleanGetTypeID(), flag.boolValue,
              let id = failure["connector_id"] as? String, !id.isEmpty,
              let name = failure["connector_name"] as? String, !name.isEmpty, name.utf8.count <= 100,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-()&")).contains($0) }),
              trustedURL(params["url"]) != nil,
              let url = trustedURL(failure["install_url"]) else { return nil }
        return Self(connectorName: name, url: url)
    }
    private static func trustedURL(_ value: Any?) -> URL? {
        guard let raw = value as? String, let parts = URLComponents(string: raw),
              parts.scheme?.lowercased() == "https", let host = parts.host?.lowercased(),
              host == "chatgpt.com" || host.hasSuffix(".chatgpt.com"),
              parts.user == nil, parts.password == nil, parts.port == nil || parts.port == 443 else { return nil }
        return parts.url
    }
}

struct CodexApprovalRequest: Sendable, Equatable {
    let requestID: String
    let method: String
    let threadID: String?
    let turnID: String?
    let message: String
    let origin: String?
    let connector: String?
    let tool: String?
    let expiresAt: Date
    var mode: String? = nil
    var isEmptyBrowserOriginForm = false
    var nativeAppName: String? = nil
    var connectionSetup: CodexConnectionSetup? = nil

    /// Both installed-client contracts grant app access for this session only:
    /// modern typed mcp_tool_call metadata and the older native-message fallback.
    static func validatedNativeAppName(in params: [String: Any], resolveApplication: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) -> String? {
        guard params["mode"] as? String == "form",
              Set(params.keys).isSubset(of: ["threadId", "turnId", "serverName", "mode", "message", "requestedSchema", "_meta", "meta"]),
              !(params["_meta"] != nil && params["meta"] != nil),
              let meta = (params["_meta"] ?? params["meta"]) as? [String: Any],
              let thread = params["threadId"] as? String, !thread.isEmpty,
              let turn = params["turnId"] as? String, !turn.isEmpty,
              let schema = params["requestedSchema"] as? [String: Any], isEmptyOriginSchema(schema) else { return nil }
        if let title = schema["title"], !(title is String) { return nil }
        if let description = schema["description"], !(description is String) { return nil }
        if meta["codex_approval_kind"] != nil {
            // A malformed modern request cannot fall through to the old prompt.
            return modernNativeAppName(meta, resolveApplication: resolveApplication)
        }
        return legacyNativeAppName(params: params, meta: meta)
    }

    private static func modernNativeAppName(_ meta: [String: Any], resolveApplication: (String) -> URL?) -> String? {
        guard meta["codex_approval_kind"] as? String == "mcp_tool_call",
              let connector = meta["connector_id"] as? String, isNativeConnector(connector),
              let toolParams = meta["tool_params"] as? [String: Any],
              Set(toolParams.keys).isSubset(of: ["app"]) else { return nil }
        // Modern MCP metadata is extensible. Unknown metadata has no authority:
        // it is never interpreted as an action parameter or copied to a response.
        if let type = meta["codex_request_type"], type as? String != "approval_request" { return nil }
        if let tool = meta["tool_name"], tool as? String != "get_app_state" { return nil }
        for key in ["connector_name", "tool_title"] {
            if let value = meta[key] { guard let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil } }
        }
        // The generic metadata schema permits missing persist, but this app-only
        // approval supports the observed native grant contract, not generic tools.
        // An always advertisement never changes our session-only response.
        guard let values = meta["persist"] as? [String], values.contains("always"),
              Set(values).isSubset(of: ["always", "session"]), Set(values).count == values.count else { return nil }
        var displayedApp: String?
        if let raw = meta["tool_params_display"] {
            guard let entries = raw as? [[String: Any]] else { return nil }
            for entry in entries {
                guard Set(entry.keys).isSubset(of: ["name", "value", "display_name"]),
                      let name = entry["name"] as? String, name.trimmingCharacters(in: .whitespacesAndNewlines) == "app",
                      entry["value"] != nil else { return nil }
                if let rawLabel = entry["display_name"] {
                    guard let label = rawLabel as? String, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                }
                if name.trimmingCharacters(in: .whitespacesAndNewlines) == "app" {
                    guard displayedApp == nil, let app = entry["value"] as? String, validAppLabel(app) else { return nil }
                    displayedApp = app
                }
            }
        }
        var parameterApp: String?
        if let raw = toolParams["app"] {
            guard let app = raw as? String, validAppLabel(app) else { return nil }
            parameterApp = app
        }
        if let displayedApp, let parameterApp, displayedApp != parameterApp {
            // The live native contract uses a bundle ID as the parameter and an
            // app name for display. Trust only the installed bundle's exact ID
            // and localized metadata; never infer identity from a suffix/path.
            guard let url = resolveApplication(parameterApp), let bundle = Bundle(url: url),
                  bundle.bundleIdentifier == parameterApp else { return nil }
            let names = ["CFBundleDisplayName", "CFBundleName"].compactMap { bundle.object(forInfoDictionaryKey: $0) as? String }
            guard names.contains(displayedApp) else { return nil }
        }
        return displayedApp ?? parameterApp
    }

    private static func legacyNativeAppName(params: [String: Any], meta: [String: Any]) -> String? {
        guard params["serverName"] as? String == "computer-use",
              // The installed native fallback permits opaque metadata extensions.
              // Reject unsupported typed approval fields instead of interpreting
              // them as app-access authorization or reflecting them in responses.
              meta["tool_params_display"] == nil, meta["codex_request_type"] == nil, meta["tool_title"] == nil,
              let persist = meta["persist"] as? [String], persist.contains("always"),
              Set(persist).isSubset(of: ["always", "session"]), Set(persist).count == persist.count,
              let message = params["message"] as? String else { return nil }
        let prefixes = ["Allow Codex to use ", "Allow ChatGPT to use "]
        guard let prefix = prefixes.first(where: message.hasPrefix), message.hasSuffix("?") else { return nil }
        let name = String(message.dropFirst(prefix.count).dropLast())
        guard validAppLabel(name) else { return nil }
        if let connector = meta["connector_id"], connector as? String != "computer-use" { return nil }
        if let tool = meta["tool_name"], tool as? String != "get_app_state" { return nil }
        if let connectorName = meta["connector_name"], connectorName as? String != "Computer Use" { return nil }
        if let raw = meta["tool_params"] {
            guard let toolParams = raw as? [String: Any], Set(toolParams.keys) == ["app"], toolParams["app"] as? String == name else { return nil }
        }
        return name
    }

    /// Bounded shape-only diagnostics. Never include prompts, arbitrary values,
    /// URLs, or unknown key names (which themselves can contain credentials).
    static func nativeApprovalShape(in params: [String: Any]) -> String {
        let meta = (params["_meta"] ?? params["meta"]) as? [String: Any] ?? [:]
        let knownKeys: Set<String> = ["codex_approval_kind", "codex_request_type", "connector_id", "connector_name", "tool_name", "tool_title", "tool_params", "tool_params_display", "persist", "app", "name", "value", "display_name", "displayName", "bundle_id", "bundleId", "app_name", "application", "application_name", "command", "args", "path", "url"]
        func type(_ value: Any?) -> String {
            guard let value else { return "missing" }
            if value is NSNull { return "null" }
            if value is String { return "string" }
            if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number" }
            if value is [String: Any] { return "object" }
            if value is [Any] { return "array" }
            return "other"
        }
        func shape(_ object: [String: Any]) -> String {
            let fields = object.keys.filter { knownKeys.contains($0) }.sorted().prefix(24).map { "\($0):\(type(object[$0]))" }
            let otherCount = object.keys.filter { !knownKeys.contains($0) }.count
            return "[" + fields.joined(separator: ",") + ";otherKeys=\(min(otherCount, 99))]"
        }
        let tool = meta["tool_name"] as? String
        let safeTool = tool.flatMap { value -> String? in
            guard value.utf8.count <= 64, value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil else { return nil }
            return value
        } ?? type(meta["tool_name"])
        let toolParams = meta["tool_params"] as? [String: Any] ?? [:]
        let entries = meta["tool_params_display"] as? [Any] ?? []
        let displays = entries.prefix(4).map { value -> String in
            guard let entry = value as? [String: Any] else { return type(value) }
            let name = entry["name"] as? String
            let nameKind = name?.trimmingCharacters(in: .whitespacesAndNewlines) == "app" ? "app" : (name == nil ? type(entry["name"]) : "otherString")
            return shape(entry) + " name=\(nameKind) app=\(nameKind == "app" ? type(entry["value"]) : "notApp")"
        }
        let displayedApps = entries.compactMap { $0 as? [String: Any] }.filter { ($0["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) == "app" }
        let parameterApp = toolParams["app"] as? String
        let displayedApp = displayedApps.first?["value"] as? String
        let identitiesMatch = parameterApp != nil && displayedApp != nil && parameterApp == displayedApp
        return "meta=\(shape(meta)) tool=\(safeTool) params=\(shape(toolParams)) parameterApp=\(type(toolParams["app"])) displayType=\(type(meta["tool_params_display"])) displayCount=\(min(entries.count, 99)) displays=\(displays.joined(separator: ";")) appIdentitiesMatch=\(identitiesMatch)"
    }

    static func isNativeConnector(_ value: String) -> Bool {
        let parts = value.lowercased().components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted).filter { !$0.isEmpty }
        var normalized = parts.joined(separator: "-")
        if normalized.hasPrefix("connector-") { normalized.removeFirst("connector-".count) }
        return normalized == "computer-use" || normalized.hasPrefix("computer-use-")
    }

    private static func validAppLabel(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format || $0.properties.generalCategory == .lineSeparator || $0.properties.generalCategory == .paragraphSeparator })
    }

    static func isEmptyOriginSchema(_ value: Any?) -> Bool {
        guard let schema = value as? [String: Any], schema["type"] as? String == "object",
              let properties = schema["properties"] as? [String: Any], properties.isEmpty,
              Set(schema.keys).isSubset(of: ["$schema", "type", "properties", "required", "additionalProperties", "title", "description"]) else { return false }
        // App Server's typed MCP schema serializes these optional fields as
        // null. Null means absent; it does not introduce any form inputs.
        if let dialect = schema["$schema"], !(dialect is NSNull), !(dialect is String) { return false }
        if let required = schema["required"], !(required is NSNull) {
            guard let fields = required as? [String], fields.isEmpty else { return false }
        }
        if let additional = schema["additionalProperties"] {
            guard let value = additional as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID(), !value.boolValue else { return false }
        }
        return true
    }
}

enum CodexApprovalDecision: String, Sendable {
    case accept, decline, cancel
}

typealias CodexApprovalHandler = @Sendable (CodexApprovalRequest) async -> CodexApprovalDecision

private final class CodexResponseWaiter: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Any, Error>?

    func resolve(_ result: Result<Any, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        lock.unlock()
        semaphore.signal()
    }

    func wait(timeout: TimeInterval) throws -> Any {
        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            throw RPCError(message: "Codex App Server response timed out")
        }
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }
}

struct CodexTurnInterrupted: Error, LocalizedError, Sendable {
    var errorDescription: String? { "Codex turn interrupted" }
}

/// A single reader owns stdout for the entire process lifetime. Request and turn
/// waiters never read the pipe, so late control responses cannot be orphaned.
final class CodexRPCConnection: @unchecked Sendable {
    private let condition = NSCondition()
    private var process: Process?
    private var input: FileHandle?
    private var nextID = 1
    private var generation = UUID()
    private var terminalError: Error?
    private var notifications: [[String: Any]] = []
    private var responseWaiters: [Int: CodexResponseWaiter] = [:]
    private var approvalHandler: CodexApprovalHandler?
    private var approvalTasks: [String: Task<Void, Never>] = [:]
    private var approvalTurns: [String: String] = [:]
    private let executableOverride: URL?
    private let argumentsOverride: [String]
    private let responseTimeout: TimeInterval
    private let eventTimeout: TimeInterval
    private let approvalTimeout: TimeInterval

    init(executable: URL? = nil, arguments: [String] = [], responseTimeout: TimeInterval = 15, eventTimeout: TimeInterval = 1800, approvalTimeout: TimeInterval = 300) {
        executableOverride = executable
        argumentsOverride = arguments
        self.responseTimeout = responseTimeout
        self.eventTimeout = eventTimeout
        self.approvalTimeout = approvalTimeout
    }

    var isRunning: Bool {
        condition.lock(); defer { condition.unlock() }
        return process?.isRunning == true && terminalError == nil
    }

    func setApprovalHandler(_ handler: CodexApprovalHandler?) {
        condition.lock(); defer { condition.unlock() }
        approvalHandler = handler
    }

    func request(method: String, params: [String: Any]? = nil, allowStart: Bool = true) throws -> Any {
        try Task.checkCancellation()
        let waiter = CodexResponseWaiter()
        condition.lock()
        let id = nextID
        nextID += 1
        do {
            try Task.checkCancellation()
            if allowStart { try startIfNeeded() }
            else if process?.isRunning != true || terminalError != nil { throw RPCError(message: "Codex App Server is not running") }
            responseWaiters[id] = waiter
            var frame: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
            if let params { frame["params"] = params }
            try write(frame)
            condition.unlock()
        } catch {
            responseWaiters.removeValue(forKey: id)
            condition.unlock()
            throw error
        }
        defer {
            condition.lock(); responseWaiters.removeValue(forKey: id); condition.unlock()
        }
        return try waiter.wait(timeout: responseTimeout)
    }

    func requestWhileStreaming(method: String, params: [String: Any]? = nil) throws -> Any {
        // A control request must never restart a stopped connection.
        condition.lock()
        let running = process?.isRunning == true && terminalError == nil
        condition.unlock()
        guard running else { throw RPCError(message: "Codex App Server is not running") }
        return try request(method: method, params: params, allowStart: false)
    }

    func waitForTurn(threadID: String, turnID: String, workspace: String? = nil) async throws -> CodexTurnResult {
        var accumulator = CodexTurnAccumulator(threadID: threadID, turnID: turnID, workspace: workspace)
        let deadline = Date().addingTimeInterval(eventTimeout)
        while true {
            try Task.checkCancellation()
            let object = try nextNotification(until: deadline) { object in
                guard let params = object["params"] as? [String: Any], params["threadId"] as? String == threadID else { return false }
                if object["method"] as? String == "turn/completed" {
                    return (params["turn"] as? [String: Any])?["id"] as? String == turnID
                }
                return params["turnId"] as? String == turnID
            }
            _ = accumulator.consume(object)
            if object["method"] as? String == "turn/completed",
               let params = object["params"] as? [String: Any],
               let turn = params["turn"] as? [String: Any] {
                guard let status = turn["status"] as? String else {
                    throw RPCError(message: "Codex turn completion omitted its status")
                }
                switch status {
                case "completed": return accumulator.result()
                case "interrupted": throw CodexTurnInterrupted()
                case "failed": throw RPCError(message: "Codex turn failed; task completion is unverified")
                default: throw RPCError(message: "Codex returned an unsupported turn completion status")
                }
            }
        }
    }

    func waitForCompaction(threadID: String) throws {
        let deadline = Date().addingTimeInterval(eventTimeout)
        while true {
            try Task.checkCancellation()
            let object = try nextNotification(until: deadline) { object in
                (object["params"] as? [String: Any])?["threadId"] as? String == threadID
            }
            let method = object["method"] as? String
            let params = object["params"] as? [String: Any]
            if method == "thread/compacted" || (method == "item/completed" && (params?["item"] as? [String: Any])?["type"] as? String == "contextCompaction") { return }
            if method == "turn/completed", let turn = params?["turn"] as? [String: Any], turn["status"] as? String != "completed" {
                throw RPCError(message: "Codex compaction did not complete")
            }
        }
    }

    private func nextNotification(until deadline: Date, matching predicate: ([String: Any]) -> Bool) throws -> [String: Any] {
        condition.lock(); defer { condition.unlock() }
        while true {
            if let index = notifications.firstIndex(where: predicate) { return notifications.remove(at: index) }
            if let terminalError { throw terminalError }
            guard process != nil else { throw RPCError(message: "Codex App Server is unavailable") }
            guard condition.wait(until: deadline) else { throw RPCError(message: "Codex App Server event timed out") }
        }
    }

    func sendNotification(method: String, params: [String: Any]? = nil) throws {
        condition.lock(); defer { condition.unlock() }
        guard terminalError == nil, process?.isRunning == true else { throw RPCError(message: "Codex App Server is unavailable") }
        var frame: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let params { frame["params"] = params }
        try write(frame)
    }

    func stop() {
        condition.lock(); defer { condition.unlock() }
        failLocked(RPCError(message: "Codex App Server stopped"))
    }

    private func failLocked(_ error: Error, preserveNotifications: Bool = false) {
        terminalError = error
        generation = UUID()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        process = nil
        try? input?.close()
        input = nil
        responseWaiters.values.forEach { $0.resolve(.failure(error)) }
        responseWaiters.removeAll()
        approvalTasks.values.forEach { $0.cancel() }
        approvalTasks.removeAll()
        approvalTurns.removeAll()
        if !preserveNotifications { notifications.removeAll() }
        condition.broadcast()
    }

    private func write(_ frame: [String: Any]) throws {
        guard let input else { throw RPCError(message: "Codex App Server is unavailable") }
        try input.write(contentsOf: JSONSerialization.data(withJSONObject: frame) + Data([0x0A]))
    }

    private func readFrames(from output: FileHandle, generation expected: UUID) {
        defer { try? output.close() }
        var buffer = Data()
        do {
            while true {
                condition.lock()
                let current = generation == expected && terminalError == nil
                condition.unlock()
                guard current else { return }
                // Poll instead of an unbounded availableData read: descendants
                // may retain stdout after the App Server exits or is canceled.
                var descriptor = pollfd(fd: output.fileDescriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                let ready = poll(&descriptor, 1, 250)
                if ready == 0 {
                    condition.lock()
                    let exited = process?.isRunning != true
                    condition.unlock()
                    if exited { throw RPCError(message: "Codex App Server exited") }
                    continue
                }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw RPCError(message: "Codex App Server output failed")
                }
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let count = Darwin.read(output.fileDescriptor, &bytes, bytes.count)
                if count == 0 { throw RPCError(message: "Codex App Server exited") }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw RPCError(message: "Codex App Server output failed")
                }
                buffer.append(contentsOf: bytes.prefix(count))
                guard buffer.count <= 40 * 1024 * 1024 else { throw RPCError(message: "Codex App Server frame exceeded size limit") }
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = Data(buffer.prefix(upTo: newline))
                    buffer.removeSubrange(...newline)
                    if line.isEmpty { continue }
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw RPCError(message: "Codex App Server emitted an invalid frame") }
                    receive(object, generation: expected)
                }
            }
        } catch {
            condition.lock(); defer { condition.unlock() }
            if generation == expected { failLocked(error, preserveNotifications: true) }
        }
    }

    private func receive(_ object: [String: Any], generation expected: UUID) {
        condition.lock(); defer { condition.unlock() }
        guard generation == expected, terminalError == nil else { return }
        if let method = object["method"] as? String, let id = object["id"] {
            handleServerRequest(method: method, id: id, params: object["params"] as? [String: Any] ?? [:], generation: expected)
        } else if let id = (object["id"] as? NSNumber)?.intValue, let waiter = responseWaiters.removeValue(forKey: id) {
            if let error = object["error"] as? [String: Any] {
                let code = (error["code"] as? NSNumber)?.intValue ?? -1
                // Server messages can include URLs or credentials; keep them out of logs/UI.
                let message = (error["message"] as? String ?? "").lowercased()
                let safeReason = ["already has an active writer", "expected ordinal", "thread not found", "no rollout found", "rollout not found", "context window exceeded"].first(where: message.contains)
                waiter.resolve(.failure(RPCError(message: "Codex App Server request failed (\(code))" + (safeReason.map { ": " + $0 } ?? ""))))
            } else { waiter.resolve(.success(object["result"] ?? NSNull())) }
        } else if let method = object["method"] as? String {
            // Only buffer events that have a consumer. Lifecycle/status chatter
            // otherwise grows without bound in a long-lived menu-bar process.
            let consumedMethods: Set<String> = ["item/agentMessage/delta", "item/completed", "turn/completed", "thread/compacted"]
            guard consumedMethods.contains(method) else { return }
            guard notifications.count < 20_000 else { failLocked(RPCError(message: "Codex event buffer exceeded limit")); return }
            if method == "turn/completed", let params = object["params"] as? [String: Any],
               let turnID = (params["turn"] as? [String: Any])?["id"] as? String {
                for key in approvalTurns.filter({ $0.value == turnID }).map(\.key) {
                    approvalTasks.removeValue(forKey: key)?.cancel()
                    approvalTurns.removeValue(forKey: key)
                }
            }
            notifications.append(object)
            condition.broadcast()
        }
    }

    private func handleServerRequest(method: String, id: Any, params: [String: Any], generation expected: UUID) {
        if method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" {
            // No exact command/diff review UI is wired yet. Decline using the
            // protocol's ordinary decision so the worker can report a blocker.
            try? write(["jsonrpc": "2.0", "id": id, "result": ["decision": "decline"]])
            return
        }
        guard method == "mcpServer/elicitation/request" else {
            try? write(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Unsupported server request"]])
            return
        }
        guard let approvalHandler else {
            // No human decision was collected. A decline can be persisted as a
            // user preference by the provider, so unsupported clients cancel.
            try? write(["jsonrpc": "2.0", "id": id, "result": ["action": "cancel"]])
            return
        }
        let meta = params["_meta"] as? [String: Any] ?? params["meta"] as? [String: Any] ?? [:]
        let connectionSetup = CodexConnectionSetup.parse(params)
        if params["mode"] as? String == "url", params["serverName"] as? String == "codex_apps", connectionSetup == nil {
            try? write(["jsonrpc": "2.0", "id": id, "result": ["action": "cancel"]])
            return
        }
        let key = String(describing: id)
        guard approvalTasks[key] == nil else { return }
        let request = CodexApprovalRequest(requestID: key, method: method,
            threadID: params["threadId"] as? String, turnID: params["turnId"] as? String,
            message: params["message"] as? String ?? "Approval requested",
            origin: params["url"] as? String ?? meta["origin"] as? String,
            connector: meta["connector_id"] as? String, tool: meta["tool_name"] as? String, expiresAt: Date().addingTimeInterval(approvalTimeout), mode: params["mode"] as? String,
            isEmptyBrowserOriginForm: params["mode"] as? String == "form"
                && meta["connector_id"] as? String == "browser-use"
                && meta["tool_name"] as? String == "access_browser_origin"
                && CodexApprovalRequest.isEmptyOriginSchema(params["requestedSchema"]),
            nativeAppName: CodexApprovalRequest.validatedNativeAppName(in: params), connectionSetup: connectionSetup)
        // Log only classification, never prompt, origin, form contents, or tokens.
        SteveLog.write("Codex approval observed url=\(request.mode == "url") emptyBrowserForm=\(request.isEmptyBrowserOriginForm) nativeAppForm=\(request.nativeAppName != nil) unknownForm=\(request.mode == "form" && !request.isEmptyBrowserOriginForm && request.nativeAppName == nil) threadBound=\(request.threadID != nil) turnBound=\(request.turnID != nil)")
        if request.mode == "form", request.nativeAppName == nil, !request.isEmptyBrowserOriginForm {
            let knownParams = Set(params.keys).isSubset(of: ["threadId", "turnId", "serverName", "mode", "message", "requestedSchema", "_meta", "meta"])
            let knownMeta = Set(meta.keys).isSubset(of: ["persist", "connector_id", "connector_name", "tool_name", "tool_title", "tool_params", "tool_params_display", "codex_approval_kind", "codex_request_type"])
            let modernKind = meta["codex_approval_kind"] as? String == "mcp_tool_call"
            let nativeConnector = (meta["connector_id"] as? String).map(CodexApprovalRequest.isNativeConnector) ?? false
            let nativeServer = params["serverName"] as? String == "computer-use"
            let emptySchema = CodexApprovalRequest.isEmptyOriginSchema(params["requestedSchema"])
            let persistAlways = (meta["persist"] as? [String])?.contains("always") == true
            let nativePrompt = (request.message.hasPrefix("Allow Codex to use ") || request.message.hasPrefix("Allow ChatGPT to use ")) && request.message.hasSuffix("?")
            SteveLog.write("Codex unsupported approval shape modernKind=\(modernKind) nativeConnector=\(nativeConnector) nativeServer=\(nativeServer) knownParams=\(knownParams) knownMeta=\(knownMeta) emptySchema=\(emptySchema) persistAlways=\(persistAlways) nativePrompt=\(nativePrompt)")
            if (modernKind && nativeConnector) || nativeServer {
                SteveLog.write("Codex native approval structure " + CodexApprovalRequest.nativeApprovalShape(in: params))
            }
        }
        approvalTurns[key] = request.turnID
        approvalTasks[key] = Task { [weak self] in
            let decision = await approvalHandler(request)
            guard !Task.isCancelled else { return }
            // Unsupported data-entry forms cannot become grants even if a
            // generic embedding handler mistakenly returns accept.
            let unsupportedForm = request.mode == "form" && !request.isEmptyBrowserOriginForm && request.nativeAppName == nil
            self?.finishApproval(id: id, key: key, decision: (unsupportedForm || request.connectionSetup != nil) && decision == .accept ? .cancel : decision,
                                 generation: expected, nativeAppForm: request.nativeAppName != nil)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + approvalTimeout) { [weak self] in
            self?.finishApproval(id: id, key: key, decision: .cancel, generation: expected)
        }
    }

    private func finishApproval(id: Any, key: String, decision: CodexApprovalDecision, generation expected: UUID, nativeAppForm: Bool = false) {
        condition.lock(); defer { condition.unlock() }
        guard generation == expected, terminalError == nil, let task = approvalTasks.removeValue(forKey: key) else { return }
        task.cancel()
        approvalTurns.removeValue(forKey: key)
        var result: [String: Any] = ["action": decision.rawValue]
        if nativeAppForm && decision == .accept {
            result["content"] = [String: String]()
            result["_meta"] = ["persist": "session"]
        }
        try? write(["jsonrpc": "2.0", "id": id, "result": result])
    }

    // Called with the condition locked. Test overrides launch only deterministic
    // fixture processes; production always resolves the installed Codex binary.
    private func startIfNeeded() throws {
        if process?.isRunning == true, terminalError == nil { return }
        let process = Process()
        let inputPipe = Pipe(), outputPipe = Pipe(), errorPipe = Pipe()
        process.executableURL = try executableOverride ?? resolveCodex()
        var environment = CodexComputerUseRuntime.sanitizedEnvironment(ProcessInfo.processInfo.environment)
        if executableOverride != nil { process.arguments = argumentsOverride }
        else if let computerUse = CodexComputerUseRuntime.discover() {
            process.arguments = ["-c", "mcp_servers.computer-use=\(computerUse.serverConfiguration)", "app-server"]
            environment["CODEX_HOME"] = computerUse.codexHome
        } else { process.arguments = ["app-server"] }
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        // Drain stderr without persisting potentially sensitive provider output.
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            if handle.availableData.isEmpty { handle.readabilityHandler = nil }
        }
        try process.run()
        self.process = process
        input = inputPipe.fileHandleForWriting
        terminalError = nil
        notifications.removeAll()
        generation = UUID()
        let currentGeneration = generation
        DispatchQueue(label: "Steve.Codex.stdout").async { [weak self] in
            self?.readFrames(from: outputPipe.fileHandleForReading, generation: currentGeneration)
        }
    }

    private func resolveCodex() throws -> URL {
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex", "/usr/bin/codex"
        ]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw RPCError(message: "Codex is not installed in a supported location")
        }
        return URL(fileURLWithPath: path)
    }
}

actor CodexAppServerClient {
    private static let autoCompactionTokenLimit = 100_000
    private let connection = CodexRPCConnection()
    private var initialized = false
    private var initializationTask: Task<Void, Error>?
    private var lifecycle = UUID()
    private var requestInFlight = false
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []

    func stop() {
        lifecycle = UUID()
        initializationTask?.cancel()
        initializationTask = nil
        connection.stop()
        initialized = false
    }

    func setApprovalHandler(_ handler: CodexApprovalHandler?) { connection.setApprovalHandler(handler) }

    func accountRead() async throws -> AccountSnapshot {
        try await ensureInitialized()
        return try await call("account/read", params: ["refreshToken": false])
    }

    func loginStart() async throws -> LoginSnapshot {
        try await ensureInitialized()
        return try await call("account/login/start", params: [
            "type": "chatgpt",
            "useHostedLoginSuccessPage": false
        ])
    }

    func listModels() async throws -> [ModelEntry] {
        try await ensureInitialized()
        var cursor: String?
        var models: [ModelEntry] = []
        repeat {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result: Page<ModelEntry> = try await call("model/list", params: params)
            models.append(contentsOf: result.data)
            cursor = result.nextCursor
        } while cursor != nil
        return models
    }

    func listPermissionProfiles(cwd: String) async throws -> [PermissionProfile] {
        try await ensureInitialized()
        var cursor: String?
        var profiles: [PermissionProfile] = []
        repeat {
            var params: [String: Any] = ["cwd": cwd, "limit": 100]
            if let cursor { params["cursor"] = cursor }
            let result: Page<PermissionProfile> = try await call("permissionProfile/list", params: params)
            profiles.append(contentsOf: result.data)
            cursor = result.nextCursor
        } while cursor != nil
        return profiles
    }

    func rateLimitsRead() async throws -> Usage {
        try await ensureInitialized()
        let raw: RawUsage = try await call("account/rateLimits/read")
        return raw.rateLimits ?? Usage(primary: raw.primary, secondary: raw.secondary)
    }

    func startThread(cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool = false, serviceTier: SteveServiceTier = .standard) async throws -> String {
        let overrides = isRelay ? try await relayToolOverrides(cwd: cwd) : [:]
        let result = try await threadRequest(
            method: "thread/start",
            params: threadParams(cwd: cwd, permissionProfile: permissionProfile, model: model, developerInstructions: developerInstructions, toolOverrides: overrides, serviceTier: serviceTier)
        )
        try Self.verifyServiceTier(result, requested: serviceTier)
        guard let id = result["thread"] as? [String: Any], let threadID = id["id"] as? String else {
            throw RPCError(message: "Codex did not return a thread id")
        }
        return threadID
    }

    func resumeThread(threadID: String, cwd: String, permissionProfile: String, model: String, developerInstructions: String, isRelay: Bool = false, serviceTier: SteveServiceTier = .standard) async throws {
        let overrides = isRelay ? try await relayToolOverrides(cwd: cwd) : [:]
        let result = try await threadRequest(
            method: "thread/resume",
            params: threadParams(
                cwd: cwd,
                permissionProfile: permissionProfile,
                model: model,
                developerInstructions: developerInstructions,
                threadID: threadID,
                toolOverrides: overrides,
                serviceTier: serviceTier
            )
        )
        try Self.verifyServiceTier(result, requested: serviceTier)
    }

    private func relayToolOverrides(cwd: String) async throws -> [String: Any] {
        try await ensureInitialized()
        let response = try await requestObject("config/read", params: ["cwd": cwd, "includeLayers": false])
        guard let config = response["config"] as? [String: Any] else {
            throw RPCError(message: "Cannot verify relay tool configuration")
        }
        return Self.relayToolOverrides(effectiveConfig: config)
    }

    nonisolated static func relayToolOverrides(effectiveConfig: [String: Any]) -> [String: Any] {
        var overrides: [String: Any] = [
            "features.shell_tool": false,
            "web_search": "disabled",
            "tools.web_search": false,
            "tools.view_image": false
        ]
        for section in ["mcp_servers", "plugins", "apps"] {
            var disabled: [String: Any] = [:]
            for key in (effectiveConfig[section] as? [String: Any] ?? [:]).keys {
                disabled[key] = ["enabled": false]
            }
            if section == "apps" { disabled["_default"] = ["enabled": false] }
            if section == "mcp_servers" { disabled["computer-use"] = ["enabled": false] }
            overrides[section] = disabled
        }
        // App Server deep-merges nested tables. Quoting names in dotted keys
        // creates literal quote-containing server names in current releases.
        // Do not round-trip effective config values: null optional fields cannot
        // be converted back to TOML, and may include private configuration.
        // Workspace-managed/injected tools still need live catalog validation.
        return overrides
    }

    func compactThread(threadID: String) async throws {
        try await ensureInitialized()
        _ = try await request("thread/compact/start", params: ["threadId": threadID])
        let connection = self.connection
        let currentLifecycle = lifecycle
        await acquireRequestSlot()
        do {
            try Task.checkCancellation()
            guard lifecycle == currentLifecycle else { throw CancellationError() }
            try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try connection.waitForCompaction(threadID: threadID)
                    }
                    defer { group.cancelAll() }
                    try await group.next()!
                }
            }, onCancel: {
                connection.stop()
            })
            releaseRequestSlot()
            SteveLog.write("Codex thread compacted thread=\(threadID)")
        } catch {
            releaseRequestSlot()
            if lifecycle == currentLifecycle {
                connection.stop()
                initialized = false
            }
            throw error
        }
    }

    func runTurn(
        threadID: String,
        text: String,
        attachmentPaths: [String] = [],
        workspace: String? = nil,
        model: String,
        effort: String,
        serviceTier: SteveServiceTier = .standard,
        onTurnStarted: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> CodexTurnResult {
        try await ensureInitialized()
        let input = try userInput(text: text, attachmentPaths: attachmentPaths)
        let result: Any = try await request("turn/start", params: [
            "threadId": threadID,
            "input": input,
            "model": model,
            "effort": effort,
            "serviceTier": serviceTier.wireValue
        ])
        guard let turn = (result as? [String: Any])?["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw RPCError(message: "Codex did not return a turn id")
        }
        await onTurnStarted(turnID)
        let output = try await waitForTurn(threadID: threadID, turnID: turnID, workspace: workspace)
        if output.wasInterrupted {
            throw CodexTurnInterrupted()
        }
        guard !output.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !output.attachments.isEmpty else {
            throw RPCError(message: "Codex completed without an agent message")
        }
        return output
    }

    func interruptTurn(threadID: String, turnID: String) async throws {
        let connection = self.connection
        _ = try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Any.self) { group in
                group.addTask {
                    try connection.requestWhileStreaming(method: "turn/interrupt", params: [
                        "threadId": threadID,
                        "turnId": turnID
                    ])
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }, onCancel: {
            connection.stop()
        })
        SteveLog.write("Codex turn interrupt requested thread=\(threadID) turn=\(turnID)")
    }

    func steerTurn(
        threadID: String,
        expectedTurnID: String,
        text: String,
        attachmentPaths: [String] = []
    ) async throws {
        try await ensureInitialized()
        let input = try userInput(text: text, attachmentPaths: attachmentPaths)
        let connection = self.connection
        _ = try await withTaskCancellationHandler(operation: {
            try await withThrowingTaskGroup(of: Any.self) { group in
                group.addTask {
                    try connection.requestWhileStreaming(method: "turn/steer", params: [
                        "threadId": threadID,
                        "expectedTurnId": expectedTurnID,
                        "input": input
                    ])
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        }, onCancel: {
            connection.stop()
        })
    }

    private func userInput(text: String, attachmentPaths: [String]) throws -> [[String: Any]] {
        var input: [[String: Any]] = []
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedText.isEmpty {
            input.append(["type": "text", "text": text])
        }

        for path in attachmentPaths {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: path)
            else { continue }
            let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)
            if type?.conforms(to: .image) == true {
                input.append(["type": "localImage", "path": path])
            } else if type?.conforms(to: .audio) == true {
                input.append(["type": "localAudio", "path": path])
            }
        }

        guard !input.isEmpty else {
            throw RPCError(message: "The message did not contain readable text or supported media")
        }
        SteveLog.write("Codex user input prepared text=\(trimmedText.isEmpty ? 0 : 1) media=\(input.count - (trimmedText.isEmpty ? 0 : 1))")
        return input
    }

    private func ensureInitialized() async throws {
        try Task.checkCancellation()
        if initialized && connection.isRunning { return }
        if let initializationTask { return try await initializationTask.value }
        let currentLifecycle = lifecycle
        let task = Task {
            _ = try await self.request("initialize", params: [
                "clientInfo": ["name": "steve", "version": "0.1.0"],
                "capabilities": ["experimentalApi": true]
            ])
            try Task.checkCancellation()
            try self.connection.sendNotification(method: "initialized")
        }
        initializationTask = task
        do {
            try await task.value
            guard lifecycle == currentLifecycle else { throw CancellationError() }
            initialized = true
            initializationTask = nil
        } catch {
            if lifecycle == currentLifecycle {
                initializationTask = nil
                initialized = false
                connection.stop()
            }
            throw error
        }
    }

    private func threadRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        try await ensureInitialized()
        return try await requestObject(method, params: params)
    }

    func threadParams(cwd: String, permissionProfile: String, model: String, developerInstructions: String, threadID: String? = nil, toolOverrides: [String: Any] = [:], serviceTier: SteveServiceTier = .standard) throws -> [String: Any] {
        let (sandbox, approvalPolicy) = try permissionContext(permissionProfile)
        var params: [String: Any] = [
            "cwd": cwd,
            "model": model,
            "approvalPolicy": approvalPolicy,
            "sandbox": sandbox,
            "developerInstructions": developerInstructions,
            "serviceTier": serviceTier.wireValue,
            "config": [
                "service_tier": serviceTier.wireValue,
                // App Server 0.153 requires this capability gate even when the
                // explicit requested tier is Standard/default.
                "features.fast_mode": true,
                "model_auto_compact_token_limit": Self.autoCompactionTokenLimit,
                "model_auto_compact_token_limit_scope": "total"
            ]
        ]
        if var config = params["config"] as? [String: Any] {
            config.merge(toolOverrides) { _, restricted in restricted }
            params["config"] = config
        }
        SteveLog.write("Codex automatic compaction configured threshold=\(Self.autoCompactionTokenLimit)")
        if let threadID { params["threadId"] = threadID }
        return params
    }

    nonisolated static func verifyServiceTier(_ response: [String: Any], requested: SteveServiceTier) throws {
        guard let actual = response["serviceTier"] as? String,
              actual == requested.resolvedValue || actual == requested.wireValue else {
            throw RPCError(message: "Codex did not confirm the requested service tier; the task was not started.")
        }
        SteveLog.write("Codex service tier confirmed requested=\(requested.rawValue) resolved=\(actual)")
    }

    private func permissionContext(_ profile: String) throws -> (String, String) {
        let normalized = profile.trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
        switch normalized {
        case "read-only": return ("read-only", "never")
        case "workspace-write": return ("workspace-write", "on-request")
        case "danger-full-access": return ("danger-full-access", "on-request")
        default: throw RPCError(message: "Unsupported permission profile: \(profile)")
        }
    }

    private func call<T: Decodable>(_ method: String, params: [String: Any]? = nil) async throws -> T {
        let value = try await request(method, params: params)
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func requestObject(_ method: String, params: [String: Any]) async throws -> [String: Any] {
        let value = try await request(method, params: params)
        guard let object = value as? [String: Any] else { throw RPCError(message: "Invalid \(method) response") }
        return object
    }

    private func request(_ method: String, params: [String: Any]? = nil) async throws -> Any {
        let connection = self.connection
        let currentLifecycle = lifecycle
        await acquireRequestSlot()
        do {
            try Task.checkCancellation()
            guard lifecycle == currentLifecycle else { throw CancellationError() }
            let value = try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: Any.self) { group in
                    group.addTask { try connection.request(method: method, params: params, allowStart: method == "initialize") }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            }, onCancel: {
                connection.stop()
            })
            releaseRequestSlot()
            return value
        } catch {
            releaseRequestSlot()
            if lifecycle == currentLifecycle {
                connection.stop()
                initialized = false
            }
            throw error
        }
    }

    private func waitForTurn(
        threadID: String,
        turnID: String,
        workspace: String?
    ) async throws -> CodexTurnResult {
        let connection = self.connection
        let currentLifecycle = lifecycle
        await acquireRequestSlot()
        do {
            try Task.checkCancellation()
            guard lifecycle == currentLifecycle else { throw CancellationError() }
            let value = try await withTaskCancellationHandler(operation: {
                try await withThrowingTaskGroup(of: CodexTurnResult.self) { group in
                    group.addTask {
                        try await connection.waitForTurn(
                            threadID: threadID,
                            turnID: turnID,
                            workspace: workspace
                        )
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
            }, onCancel: {
                connection.stop()
            })
            releaseRequestSlot()
            return value
        } catch {
            releaseRequestSlot()
            if lifecycle == currentLifecycle {
                connection.stop()
                initialized = false
            }
            throw error
        }
    }

    private func acquireRequestSlot() async {
        guard requestInFlight else {
            requestInFlight = true
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            requestWaiters.append(continuation)
        }
    }

    private func releaseRequestSlot() {
        if let waiter = requestWaiters.first {
            requestWaiters.removeFirst()
            waiter.resume()
        } else {
            requestInFlight = false
        }
    }
}

private struct Page<T: Decodable>: Decodable {
    let data: [T]
    let nextCursor: String?
}

private struct RawUsage: Decodable {
    let rateLimits: Usage?
    let primary: RateWindow?
    let secondary: RateWindow?

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try container.decodeIfPresent(Usage.self, forKey: .rateLimits)
        primary = try container.decodeIfPresent(RateWindow.self, forKey: .primary)
        secondary = try container.decodeIfPresent(RateWindow.self, forKey: .secondary)
    }

    private enum CodingKeys: String, CodingKey { case rateLimits, primary, secondary }
}
