import Foundation
import XCTest
@testable import SteveNative

private final class PhoneTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 2_000_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}

private actor PhoneFakeDesktop: PhoneDesktopControl {
    var captures = 0, inputs = 0, starts = 0, stops = 0
    var missing: [String] = []
    func missingPermissions() async -> [String] { missing }
    func start() async throws { starts += 1 }
    func frame() async throws -> PhoneTakeoverFrame {
        captures += 1
        return PhoneTakeoverFrame(id: "frame-\(captures)", jpeg: Data([0xFF, 0xD8, 0xFF, 0xD9]))
    }
    func apply(_ input: PhoneTakeoverInput) async throws { inputs += 1 }
    func stop() async { stops += 1 }
    func counts() -> [Int] { [starts, captures, inputs, stops] }
    func denyPermissions() { missing = ["Screen Recording"] }
}

private actor PhoneHookRecorder {
    var pauses = 0, resumes = 0, ends = 0
    func pause() { pauses += 1 }
    func resume() { resumes += 1 }
    func end() { ends += 1 }
    func counts() -> [Int] { [pauses, resumes] }
}

private actor PhoneDrainGate {
    var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
}

private actor PhoneStopGateDesktop: PhoneDesktopControl {
    private var waiter: CheckedContinuation<Void, Never>?
    private var stopCount = 0
    var firstStopEntered = false
    func missingPermissions() async -> [String] { [] }
    func start() async throws {}
    func frame() async throws -> PhoneTakeoverFrame { PhoneTakeoverFrame(id: "fixture", jpeg: Data()) }
    func apply(_ input: PhoneTakeoverInput) async throws {}
    func stop() async {
        stopCount += 1
        if stopCount == 1 {
            firstStopEntered = true
            await withCheckedContinuation { waiter = $0 }
        }
    }
    func releaseFirstStop() { waiter?.resume(); waiter = nil }
}

private actor PhonePermissionGateDesktop: PhoneDesktopControl {
    private var waiter: CheckedContinuation<Void, Never>?
    private var checkCount = 0
    var checking = false
    func missingPermissions() async -> [String] {
        checkCount += 1
        if checkCount == 1 {
            checking = true
            await withCheckedContinuation { waiter = $0 }
        }
        return []
    }
    func start() async throws {}
    func frame() async throws -> PhoneTakeoverFrame { PhoneTakeoverFrame(id: "fixture", jpeg: Data()) }
    func apply(_ input: PhoneTakeoverInput) async throws {}
    func stop() async {}
    func releaseCheck() { waiter?.resume(); waiter = nil }
}

private actor PhoneOverlappingStopDesktop: PhoneDesktopControl {
    private var stops = 0
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    func missingPermissions() async -> [String] { [] }
    func start() async throws {}
    func frame() async throws -> PhoneTakeoverFrame { PhoneTakeoverFrame(id: "fixture", jpeg: Data()) }
    func apply(_ input: PhoneTakeoverInput) async throws {}
    func stop() async {
        stops += 1
        let index = stops
        if index <= 2 { await withCheckedContinuation { waiters[index] = $0 } }
    }
    func stopCount() -> Int { stops }
    func release(_ index: Int) { waiters.removeValue(forKey: index)?.resume() }
}

final class PhoneTakeoverTests: XCTestCase {
    private func setup() -> (PhoneTakeoverSession, PhoneFakeDesktop, PhoneHookRecorder, PhoneTestClock) {
        let desktop = PhoneFakeDesktop(), hooks = PhoneHookRecorder(), clock = PhoneTestClock()
        let session = PhoneTakeoverSession(desktop: desktop, now: { clock.now() }, pauseAndDrain: { _ in await hooks.pause() }, resumeAfterInspection: { await hooks.resume() })
        return (session, desktop, hooks, clock)
    }

    private func request(_ path: String, origin: String = "https://fixture.test.ts.net", cookie: String? = nil, csrf: String? = nil, body: [String: Any] = [:]) throws -> PhoneHTTPRequest {
        var headers = ["host": ["fixture.test.ts.net"], "origin": [origin], "content-type": ["application/json"]]
        if let cookie { headers["cookie"] = ["\(PhoneTakeoverHTTPService.cookieName)=\(cookie)"] }
        if let csrf { headers["x-steve-csrf"] = [csrf] }
        return PhoneHTTPRequest(method: "POST", path: path, headers: headers, body: try JSONSerialization.data(withJSONObject: body))
    }

