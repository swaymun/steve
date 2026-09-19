import XCTest
@testable import SteveNative

final class SteveProcessTests: XCTestCase {
    func testArgumentsArePassedLiterallyWithoutShellExpansion() async throws {
        let result = try await SteveProcess.run(executable: "/bin/echo", arguments: ["$HOME; $(echo unexpected)"], environment: [:])
        XCTAssertEqual(result.code, 0)
        XCTAssertEqual(String(decoding: result.output, as: UTF8.self), "$HOME; $(echo unexpected)\n")
    }

    func testTimeoutTerminatesChild() async {
        let start = Date()
        do {
            _ = try await SteveProcess.run(executable: "/bin/sleep", arguments: ["10"], environment: [:], timeout: 0.05)
            XCTFail("Expected timeout")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellationStopsChild() async throws {
        let task = Task { try await SteveProcess.run(executable: "/bin/sleep", arguments: ["10"], environment: [:]) }
        try await Task.sleep(for: .milliseconds(50))
        let start = Date()
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testOutputIsBounded() async {
        do {
            _ = try await SteveProcess.run(executable: "/usr/bin/yes", arguments: ["fixture"], environment: [:])
            XCTFail("Expected output limit")
        } catch { XCTAssertTrue(error.localizedDescription.contains("too large")) }
    }
}
