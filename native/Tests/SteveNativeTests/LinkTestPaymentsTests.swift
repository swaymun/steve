import Foundation
import XCTest
@testable import SteveNative

private actor LinkFixtureRunner {
    var calls: [[String]] = []
    var failCreation = false
    func failNextCreation() { failCreation = true }
    func run(_ arguments: [String]) throws -> SteveProcess.Result {
        calls.append(arguments)
        if arguments.contains("--schema") { return SteveProcess.Result(code: 0, output: Data(#"{"options":{"properties":{"test":{},"idempotencyKey":{},"requestApproval":{}}}}"#.utf8)) }
        if arguments.starts(with: ["auth", "status"]) { return SteveProcess.Result(code: 0, output: Data(#"{"authenticated":true,"access_token":"fixture-secret-not-for-output","phrase":"private-fixture"}"#.utf8)) }
        if arguments.contains("create") && failCreation { failCreation = false; throw LinkTestPaymentError.unavailable }
        return SteveProcess.Result(code: 0, output: Data(#"{"id":"lsrq_fixture","status":"created","card":{"number":"fixture-sensitive"},"link_pay_token":"fixture-token","_next":{"command":"untrusted command"}}"#.utf8))
    }
    func creations() -> [[String]] { calls.filter { $0.contains("create") && !$0.contains("--schema") } }
}

final class LinkTestPaymentsTests: XCTestCase {
    private let envelope = LinkPurchaseEnvelope(merchantName: "Fixture Shop", merchantURL: "https://shop.example", items: [.init(name: "Fixture book", quantity: 2, unitAmount: 1000)], shipping: 100, tax: 200, amount: 2300, currency: "usd")
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("Steve-Link-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private func approval(_ operation: UUID = UUID()) throws -> LinkTestApproval {
        LinkTestApproval(operationID: operation, envelopeFingerprint: try envelope.fingerprint(), expiresAt: Date().addingTimeInterval(300))
    }

    func testTestOnlyArgumentsAndAllowlistedOutput() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LinkFixtureRunner()
        let client = LinkTestPayments(journalURL: directory.appendingPathComponent("journal.json"), runner: { try await fixture.run($0) })
        let request = try await client.createTestRequest(envelope, approval: approval())
        XCTAssertEqual(request, LinkTestRequest(id: "lsrq_fixture", status: .created))
        let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-sensitive"))
        XCTAssertFalse(encoded.contains("fixture-token"))
        XCTAssertFalse(encoded.contains("untrusted"))
        let calls = await fixture.creations()
        let arguments = try XCTUnwrap(calls.first)
        XCTAssertTrue(arguments.contains("--test"))
        XCTAssertTrue(arguments.contains("--no-request-approval"))
        XCTAssertTrue(arguments.contains("--idempotency-key"))
        XCTAssertFalse(arguments.contains("--approve"))
        XCTAssertFalse(arguments.contains("--include"))
        XCTAssertFalse(arguments.contains("pay"))
        let authenticated = try await client.authenticated()
        XCTAssertTrue(authenticated)
    }

    func testKnownOperationDoesNotCreateTwiceAcrossClients() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LinkFixtureRunner(), journal = directory.appendingPathComponent("journal.json")
        let receipt = try approval()
        let first = LinkTestPayments(journalURL: journal, runner: { try await fixture.run($0) })
        _ = try await first.createTestRequest(envelope, approval: receipt)
        let second = LinkTestPayments(journalURL: journal, runner: { try await fixture.run($0) })
        _ = try await second.createTestRequest(envelope, approval: receipt)
        let calls = await fixture.creations()
        XCTAssertEqual(calls.count, 1)
        let data = try Data(contentsOf: journal)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Fixture Shop"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("fixture-sensitive"))
    }

    func testAmbiguousRetryUsesSameUpstreamKeyAndRequiresExplicitRetry() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LinkFixtureRunner(), journal = directory.appendingPathComponent("journal.json")
        await fixture.failNextCreation()
        let client = LinkTestPayments(journalURL: journal, runner: { try await fixture.run($0) })
        let receipt = try approval()
        do { _ = try await client.createTestRequest(envelope, approval: receipt); XCTFail("Ambiguous result") } catch { XCTAssertEqual(error as? LinkTestPaymentError, .ambiguous) }
        do { _ = try await client.createTestRequest(envelope, approval: receipt); XCTFail("Cannot automatically retry") } catch { XCTAssertEqual(error as? LinkTestPaymentError, .ambiguous) }
        _ = try await client.createTestRequest(envelope, approval: receipt, retryAmbiguous: true)
        let calls = await fixture.creations()
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0], calls[1])
    }

    func testChangedOrExpiredApprovalCannotInvokeCLI() async throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = LinkFixtureRunner()
        let client = LinkTestPayments(journalURL: directory.appendingPathComponent("journal.json"), runner: { try await fixture.run($0) })
        for receipt in [LinkTestApproval(operationID: UUID(), envelopeFingerprint: "wrong", expiresAt: Date().addingTimeInterval(300)), LinkTestApproval(operationID: UUID(), envelopeFingerprint: try envelope.fingerprint(), expiresAt: Date().addingTimeInterval(-1))] {
            do { _ = try await client.createTestRequest(envelope, approval: receipt); XCTFail("Must reject invalid approval") } catch { }
        }
        let calls = await fixture.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testEnvelopeRejectsParserInjectionAndMismatchedTotal() {
        let bad = LinkPurchaseEnvelope(merchantName: "Fixture", merchantURL: "https://shop.example", items: [.init(name: "book,quantity:99", quantity: 1, unitAmount: 100)], shipping: 0, tax: 0, amount: 100, currency: "usd")
        XCTAssertThrowsError(try bad.validate())
        let mismatched = LinkPurchaseEnvelope(merchantName: "Fixture", merchantURL: "https://shop.example", items: [.init(name: "book", quantity: 1, unitAmount: 100)], shipping: 0, tax: 0, amount: 101, currency: "usd")
        XCTAssertThrowsError(try mismatched.validate())
    }

    func testEnvironmentDropsCredentialsAndEndpointOverrides() {
        let result = LinkTestPayments.safeEnvironment(["HOME": "/fixture", "PATH": "/usr/bin", "LINK_ACCESS_TOKEN": "fixture", "LINK_AUTH_FILE": "/private", "LINK_API_BASE_URL": "https://attacker.invalid", "HTTP_PROXY": "https://attacker.invalid", "NODE_OPTIONS": "--require /tmp/unsafe"])
        XCTAssertEqual(result["HOME"], "/fixture")
        for key in ["LINK_ACCESS_TOKEN", "LINK_AUTH_FILE", "LINK_API_BASE_URL", "HTTP_PROXY", "NODE_OPTIONS"] { XCTAssertNil(result[key]) }
    }
}
