import Foundation
import CryptoKit
import Security

struct PhoneTakeoverInput: Codable, Sendable {
    let sequence: Int
    let frameID: String
    let kind: String
    var x: Double?
    var y: Double?
    var delta: Int?
    var key: String?
    var text: String?

    func validate() throws {
        guard sequence > 0, frameID.count <= 64 else { throw PhoneTakeoverError.invalidInput }
        switch kind {
        case "click":
            guard let x, let y, x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else { throw PhoneTakeoverError.invalidInput }
        case "scroll":
            guard let delta, (-600...600).contains(delta) else { throw PhoneTakeoverError.invalidInput }
        case "key":
            guard let key, ["return", "tab", "backspace", "escape", "left", "right", "up", "down"].contains(key) else { throw PhoneTakeoverError.invalidInput }
        case "text":
            guard let text, !text.isEmpty, text.utf16.count <= 1024, !text.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw PhoneTakeoverError.invalidInput }
        default: throw PhoneTakeoverError.invalidInput
        }
    }
}

struct PhoneTakeoverFrame: Sendable {
    let id: String
    let jpeg: Data
}

protocol PhoneDesktopControl: Sendable {
    func missingPermissions() async -> [String]
    func start() async throws
    func frame() async throws -> PhoneTakeoverFrame
    func apply(_ input: PhoneTakeoverInput) async throws
    func stop() async
}

enum PhoneTakeoverError: Error, LocalizedError {
    case unauthorized, busy, expired, invalidInput, staleFrame, origin, unavailable(String)
    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Pair this phone again using the link shown on your Mac."
        case .busy: return "Control is busy. Wait for the current action to finish."
        case .expired: return "This connection ended. Steve remains paused. Pair again on the Mac."
        case .invalidInput: return "This input is not supported."
        case .staleFrame: return "The screen changed. Wait for the new image, then try again."
        case .origin: return "Open the configured private HTTPS address."
        case .unavailable(let message): return message
        }
    }
}

struct PhoneTakeoverGrant: Sendable {
    let cookie: String
    let csrf: String
    let expiresAt: Date
}

