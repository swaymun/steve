import XCTest
@testable import SteveNative

final class ServiceTierTests: XCTestCase {
    func testLegacySettingsDefaultToStandardAndFastRoundTrips() throws {
        let legacy = Data(#"{"displayName":"Fixture","model":"fixture","effort":"xhigh"}"#.utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: legacy)
        XCTAssertEqual(settings.serviceTier, .standard)
        settings.serviceTier = .fast
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.serviceTier, .fast)
        let invalid = Data(#"{"displayName":"Fixture","model":"fixture","effort":"xhigh","serviceTier":"auto"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: invalid))
    }

    func testSetupParsesExplicitServiceTier() throws {
        let (request, json, _) = try SteveCLI.parse(["setup", "--service-tier", "fast", "--json"])
        XCTAssertEqual(request.options["service-tier"], "fast")
        XCTAssertTrue(json)
        XCTAssertThrowsError(try SteveCLI.parse(["setup", "--service-tier"]))
    }

    func testThreadStartAndResumeOverrideAmbientTierAndRequireConfirmation() async throws {
        let client = CodexAppServerClient()
        for tier in SteveServiceTier.allCases {
            for id: String? in [nil, "existing-thread"] {
                let params = try await client.threadParams(cwd: "/fixture", permissionProfile: "read-only", model: "fixture", developerInstructions: "fixture", threadID: id, serviceTier: tier)
                XCTAssertEqual(params["serviceTier"] as? String, tier.wireValue)
                let config = try XCTUnwrap(params["config"] as? [String: Any])
                XCTAssertEqual(config["service_tier"] as? String, tier.wireValue)
                XCTAssertEqual(config["features.fast_mode"] as? Bool, tier == .fast)
                XCTAssertNoThrow(try CodexAppServerClient.verifyServiceTier(["serviceTier": tier.resolvedValue], requested: tier))
                XCTAssertThrowsError(try CodexAppServerClient.verifyServiceTier([:], requested: tier))
            }
        }
        XCTAssertThrowsError(try CodexAppServerClient.verifyServiceTier(["serviceTier": "default"], requested: .fast))
        XCTAssertThrowsError(try CodexAppServerClient.verifyServiceTier(["serviceTier": "priority"], requested: .standard))
    }
}
