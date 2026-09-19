import AppKit
import CoreGraphics
import Foundation
import XCTest
@testable import SteveNative

@MainActor
private final class CaptureFakeRecorder: TaskVideoRecording {
    var callbacks: [(UUID, @MainActor @Sendable (UUID) -> Void)] = []
    var starts = 0
    var targets: [TaskVideoTarget] = []
    func windows(app: String) async throws -> [TaskVideoWindow] { [] }
    func start(workspace: URL, target: TaskVideoTarget, options: TaskVideoOptions, privacyAllowsCapture: @escaping @Sendable () -> Bool, onEnd: @escaping @MainActor @Sendable (UUID) -> Void) async throws -> UUID {
        guard privacyAllowsCapture() else { throw TaskVideoError.privacy }
        starts += 1
        targets.append(target)
        let id = UUID()
        callbacks.append((id, onEnd))
        return id
    }
    func stop(id: UUID) async throws -> TaskVideoArtifact { throw TaskVideoError.noVideo }
    func cancel(reason: TaskVideoError) async { if let (id, callback) = callbacks.last { callback(id) } }
    func finish(_ index: Int, wrongID: Bool = false) { let (id, callback) = callbacks[index]; callback(wrongID ? UUID() : id) }
}

final class CaptureBoundaryTests: XCTestCase {
    func testDisplayWakeRestoresAvailabilityWithoutClearingInactiveSession() {
        var state = CaptureSessionState()
        XCTAssertTrue(state.isAvailable)
        state.receive(NSWorkspace.screensDidSleepNotification)
        XCTAssertFalse(state.isAvailable)
        state.receive(NSWorkspace.screensDidWakeNotification)
        XCTAssertTrue(state.isAvailable)
        state.receive(NSWorkspace.sessionDidResignActiveNotification)
        state.receive(NSWorkspace.screensDidSleepNotification)
        state.receive(NSWorkspace.screensDidWakeNotification)
        XCTAssertFalse(state.isAvailable, "A waking screen does not activate a signed-out user session")
        state.receive(NSWorkspace.sessionDidBecomeActiveNotification)
        XCTAssertTrue(state.isAvailable)
    }

    func testSessionActivationDoesNotClearDisplaySleep() {
        var state = CaptureSessionState()
        state.receive(NSWorkspace.screensDidSleepNotification)
        state.receive(NSWorkspace.sessionDidResignActiveNotification)
        state.receive(NSWorkspace.sessionDidBecomeActiveNotification)
        XCTAssertFalse(state.isAvailable)
        state.receive(NSWorkspace.screensDidWakeNotification)
        XCTAssertTrue(state.isAvailable)
    }

    func testWindowTargetRequiresExactScopeAndRejectsWideningOrAudio() throws {
        XCTAssertEqual(try TaskVideoTarget.parse(["window": "42", "app": "com.apple.TextEdit"]), .window(42, app: "com.apple.TextEdit"))
        XCTAssertEqual(try TaskVideoTarget.parse(["display": "1", "audio": "true"]), .display(1))
        for invalid in [[String: String](), ["app": "com.apple.TextEdit"], ["window": "42"], ["window": "0", "app": "com.apple.TextEdit"], ["window": "42", "app": "TextEdit"], ["window": "42", "app": "com.apple.TextEdit", "display": "1"], ["window": "42", "app": "com.apple.TextEdit", "audio": "true"]] {
            XCTAssertThrowsError(try TaskVideoTarget.parse(invalid))
        }
    }
    func testWindowSelectionAndLifecycleFailClosedWithoutDisplayFallback() throws {
        let selected = TaskVideoWindow(windowID: 42, processID: 123, app: "com.apple.TextEdit", title: "Task", width: 600, height: 400)
        XCTAssertEqual(try TaskVideoWindow.selected(id: 42, app: selected.app, from: [selected]), selected)
        for windows in [[], [selected, selected]] { XCTAssertThrowsError(try TaskVideoWindow.selected(id: 42, app: selected.app, from: windows)) }
        XCTAssertThrowsError(try TaskVideoWindow.selected(id: 42, app: "com.other.App", from: [selected]))
        var info: [String: Any] = [kCGWindowNumber as String: 42, kCGWindowOwnerPID as String: 123, kCGWindowIsOnscreen as String: true, kCGWindowBounds as String: CGRect(x: 20, y: 20, width: 600, height: 400).dictionaryRepresentation]
        XCTAssertTrue(selected.stillMatches(info))
        info[kCGWindowBounds as String] = CGRect(x: 900, y: 20, width: 600, height: 400).dictionaryRepresentation
        XCTAssertTrue(selected.stillMatches(info)) // Moving doesn't change scope.
        info[kCGWindowBounds as String] = CGRect(x: 900, y: 20, width: 900, height: 400).dictionaryRepresentation
        XCTAssertFalse(selected.stillMatches(info))
        info[kCGWindowBounds as String] = CGRect(x: 20, y: 20, width: 600, height: 400).dictionaryRepresentation
        info[kCGWindowOwnerPID as String] = 456
        XCTAssertFalse(selected.stillMatches(info))
        info[kCGWindowOwnerPID as String] = 123
        info[kCGWindowIsOnscreen as String] = false
        XCTAssertFalse(selected.stillMatches(info))
        XCTAssertFalse(selected.stillMatches([:]))
    }
    @MainActor func testWindowControlPassesOnlyExplicitTargetToRecorder() async throws {
        let permit = SteveCapturePermit(), recorder = CaptureFakeRecorder()
        let control = SteveTaskVideoControl(capturePermit: permit, authorize: {
            let token = UUID().uuidString; try permit.issue(token, kind: .video)
            return .init(token: token, workspace: URL(fileURLWithPath: "/fixture"))
        }, recorder: recorder)
        let result = await control.handle(.init(command: "video", options: ["action": "start", "demonstration": "true", "window": "42", "app": "com.apple.TextEdit"]))
        XCTAssertEqual(result.state, "ready"); XCTAssertEqual(result.values["captureScope"], "window")
        XCTAssertEqual(recorder.targets, [.window(42, app: "com.apple.TextEdit")])
        await control.cancel()
        let invalid = await control.handle(.init(command: "video", options: ["action": "start", "demonstration": "true", "window": "42", "app": "com.apple.TextEdit", "audio": "true"]))
        XCTAssertEqual(invalid.state, "failed"); XCTAssertEqual(recorder.starts, 1)
    }

