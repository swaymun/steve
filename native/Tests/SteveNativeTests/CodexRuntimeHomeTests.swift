import Foundation
import XCTest
@testable import SteveNative

final class CodexRuntimeHomeTests: XCTestCase {
    private func fixture(_ body: (CodexRuntimeHome) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let home = CodexRuntimeHome(root: directory.appendingPathComponent("private"), shared: directory.appendingPathComponent("desktop"))
        try FileManager.default.createDirectory(at: home.shared, withIntermediateDirectories: true)
        try body(home)
    }

    func testSharesSetupButNeverDesktopHistoryAndPreservesPrivateSettings() throws {
        try fixture { home in
            let fm = FileManager.default
            for name in ["config.toml", "auth.json", ".credentials.json", "custom.config.toml", "state_5.sqlite", "history.jsonl"] {
                try Data("fixture".utf8).write(to: home.shared.appendingPathComponent(name))
            }
            for name in ["plugins", "skills", "rules", "sessions", "memories"] {
                try fm.createDirectory(at: home.shared.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            try home.prepare()
            for name in ["config.toml", "auth.json", ".credentials.json", "custom.config.toml", "plugins", "skills", "rules"] {
                XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: home.root.appendingPathComponent(name).path), home.shared.appendingPathComponent(name).path)
            }
            XCTAssertFalse(fm.fileExists(atPath: home.root.appendingPathComponent("state_5.sqlite").path))
            XCTAssertFalse(fm.fileExists(atPath: home.root.appendingPathComponent("history.jsonl").path))
            XCTAssertEqual(try fm.attributesOfItem(atPath: home.root.path)[.posixPermissions] as? Int, 0o700)
            for name in ["sessions", "memories"] {
                XCTAssertEqual(try fm.attributesOfItem(atPath: home.root.appendingPathComponent(name).path)[.type] as? FileAttributeType, .typeDirectory)
            }
            try fm.removeItem(at: home.root.appendingPathComponent("auth.json"))
            try Data("private sign-in fixture".utf8).write(to: home.root.appendingPathComponent("auth.json"))
            try home.prepare()
            XCTAssertEqual(try String(contentsOf: home.root.appendingPathComponent("auth.json")), "private sign-in fixture")
            XCTAssertEqual(try String(contentsOf: home.shared.appendingPathComponent("auth.json")), "fixture")
        }
    }

    func testRejectsSharedStorageRootsAndLinks() throws {
        try fixture { home in
            let fm = FileManager.default
            XCTAssertThrowsError(try CodexRuntimeHome(root: home.shared, shared: home.shared).prepare())
            XCTAssertThrowsError(try CodexRuntimeHome(root: home.shared.appendingPathComponent("nested"), shared: home.shared).prepare())
            try fm.createSymbolicLink(at: home.root, withDestinationURL: home.shared)
            XCTAssertThrowsError(try home.prepare())
            try fm.removeItem(at: home.root)
            try home.prepare()
            try fm.removeItem(at: home.root.appendingPathComponent("sessions"))
            try fm.createSymbolicLink(at: home.root.appendingPathComponent("sessions"), withDestinationURL: home.shared)
            XCTAssertThrowsError(try home.prepare())
            try fm.removeItem(at: home.root.appendingPathComponent("sessions"))
            let sharedDB = home.shared.appendingPathComponent("state_5.sqlite")
            try Data("fixture".utf8).write(to: sharedDB)
            try fm.linkItem(at: sharedDB, to: home.root.appendingPathComponent("state_5.sqlite"))
            XCTAssertThrowsError(try home.prepare())
        }
    }

