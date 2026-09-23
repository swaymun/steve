import AppKit

/// Session switching and display sleep are independent. Waking a display must
/// not clear a still-inactive user session, and activation must not clear sleep.
struct CaptureSessionState {
    static let notifications = [NSWorkspace.sessionDidResignActiveNotification,
        NSWorkspace.sessionDidBecomeActiveNotification,
        NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification]
    private var active = true
    private var awake = true
    var isAvailable: Bool { active && awake }

    mutating func receive(_ name: Notification.Name) {
        switch name {
        case NSWorkspace.sessionDidResignActiveNotification: active = false
        case NSWorkspace.sessionDidBecomeActiveNotification: active = true
        case NSWorkspace.screensDidSleepNotification: awake = false
        case NSWorkspace.screensDidWakeNotification: awake = true
        default: break
        }
    }
}

/// Synchronous gate for native capture/input callbacks. Gateway invalidation
/// closes it before any suspension point, including pause, revoke, and takeover.
final class SteveCapturePermit: @unchecked Sendable {
    enum Kind { case phone, video, connectionHandoff }
    private let lock = NSLock()
    private var active: (String, Kind)?

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil
    }

    func issue(_ token: String, kind: Kind) throws {
        lock.lock(); defer { lock.unlock() }
        guard active == nil else { throw RPCError(message: "Screen access is already active.") }
        active = (token, kind)
    }
    func allows(_ token: String, kind: Kind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return active?.0 == token && active?.1 == kind
    }
    /// The body must be short and synchronous, and must not call back into
    /// this permit. Invalidation waits for a complete key/click pair to finish.
    func withPermit<R>(_ token: String, kind: Kind, _ body: () throws -> R) throws -> R {
        lock.lock(); defer { lock.unlock() }
        guard active?.0 == token && active?.1 == kind else { throw PhoneTakeoverError.expired }
        return try body()
    }
    func revoke(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        if active?.0 == token { active = nil }
    }
    func invalidate() { lock.lock(); active = nil; lock.unlock() }
}

struct SteveVideoAuthorization: Sendable {
    let token: String
    let workspace: URL
}