    func testOverlappingRevokesBlockNewPairingUntilEveryCleanupCompletes() async throws {
        let desktop = PhoneOverlappingStopDesktop()
        let session = PhoneTakeoverSession(desktop: desktop, pauseAndDrain: { _ in }, resumeAfterInspection: {})
        let token = try await session.issuePairingToken()
        _ = try await session.claim(token: token)
        let first = Task { await session.revoke() }
        var deadline = Date().addingTimeInterval(2)
        while await desktop.stopCount() < 1 && Date() < deadline { await Task.yield() }
        let second = Task { await session.revoke() }
        deadline = Date().addingTimeInterval(2)
        while await desktop.stopCount() < 2 && Date() < deadline { await Task.yield() }
        let stops = await desktop.stopCount()
        XCTAssertEqual(stops, 2)
        await desktop.release(1)
        await first.value // The transition owner has finished, second still waits.
        do { _ = try await session.issuePairingToken(); XCTFail("Old cleanup must not overlap a new lease") }
        catch { XCTAssertTrue(error is PhoneTakeoverError) }
        await desktop.release(2)
        await second.value
        let fresh = try await session.issuePairingToken()
        _ = try await session.claim(token: fresh)
        await session.revoke()
    }

    func testRevokeDuringPermissionCheckCannotResurrectPairingToken() async throws {
        let desktop = PhonePermissionGateDesktop()
        let session = PhoneTakeoverSession(desktop: desktop, pauseAndDrain: { _ in }, resumeAfterInspection: {})
        let issuance = Task { try await session.issuePairingToken() }
        let deadline = Date().addingTimeInterval(2)
        while !(await desktop.checking) && Date() < deadline { await Task.yield() }
        let checking = await desktop.checking
        XCTAssertTrue(checking)
        await session.revoke()
        await desktop.releaseCheck()
        do { _ = try await issuance.value; XCTFail("A canceled issuance must not resurrect a token") }
        catch { XCTAssertTrue(error is PhoneTakeoverError) }
        let fresh = try await session.issuePairingToken()
        XCTAssertFalse(fresh.isEmpty)
        await session.revoke()
    }

    func testRevokeDuringFinishStopDoesNotLeavePairingPermanentlyBusy() async throws {
        let desktop = PhoneStopGateDesktop()
        let hooks = PhoneHookRecorder()
        let session = PhoneTakeoverSession(desktop: desktop, pauseAndDrain: { _ in }, resumeAfterInspection: { await hooks.resume() }, onEndWithoutResume: { await hooks.end() })
        let token = try await session.issuePairingToken()
        let grant = try await session.claim(token: token)
        let finish = Task { try await session.finish(cookie: grant.cookie, csrf: grant.csrf, resume: true) }
        let deadline = Date().addingTimeInterval(2)
        while !(await desktop.firstStopEntered) && Date() < deadline { await Task.yield() }
        let entered = await desktop.firstStopEntered
        XCTAssertTrue(entered)
        await session.revoke()
        await desktop.releaseFirstStop()
        do { try await finish.value; XCTFail("Revocation must defeat explicit resume still awaiting stop") }
        catch { XCTAssertTrue(error is PhoneTakeoverError) }
        let counts = await hooks.counts()
        XCTAssertEqual(counts[1], 0)
        let replacement = try await session.issuePairingToken()
        XCTAssertFalse(replacement.isEmpty)
        await session.revoke()
    }

    func testOneUseTokenAndExplicitResume() async throws {
        let (session, desktop, hooks, _) = setup()
        let token = try await session.issuePairingToken()
        let grant = try await session.claim(token: token)
        do { _ = try await session.claim(token: token); XCTFail("Token cannot be reused") } catch { }
        let before = await hooks.counts()
        XCTAssertEqual(before, [1, 0])
        try await session.finish(cookie: grant.cookie, csrf: grant.csrf, resume: true)
        do { try await session.finish(cookie: grant.cookie, csrf: grant.csrf, resume: true); XCTFail("Resume cannot repeat") } catch { }
        let after = await hooks.counts(), counts = await desktop.counts()
        XCTAssertEqual(after, [1, 1])
        XCTAssertEqual(counts[3], 1)
    }