    func testOverridesInheritedDatabaseLocationAndKeepsComputerUseSeparate() throws {
        try fixture { home in
            let environment = home.environment(["CODEX_HOME": home.shared.path, "CODEX_SQLITE_HOME": "/wrong", "CODEX_THREAD_ID": "another-task", "PATH": "/usr/bin"])
            XCTAssertEqual(environment["CODEX_HOME"], home.root.path)
            XCTAssertEqual(environment["CODEX_SQLITE_HOME"], home.root.path)
            XCTAssertNil(environment["CODEX_THREAD_ID"])
            XCTAssertEqual(environment["PATH"], "/usr/bin")
            XCTAssertTrue(home.configurationArguments.contains("sqlite_home=\"" + home.root.path + "\""))
            let cua = CodexComputerUseRuntime(executablePath: "/native/client", codexHome: home.shared.path, workingDirectory: "/native")
            XCTAssertTrue(cua.serverConfiguration.contains("env={CODEX_HOME=\"" + home.shared.path + "\"}"))
            XCTAssertFalse(cua.serverConfiguration.contains(home.root.path))
            XCTAssertEqual(CodexRuntimeHome.tomlString("/a\\b\"c\nd"), "\"/a\\\\b\\\"c\\nd\"")
        }
    }

    func testRemovedSQLiteSidecarDoesNotPreventRestart() throws {
        try fixture { home in
            try home.prepare()
            let sidecar = home.root.appendingPathComponent("queue_1.sqlite-shm")
            try Data("temporary".utf8).write(to: sidecar)
            let enumerated = try FileManager.default.contentsOfDirectory(at: home.root, includingPropertiesForKeys: nil)
            XCTAssertTrue(enumerated.contains { $0.lastPathComponent == sidecar.lastPathComponent })
            try FileManager.default.removeItem(at: sidecar)
            XCTAssertNoThrow(try CodexRuntimeHome.validateStorageFile(sidecar))
            try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: home.shared.appendingPathComponent("missing.sqlite-shm"))
            XCTAssertThrowsError(try CodexRuntimeHome.validateStorageFile(sidecar), "A dangling storage link must still fail closed")
        }
    }

    func testImportsOnlyMatchingSteveRolloutOnceWithoutMovingOriginal() throws {
        try fixture { home in
            let id = UUID().uuidString.lowercased()
            let source = try writeRollout(id: id, originator: "steve", home: home.shared)
            let imported = try XCTUnwrap(home.importLegacyThread(id))
            XCTAssertNotEqual(source, imported)
            XCTAssertTrue(imported.path.hasPrefix(home.root.resolvingSymlinksInPath().path + "/sessions/"))
            XCTAssertEqual(try Data(contentsOf: source), try Data(contentsOf: imported))
            try Data("private continuation\n".utf8).append(to: imported)
            XCTAssertEqual(try home.importLegacyThread(id), imported)
            XCTAssertFalse(try String(contentsOf: source).contains("private continuation"))
            XCTAssertTrue(try String(contentsOf: imported).contains("private continuation"))
        }
    }

    func testDoesNotImportOtherOriginsMismatchedIDsOrSymlinks() throws {
        try fixture { home in
            let fm = FileManager.default
            let id = UUID().uuidString.lowercased()
            let source = try writeRollout(id: id, originator: "codex_desktop", home: home.shared)
            XCTAssertNil(try home.importLegacyThread(id))
            try fm.removeItem(at: source)
            let other = try writeRollout(id: UUID().uuidString.lowercased(), originator: "steve", home: home.shared)
            try fm.copyItem(at: other, to: source)
            XCTAssertNil(try home.importLegacyThread(id))
            try fm.removeItem(at: source)
            try fm.createSymbolicLink(at: source, withDestinationURL: other)
            XCTAssertNil(try home.importLegacyThread(id))
            XCTAssertNil(try home.importLegacyThread("../not-a-thread"))
        }
    }

    private func writeRollout(id: String, originator: String, home: URL) throws -> URL {
        let directory = home.appendingPathComponent("sessions/2026/09/20")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-2026-09-20-" + id + ".jsonl")
        var data = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": ["id": id, "originator": originator]])
        data.append(10)
        try data.write(to: file)
        return file
    }
}

private extension Data {
    func append(to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: self)
    }
}
