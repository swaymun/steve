import XCTest
@testable import SteveNative

final class TailscaleRouteTests: XCTestCase {
    private let host = "fixture.test.ts.net"
    private func route(_ json: String, saved: String? = nil) throws -> TailscaleSetup.PhoneRoute {
        try TailscaleSetup.selectPhoneRoute(host: host, serveJSON: Data(json.utf8), existingOrigin: saved, existingPort: nil)
    }
    func testPreservesOtherRoutesAndChoosesUnusedPort() throws {
        let result = try route(#"{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:1234"}}}}}"#)
        XCTAssertEqual(result.httpsPort, 10000)
        XCTAssertEqual(result.target, "http://127.0.0.1:19887")
        XCTAssertEqual(result.origin.authority, host + ":10000")
    }
    func testRefusesConflictsFunnelAndChangedAccount() throws {
        let existing = "https://" + host + ":8443"
        XCTAssertThrowsError(try route(#"{"TCP":{"8443":{"HTTPS":true}}}"#, saved: existing))
        XCTAssertThrowsError(try route(#"{"AllowFunnel":{"fixture.test.ts.net:8443":true}}"#, saved: existing))
        XCTAssertThrowsError(try route("{}", saved: "https://other.test.ts.net:8443"))
        XCTAssertThrowsError(try route(#"{"TCP":{"8443":{"HTTPS":true},"10000":{"HTTPS":true}}}"#))
    }
    func testOnlyExactSavedRouteIsReused() throws {
        let json = #"{"TCP":{"8443":{"HTTPS":true}},"Web":{"fixture.test.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:19887"}}}}}"#
        XCTAssertEqual(try route(json, saved: "https://" + host + ":8443").httpsPort, 8443)
        XCTAssertEqual(try route(json).httpsPort, 10000)
        XCTAssertThrowsError(try PhoneTakeoverOrigin("https://" + host + ":8080"))
    }
}