    func testExpiredPairingCannotPauseAgent() async throws {
        let (session, _, hooks, clock) = setup()
        let token = try await session.issuePairingToken()
        clock.advance(121)
        do { _ = try await session.claim(token: token); XCTFail("Expired token") } catch { }
        let counts = await hooks.counts()
        XCTAssertEqual(counts, [0, 0])
    }

    func testMissingPermissionsPreventPairing() async {
        let (session, desktop, hooks, _) = setup()
        await desktop.denyPermissions()
        do { _ = try await session.issuePairingToken(); XCTFail("Missing permission must block") } catch { }
        let counts = await hooks.counts()
        XCTAssertEqual(counts, [0, 0])
    }

    func testHeartbeatExpiryRevokesWithoutResuming() async throws {
        let (session, desktop, hooks, clock) = setup()
        let token = try await session.issuePairingToken()
        let grant = try await session.claim(token: token)
        clock.advance(16)
        await session.expireIfNeeded()
        do { _ = try await session.frame(cookie: grant.cookie, csrf: grant.csrf); XCTFail("Expired lease") } catch { }
        let calls = await hooks.counts(), counts = await desktop.counts()
        XCTAssertEqual(calls, [1, 0])
        XCTAssertEqual(counts[1], 0)
        XCTAssertEqual(counts[3], 1)
    }

    func testReplayAndStaleFrameCannotInjectInput() async throws {
        let (session, desktop, _, clock) = setup()
        let token = try await session.issuePairingToken()
        let grant = try await session.claim(token: token)
        defer { Task { await session.revoke() } }
        let frame = try await session.frame(cookie: grant.cookie, csrf: grant.csrf)
        let input = PhoneTakeoverInput(sequence: 1, frameID: frame.id, kind: "click", x: 0.5, y: 0.5)
        try await session.input(input, cookie: grant.cookie, csrf: grant.csrf)
        clock.advance(1)
        do { try await session.input(input, cookie: grant.cookie, csrf: grant.csrf); XCTFail("Duplicate input") } catch { }
        _ = try await session.frame(cookie: grant.cookie, csrf: grant.csrf)
        let stale = PhoneTakeoverInput(sequence: 2, frameID: frame.id, kind: "click", x: 0.5, y: 0.5)
        do { try await session.input(stale, cookie: grant.cookie, csrf: grant.csrf); XCTFail("Stale frame") } catch { }
        let counts = await desktop.counts()
        XCTAssertEqual(counts[2], 1)
    }

    func testClaimCannotCaptureUntilAgentDrainCompletesAndRevokeWins() async throws {
        let desktop = PhoneFakeDesktop(), gate = PhoneDrainGate()
        let session = PhoneTakeoverSession(desktop: desktop, pauseAndDrain: { _ in await gate.wait() }, resumeAfterInspection: {})
        let token = try await session.issuePairingToken()
        let claim = Task { try await session.claim(token: token) }
        let deadline = Date().addingTimeInterval(1)
        while !(await gate.entered) && Date() < deadline { await Task.yield() }
        let counts = await desktop.counts()
        XCTAssertEqual(counts[0], 0)
        XCTAssertEqual(counts[1], 0)
        await session.revoke()
        do { _ = try await session.issuePairingToken(); XCTFail("Cannot overlap a draining handoff") } catch { }
        await gate.release()
        do { _ = try await claim.value; XCTFail("Revoked claim must not start capture") } catch { }
        let final = await desktop.counts()
        XCTAssertEqual(final[0], 0)
        _ = try await session.issuePairingToken()
    }

    func testHTTPEnforcesOriginCookieCSRFAndSecurityHeaders() async throws {
        let (session, desktop, _, _) = setup()
        let service = try PhoneTakeoverHTTPService(origin: PhoneTakeoverOrigin("https://fixture.test.ts.net"), session: session, assets: ["/": ("text/html", Data("fixture".utf8))])
        let token = try await session.issuePairingToken()
        let crossOrigin = await service.handle(try request("/api/pair", origin: "https://attacker.invalid", body: ["token": token]))
        XCTAssertEqual(crossOrigin.status, 403)
        let claimed = await service.handle(try request("/api/pair", body: ["token": token]))
        XCTAssertEqual(claimed.status, 200)
        let cookie = try XCTUnwrap(claimed.headers["Set-Cookie"])
        for flag in ["Secure", "HttpOnly", "SameSite=Strict", "Path=/"] { XCTAssertTrue(cookie.contains(flag)) }
        XCTAssertEqual(claimed.headers["Cache-Control"], "no-store, max-age=0")
        XCTAssertTrue(claimed.headers["Content-Security-Policy"]?.contains("frame-ancestors 'none'") == true)
        let noCSRF = await service.handle(try request("/api/frame", cookie: "untrusted"))
        XCTAssertEqual(noCSRF.status, 401)
        let counts = await desktop.counts()
        XCTAssertEqual(counts[1], 0)
        await session.revoke()
    }