/// Everything here is ephemeral: no credentials, input, frames, or session
/// secrets are logged, written to disk, or passed to the model.
actor PhoneTakeoverSession {
    private struct Pairing { let digest: Data; let expires: Date; let boundary: PhoneAccessBoundary? }
    private struct Lease {
        let id: UUID
        let cookieDigest: Data
        let csrf: String
        let expires: Date
        var heartbeat: Date
        var sequence = 0
        var frameID: String?
        var busy = false
        var lastInput = Date.distantPast
    }
    private var pairing: Pairing?
    private var issuanceGeneration = UUID()
    private var revocationsInFlight = 0
    private var lease: Lease?
    private var transition: UUID?
    private var canceledTransition: UUID?
    private let desktop: any PhoneDesktopControl
    private let pauseAndDrain: @Sendable (PhoneAccessBoundary?) async throws -> Void
    private let onEndWithoutResume: @Sendable () async -> Void
    private let resumeAfterInspection: @Sendable () async throws -> Void
    private let now: @Sendable () -> Date
    private let leaseSeconds: TimeInterval
    private let heartbeatSeconds: TimeInterval
    private var watchdog: Task<Void, Never>?

    init(desktop: any PhoneDesktopControl,
         leaseSeconds: TimeInterval = 900, heartbeatSeconds: TimeInterval = 15,
         now: @escaping @Sendable () -> Date = { Date() },
         pauseAndDrain: @escaping @Sendable (PhoneAccessBoundary?) async throws -> Void,
         resumeAfterInspection: @escaping @Sendable () async throws -> Void,
         onEndWithoutResume: @escaping @Sendable () async -> Void = {}) {
        self.desktop = desktop
        self.leaseSeconds = leaseSeconds
        self.heartbeatSeconds = heartbeatSeconds
        self.now = now
        self.pauseAndDrain = pauseAndDrain
        self.resumeAfterInspection = resumeAfterInspection
        self.onEndWithoutResume = onEndWithoutResume
    }

    func issuePairingToken(boundary: PhoneAccessBoundary? = nil) async throws -> String {
        let captured = issuanceGeneration
        await expireIfNeeded()
        guard captured == issuanceGeneration else { throw PhoneTakeoverError.expired }
        guard lease == nil, transition == nil, revocationsInFlight == 0 else { throw PhoneTakeoverError.busy }
        let missing = await desktop.missingPermissions()
        guard captured == issuanceGeneration else { throw PhoneTakeoverError.expired }
        try Task.checkCancellation()
        guard missing.isEmpty else { throw PhoneTakeoverError.unavailable("Enable " + missing.joined(separator: " and ") + " for Steve in System Settings, then try again.") }
        guard lease == nil, transition == nil, revocationsInFlight == 0 else { throw PhoneTakeoverError.busy }
        let token = try Self.token()
        pairing = Pairing(digest: Self.digest(token), expires: now().addingTimeInterval(120), boundary: boundary)
        return token
    }

    func claim(token: String) async throws -> PhoneTakeoverGrant {
        guard lease == nil, transition == nil, revocationsInFlight == 0, let pairing,
              pairing.expires > now(), Self.matches(token, digest: pairing.digest) else { throw PhoneTakeoverError.unauthorized }
        self.pairing = nil // One use, including interrupted or failed handoffs.
        let id = UUID()
        transition = id
        do {
            try Task.checkCancellation()
            try await pauseAndDrain(pairing.boundary)
            guard transition == id, canceledTransition != id else { throw PhoneTakeoverError.expired }
            try Task.checkCancellation()
            try await desktop.start()
            guard transition == id, canceledTransition != id else { await desktop.stop(); throw PhoneTakeoverError.expired }
            try Task.checkCancellation()
            let cookie = try Self.token(), csrf = try Self.token()
            let expires = now().addingTimeInterval(leaseSeconds)
            lease = Lease(id: id, cookieDigest: Self.digest(cookie), csrf: csrf, expires: expires, heartbeat: now())
            transition = nil
            watchdog?.cancel()
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self else { return }
                    await self.expireIfNeeded()
                }
            }
            return PhoneTakeoverGrant(cookie: cookie, csrf: csrf, expiresAt: expires)
        } catch {
            await desktop.stop()
            await onEndWithoutResume()
            if transition == id { transition = nil; canceledTransition = nil }
            // A failed/disconnected handoff never resumes the agent automatically.
            throw error
        }
    }

    func heartbeat(cookie: String, csrf: String) async throws {
        try await authenticate(cookie: cookie, csrf: csrf)
        lease?.heartbeat = now()
    }

    func frame(cookie: String, csrf: String) async throws -> PhoneTakeoverFrame {
        try await authenticate(cookie: cookie, csrf: csrf)
        guard let current = lease, !current.busy else { throw PhoneTakeoverError.busy }
        lease?.busy = true
        do {
            let frame = try await desktop.frame()
            try Task.checkCancellation()
            await expireIfNeeded()
            guard lease?.id == current.id else { throw PhoneTakeoverError.expired }
            lease?.busy = false
            lease?.frameID = frame.id
            return frame
        } catch {
            if lease?.id == current.id { lease?.busy = false }
            throw error
        }
    }

    func input(_ input: PhoneTakeoverInput, cookie: String, csrf: String) async throws {
        try await authenticate(cookie: cookie, csrf: csrf)
        try input.validate()
        guard let current = lease, !current.busy else { throw PhoneTakeoverError.busy }
        guard input.sequence == current.sequence + 1 else { throw PhoneTakeoverError.invalidInput }
        guard input.frameID == current.frameID else { throw PhoneTakeoverError.staleFrame }
        guard now().timeIntervalSince(current.lastInput) >= 0.04 else { throw PhoneTakeoverError.busy }
        // Advance before dispatch: ambiguous failures must never replay a key or click.
        lease?.sequence = input.sequence
        lease?.lastInput = now()
        lease?.busy = true
        do {
            try await desktop.apply(input)
            guard lease?.id == current.id else { throw PhoneTakeoverError.expired }
            lease?.busy = false
        } catch {
            if lease?.id == current.id { await revoke() }
            throw error
        }
    }

    func finish(cookie: String, csrf: String, resume: Bool) async throws {
        try await authenticate(cookie: cookie, csrf: csrf)
        // Revoke before awaiting native stop, so no additional input can begin.
        let id = UUID()
        transition = id
        lease = nil
        pairing = nil
        watchdog?.cancel()
        watchdog = nil
        do {
            await desktop.stop()
            guard transition == id, canceledTransition != id else { throw PhoneTakeoverError.expired }
            if resume {
                try Task.checkCancellation()
                try await resumeAfterInspection()
            } else {
                await onEndWithoutResume()
            }
            if transition == id { transition = nil; canceledTransition = nil }
        } catch {
            await onEndWithoutResume()
            if transition == id { transition = nil; canceledTransition = nil }
            throw error
        }
    }

    func revoke() async {
        revocationsInFlight += 1
        defer { revocationsInFlight -= 1 }
        issuanceGeneration = UUID()
        pairing = nil
        lease = nil
        let ownsTransition = transition == nil
        let id = transition ?? UUID()
        transition = id
        canceledTransition = id
        watchdog?.cancel()
        watchdog = nil
        await desktop.stop()
        await onEndWithoutResume()
        if ownsTransition, transition == id { transition = nil; canceledTransition = nil }
    }

    func expireIfNeeded() async {
        if let pairing, pairing.expires <= now() { self.pairing = nil }
        guard let lease, lease.expires <= now() || now().timeIntervalSince(lease.heartbeat) >= heartbeatSeconds else { return }
        await revoke()
    }

    private func authenticate(cookie: String, csrf: String) async throws {
        await expireIfNeeded()
        guard let lease, Self.matches(cookie, digest: lease.cookieDigest), Self.matches(csrf, digest: Self.digest(lease.csrf)) else { throw PhoneTakeoverError.expired }
    }

    private static func token() throws -> String {
        var data = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, data.count, &data) == errSecSuccess else { throw PhoneTakeoverError.unavailable("Secure pairing is unavailable.") }
        return data.map { String(format: "%02x", $0) }.joined()
    }
    private static func digest(_ value: String) -> Data { Data(SHA256.hash(data: Data(value.utf8))) }
    private static func matches(_ value: String, digest expected: Data) -> Bool {
        guard value.utf8.count == 64 else { return false }
        let actual = digest(value)
        return zip(actual, expected).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
