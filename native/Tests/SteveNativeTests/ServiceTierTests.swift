import XCTest
@testable import SteveNative

final class ServiceTierTests: XCTestCase {
    func testChangedAccessColdResumesSameThreadAndUnchangedAccessDoesNotUnload() async throws {
        let script = #"""
        loaded=0
        while IFS= read -r line; do
          id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
          [ -n "$id" ] || continue
          method=$(printf '%s' "$line" | sed -n 's/.*"method":"\([^"]*\)".*/\1/p' | tr -d '\\')
          case "$method" in
            initialize) result='{}' ;;
            thread/start) loaded=1; result='{"thread":{"id":"t"},"serviceTier":"default","sandbox":{"type":"readOnly"}}' ;;
            thread/loaded/list)
              if [ "$loaded" = 1 ]; then result='{"data":["t"]}'; else result='{"data":[]}'; fi ;;
            thread/read) result='{"thread":{"id":"t","turns":[]}}' ;;
            thread/unsubscribe) loaded=0; result='{"status":"unsubscribed"}' ;;
            thread/resume)
              if [ "$loaded" = 1 ]; then result='{"thread":{"id":"t"},"serviceTier":"default","sandbox":{"type":"readOnly"}}';
              else result='{"thread":{"id":"t"},"serviceTier":"default","sandbox":{"type":"workspaceWrite"}}'; fi ;;
            *) result='{}' ;;
          esac
          printf '{"id":%s,"result":%s}\n' "$id" "$result"
        done
        """#
        let connection = CodexRPCConnection(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], responseTimeout: 2)
        let client = CodexAppServerClient(connection: connection)
        addTeardownBlock { await client.stop() }
        let id = try await client.startThread(cwd: "/tmp", permissionProfile: "read-only", model: "fixture", developerInstructions: "fixture", serviceTier: .standard)
        try await client.resumeThread(threadID: id, cwd: "/tmp", permissionProfile: "read-only", model: "fixture", developerInstructions: "fixture", serviceTier: .standard)
        try await client.resumeThread(threadID: id, cwd: "/tmp", permissionProfile: "workspace-write", model: "fixture", developerInstructions: "updated", serviceTier: .standard)
        XCTAssertThrowsError(try CodexAppServerClient.verifySandbox(["sandbox": ["type": "dangerFullAccess"]], requested: "read-only"))
    }

    func testLegacyUTCDefaultUsesLocalTimeButExplicitZoneIsPreserved() throws {
        let local = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        XCTAssertEqual(StevePrompt.defaultTimeZone(configured: "UTC", local: local), "America/New_York")
        XCTAssertEqual(StevePrompt.defaultTimeZone(configured: "invalid", local: local), "America/New_York")
        XCTAssertEqual(StevePrompt.defaultTimeZone(configured: "America/Los_Angeles", local: local), "America/Los_Angeles")
    }
    func testFullAccessUsesNoCommandApprovalsOnStartAndResume() async throws {
        let client = CodexAppServerClient()
        for id: String? in [nil, "existing-thread"] {
            let full = try await client.threadParams(cwd: "/fixture", permissionProfile: ":danger-full-access", model: "fixture", developerInstructions: "fixture", threadID: id)
            XCTAssertEqual(full["sandbox"] as? String, "danger-full-access")
            XCTAssertEqual(full["approvalPolicy"] as? String, "never")
            let scoped = try await client.threadParams(cwd: "/fixture", permissionProfile: "workspace-write", model: "fixture", developerInstructions: "fixture", threadID: id)
            XCTAssertEqual(scoped["approvalPolicy"] as? String, "on-request")
        }
    }
    func testLegacySettingsDefaultToStandardAndFastRoundTrips() throws {
        let legacy = Data(#"{"displayName":"Fixture","model":"fixture","effort":"xhigh"}"#.utf8)
        var settings = try JSONDecoder().decode(Settings.self, from: legacy)
        XCTAssertEqual(settings.serviceTier, .standard)
        XCTAssertNil(settings.relayModel)
        XCTAssertEqual(settings.relayEffort, "low")
        XCTAssertEqual(settings.relayServiceTier, .standard)
        XCTAssertEqual(settings.maxConcurrentOperators, 2)
        XCTAssertEqual(settings.maxHelpersPerOperator, 1)
        settings.serviceTier = .fast
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded.serviceTier, .fast)
        let invalid = Data(#"{"displayName":"Fixture","model":"fixture","effort":"xhigh","serviceTier":"auto"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: invalid))
        for limits in [#""maxConcurrentOperators":0"#, #""maxConcurrentOperators":5"#, #""maxHelpersPerOperator":-1"#, #""maxHelpersPerOperator":3"#] {
            let data = Data("{\"displayName\":\"Fixture\",\"model\":\"fixture\",\"effort\":\"low\",\(limits)}".utf8)
            XCTAssertThrowsError(try JSONDecoder().decode(Settings.self, from: data))
        }
    }

    func testSetupParsesExplicitServiceTier() throws {
        let (request, json, _) = try SteveCLI.parse(["setup", "--service-tier", "fast", "--relay-model", "auto", "--relay-effort", "low", "--relay-service-tier", "standard", "--max-operators", "4", "--max-helpers", "0", "--json"])
        XCTAssertEqual(request.options["service-tier"], "fast")
        XCTAssertEqual(request.options["relay-model"], "auto")
        XCTAssertEqual(request.options["relay-effort"], "low")
        XCTAssertEqual(request.options["relay-service-tier"], "standard")
        XCTAssertEqual(request.options["max-operators"], "4")
        XCTAssertEqual(request.options["max-helpers"], "0")
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
                XCTAssertEqual(config["features.fast_mode"] as? Bool, true, "Standard also needs the tier-confirmation capability gate")
                XCTAssertNoThrow(try CodexAppServerClient.verifyServiceTier(["serviceTier": tier.resolvedValue], requested: tier))
                XCTAssertThrowsError(try CodexAppServerClient.verifyServiceTier([:], requested: tier))
            }
        }
        XCTAssertThrowsError(try CodexAppServerClient.verifyServiceTier(["serviceTier": "default"], requested: .fast))
        XCTAssertThrowsError(try CodexAppServerClient.verifyServiceTier(["serviceTier": "priority"], requested: .standard))
    }
    func testSavedUserTimezoneOverridesMacAndPreservesDaylightRules() {
        let provenance = ExplicitUserProvenance(source: .pairedMessage, sourceID: "zone", statement: "My timezone is PST", explicitlyRequested: true, recordedAt: Date())
        let preference = ExplicitPreference(key: "timezone", value: "PST", provenance: provenance, createdAt: Date(), updatedAt: Date())
        let zone = StevePrompt.userTimeZone(preferences: [preference], configured: "America/New_York")
        XCTAssertEqual(zone, "America/Los_Angeles")
        let date = ISO8601DateFormatter().date(from: "2026-09-20T12:00:00Z")!
        XCTAssertEqual(TimeZone(identifier: zone)?.abbreviation(for: date), "PDT")
        XCTAssertEqual(StevePrompt.userTimeZone(preferences: [], configured: "America/New_York"), "America/New_York")
    }

}