    func testHostAndDuplicateHeaderRejection() async throws {
        let (session, _, _, _) = setup()
        let service = try PhoneTakeoverHTTPService(origin: PhoneTakeoverOrigin("https://fixture.test.ts.net"), session: session, assets: ["/": ("text/html", Data())])
        for hosts in [["localhost"], ["fixture.test.ts.net", "attacker.invalid"]] {
            let request = PhoneHTTPRequest(method: "GET", path: "/", headers: ["host": hosts], body: Data())
            let response = await service.handle(request)
            XCTAssertEqual(response.status, 403)
        }
    }

    func testEndCleanupRunsOnExpiryAndFailedResume() async throws {
        let desktop = PhoneFakeDesktop(), hooks = PhoneHookRecorder(), clock = PhoneTestClock()
        let session = PhoneTakeoverSession(desktop: desktop, now: { clock.now() }, pauseAndDrain: { _ in await hooks.pause() }, resumeAfterInspection: { throw PhoneTakeoverError.expired }, onEndWithoutResume: { await hooks.end() })
        let first = try await session.issuePairingToken()
        _ = try await session.claim(token: first)
        clock.advance(16)
        await session.expireIfNeeded()
        let expiredEnds = await hooks.ends
        XCTAssertEqual(expiredEnds, 1)
        let second = try await session.issuePairingToken()
        let grant = try await session.claim(token: second)
        do { try await session.finish(cookie: grant.cookie, csrf: grant.csrf, resume: true); XCTFail("Resume failure must propagate") } catch { }
        let failedEnds = await hooks.ends
        XCTAssertEqual(failedEnds, 2)
        _ = try await session.issuePairingToken()
    }

    func testLoopbackServerServesAssetsAndClosesConnectionWithoutRevokingLease() async throws {
        let (session, desktop, _, _) = setup()
        let service = try PhoneTakeoverHTTPService(origin: PhoneTakeoverOrigin("https://fixture.test.ts.net"), session: session, assets: ["/": ("text/html", Data("fixture".utf8))])
        let server = try await PhoneTakeoverHTTPServer(service: service)
        let token = try await session.issuePairingToken()
        let grant = try await session.claim(token: token)
        do {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/")!)
            request.setValue("fixture.test.ts.net", forHTTPHeaderField: "Host")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 3
            let client = URLSession(configuration: configuration)
            defer { client.invalidateAndCancel() }
            let (data, response) = try await client.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "fixture")
            try await session.heartbeat(cookie: grant.cookie, csrf: grant.csrf)
            let counts = await desktop.counts()
            XCTAssertEqual(counts[1], 0)
            await server.stop()
        } catch { await server.stop(); throw error }
    }

    func testOriginAndInputValidation() throws {
        for origin in ["http://fixture.test.ts.net", "https://user:password@fixture.test.ts.net", "https://fixture.test.ts.net/path", "https://fixture.test.ts.net?token=value"] {
            XCTAssertThrowsError(try PhoneTakeoverOrigin(origin))
        }
        XCTAssertThrowsError(try PhoneTakeoverInput(sequence: 1, frameID: "frame", kind: "shell", text: "no").validate())
        XCTAssertThrowsError(try PhoneTakeoverInput(sequence: 1, frameID: "frame", kind: "click", x: .nan, y: 0).validate())
        XCTAssertThrowsError(try PhoneTakeoverInput(sequence: 1, frameID: "frame", kind: "text", text: "line\nline").validate())
        XCTAssertNoThrow(try PhoneTakeoverInput(sequence: 1, frameID: "frame", kind: "text", text: "fixture🔑").validate())
    }
}