    func testInvalidationWaitsForWholeInputPairAndBlocksFutureInput() throws {
        let permit = SteveCapturePermit()
        try permit.issue("fixture", kind: .phone)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let attempted = DispatchSemaphore(value: 0), invalidated = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try permit.withPermit("fixture", kind: .phone) {
                    entered.signal() // Equivalent to key down.
                    XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
                    // Key up occurs before withPermit returns.
                }
            } catch { XCTFail("Initial input should be authorized") }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async { attempted.signal(); permit.invalidate(); invalidated.signal() }
        XCTAssertEqual(attempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(invalidated.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(invalidated.wait(timeout: .now() + 2), .success)
        var called = false
        XCTAssertThrowsError(try permit.withPermit("fixture", kind: .phone) { called = true })
        XCTAssertFalse(called)
    }

    func testMismatchedPermitCannotRunActionAndThrowReleasesLock() throws {
        let permit = SteveCapturePermit()
        try permit.issue("fixture", kind: .phone)
        XCTAssertThrowsError(try permit.withPermit("other", kind: .phone) { XCTFail("Wrong token") })
        XCTAssertThrowsError(try permit.withPermit("fixture", kind: .video) { XCTFail("Wrong kind") })
        XCTAssertThrowsError(try permit.withPermit("fixture", kind: .phone) { throw PhoneTakeoverError.invalidInput })
        permit.invalidate()
        XCTAssertFalse(permit.allows("fixture", kind: .phone))
    }

    @MainActor func testNativeEndClearsPermitAndOldCallbackCannotClearNewRecording() async throws {
        let permit = SteveCapturePermit(), recorder = CaptureFakeRecorder()
        var tokens: [String] = []
        let control = SteveTaskVideoControl(capturePermit: permit, authorize: {
            let token = UUID().uuidString
            try permit.issue(token, kind: .video)
            tokens.append(token)
            return SteveVideoAuthorization(token: token, workspace: URL(fileURLWithPath: "/fixture"))
        }, recorder: recorder)
        let start = SteveControlRequest(command: "video", options: ["action": "start", "demonstration": "true", "display": "1"])
        let first = await control.handle(start)
        XCTAssertEqual(first.state, "ready")
        recorder.finish(0, wrongID: true)
        XCTAssertTrue(permit.allows(tokens[0], kind: .video))
        recorder.finish(0) // The same callback used by badge/expiry cancellation.
        XCTAssertFalse(permit.allows(tokens[0], kind: .video))
        let second = await control.handle(start)
        XCTAssertEqual(second.state, "ready")
        recorder.finish(0) // Late callback from the old capture cannot revoke new.
        XCTAssertTrue(permit.allows(tokens[1], kind: .video))
        await control.cancel()
        XCTAssertFalse(permit.allows(tokens[1], kind: .video))
    }

    @MainActor func testMissingDisplayCannotAuthorizeOrStartCapture() async {
        let recorder = CaptureFakeRecorder()
        let control = SteveTaskVideoControl(capturePermit: SteveCapturePermit(), authorize: { XCTFail("No implicit display authorization"); throw TaskVideoError.invalidOptions }, recorder: recorder)
        let result = await control.handle(SteveControlRequest(command: "video", options: ["action": "start", "demonstration": "true"]))
        XCTAssertEqual(result.state, "failed")
        XCTAssertTrue(result.summary.contains("--display"))
        XCTAssertEqual(recorder.starts, 0)
    }

    @MainActor func testCancelDuringAuthorizationPreventsLaterCapture() async {
        let permit = SteveCapturePermit(), recorder = CaptureFakeRecorder()
        var resume: CheckedContinuation<Void, Never>?
        var entered = false
        let control = SteveTaskVideoControl(capturePermit: permit, authorize: {
            entered = true
            await withCheckedContinuation { resume = $0 }
            try permit.issue("late", kind: .video)
            return SteveVideoAuthorization(token: "late", workspace: URL(fileURLWithPath: "/fixture"))
        }, recorder: recorder)
        let task = Task { await control.handle(SteveControlRequest(command: "video", options: ["action": "start", "demonstration": "true", "display": "1"])) }
        for _ in 0..<1000 { if entered { break }; await Task.yield() }
        XCTAssertTrue(entered)
        await control.cancel()
        resume?.resume()
        let result = await task.value
        XCTAssertEqual(result.state, "failed")
        XCTAssertEqual(recorder.starts, 0)
        XCTAssertFalse(permit.allows("late", kind: .video))
    }
}
