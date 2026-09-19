import XCTest
@testable import SteveNative

final class SteveControlTests: XCTestCase {
    func testNonInteractiveSetupHasNoImplicitMutations() throws {
        let (request, json, interactive) = try SteveCLI.parse(["setup", "--non-interactive", "--json"])
        XCTAssertEqual(request.command, "setup")
        XCTAssertTrue(request.options.isEmpty)
        XCTAssertTrue(json)
        XCTAssertFalse(interactive)
        XCTAssertThrowsError(try SteveCLI.parse(["status", "--workspace", "/tmp"]))
        XCTAssertThrowsError(try SteveCLI.parse(["setup", "--workspace", "--json"]))
        XCTAssertThrowsError(try SteveCLI.parse(["setup", "--approve-all"]))
    }

    func testExplicitSetupOptionsRoundTrip() throws {
        let (request, _, _) = try SteveCLI.parse(["setup", "--workspace", "/tmp/a folder", "--permission", "read-only", "--login", "--pair"])
        let decoded = try JSONDecoder().decode(SteveControlRequest.self, from: JSONEncoder().encode(request))
        XCTAssertEqual(decoded.options["workspace"], "/tmp/a folder")
        XCTAssertEqual(decoded.options["permission"], "read-only")
        XCTAssertEqual(decoded.options["login"], "true")
        XCTAssertEqual(decoded.options["pair"], "true")
    }

    func testSocketRejectsLongPaths() {
        XCTAssertThrowsError(try SteveControlSocket.address("/" + String(repeating: "x", count: 105)))
    }

    func testApprovalRequiresAnExplicitCurrentID() throws {
        XCTAssertThrowsError(try SteveCLI.parse(["approve", "--json"]))
        let (request, json, _) = try SteveCLI.parse(["deny", "TEST1234", "--json"])
        XCTAssertEqual(request.options, ["id": "TEST1234"])
        XCTAssertTrue(json)
        XCTAssertThrowsError(try SteveCLI.parse(["approve", "TEST1234", "second-id"]))
    }

    func testControlSocketUsesOwnerOnlyEndpointAndOneServer() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-" + UUID().uuidString.prefix(8))
        let path = directory.appendingPathComponent("socket").path
        defer { try? FileManager.default.removeItem(at: directory) }
        let server = try SteveLocalControlServer(path: path) { request in
            SteveControlResponse(state: "ready", summary: request.command)
        }
        defer { withExtendedLifetime(server) {} }
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try SteveLocalControlServer(path: path) { _ in SteveControlResponse(state: "failed", summary: "duplicate") })
        let response = try SteveControlSocket.request(SteveControlRequest(command: "status"), path: path)
        XCTAssertEqual(response.summary, "status")
        XCTAssertEqual(response.state, "ready")
    }

    func testControlSocketRejectsSharedDirectory() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sc-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try SteveLocalControlServer(path: directory.appendingPathComponent("socket").path) { _ in
            SteveControlResponse(state: "ready", summary: "no")
        })
    }
}
