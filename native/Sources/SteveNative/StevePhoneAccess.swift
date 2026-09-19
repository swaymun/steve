import Foundation

/// Holds the runtime's lease separately from the browser's opaque session.
/// Every capture/input operation checks the current paired conversation boundary.
actor BoundPhoneDesktopControl: PhoneDesktopControl {
    private let runtime: SteveRuntime
    private let desktop: any PhoneDesktopControl
    private let onAuthorized: @Sendable (String) async -> Void
    private var token: String?

    init(runtime: SteveRuntime, desktop: any PhoneDesktopControl, onAuthorized: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.runtime = runtime
        self.desktop = desktop
        self.onAuthorized = onAuthorized
    }

    func begin(boundary: PhoneAccessBoundary) async throws {
        guard token == nil else { throw PhoneTakeoverError.busy }
        let current = try await runtime.beginPhoneTakeover(expectedBoundary: boundary)
        token = current
        await onAuthorized(current)
    }

    func end(resume: Bool) async throws {
        guard let current = token else {
            if resume { throw PhoneTakeoverError.expired }
            return
        }
        token = nil
        try await runtime.endPhoneTakeover(token: current, resume: resume)
    }

    private func validate() async throws {
        guard let current = token, await runtime.phoneTakeoverIsActive(token: current), token == current else {
            throw PhoneTakeoverError.expired
        }
    }

    func missingPermissions() async -> [String] { await desktop.missingPermissions() }
    func start() async throws {
        try await validate()
        try await desktop.start()
        do { try await validate() } catch { await desktop.stop(); throw error }
    }
    func frame() async throws -> PhoneTakeoverFrame {
        try await validate()
        let frame = try await desktop.frame()
        try await validate()
        return frame
    }
    func apply(_ input: PhoneTakeoverInput) async throws {
        try await validate()
        try await desktop.apply(input)
        try await validate()
    }
    func stop() async { await desktop.stop() }
}

@MainActor
final class StevePhoneAccess {
    private let runtime: SteveRuntime
    private let beforeTakeover: @Sendable () async -> Void
    private var service: PhoneTakeoverHTTPService?
    private var server: PhoneTakeoverHTTPServer?
    private var changing = false

    init(runtime: SteveRuntime, beforeTakeover: @escaping @Sendable () async -> Void = {}) {
        self.runtime = runtime
        self.beforeTakeover = beforeTakeover
    }

    func restore() async throws {
        guard let raw = try await runtime.store.phoneAccessOrigin(),
              let port = try await runtime.store.phoneAccessPort() else { return }
        let origin = try PhoneTakeoverOrigin(raw)
        try await TailscaleSetup.verifyPhoneRoute(.init(origin: origin, localPort: port))
        try await start(origin: origin, port: port)
    }

    func configure() async throws -> String {
        guard !changing else { throw PhoneTakeoverError.busy }
        changing = true
        defer { changing = false }
        if let service, let server {
            try await TailscaleSetup.verifyPhoneRoute(.init(origin: service.origin, localPort: server.port))
            return service.origin.value
        }
        let savedPort = try await runtime.store.phoneAccessPort()
        let savedOrigin = try await runtime.store.phoneAccessOrigin()
        let route = try await TailscaleSetup.phoneRoute(existingOrigin: savedOrigin, existingPort: savedPort)
        // Bind before creating a route, so an occupied local port is never exposed.
        try await start(origin: route.origin, port: route.localPort)
        do {
            try await TailscaleSetup.enablePhoneRoute(route)
            try await runtime.store.savePhoneAccessPort(route.localPort)
            try await runtime.store.savePhoneAccessOrigin(route.origin.value)
            return route.origin.value
        } catch {
            await stop()
            throw error
        }
    }

    func pairingURL() async throws -> URL {
        guard let service, let server else { throw PhoneTakeoverError.unavailable("Run steve setup --phone-access after connecting Tailscale on this Mac and your phone.") }
        // Recheck before issuing a new secret if routing changed after startup.
        try await TailscaleSetup.verifyPhoneRoute(.init(origin: service.origin, localPort: server.port))
        let boundary = try await runtime.phoneAccessBoundary()
        return try await service.pairingURL(boundary: boundary)
    }

    func revoke() async { await service?.session.revoke() }

    func stop() async {
        let old = server
        server = nil
        service = nil
        await old?.stop()
    }

    private func start(origin: PhoneTakeoverOrigin, port: Int) async throws {
        guard server == nil else { return }
        let desktop = NativePhoneDesktopControl()
        desktop.accessStillAllowed = { false }
        let permit = runtime.capturePermit
        let bound = BoundPhoneDesktopControl(runtime: runtime, desktop: desktop) { token in
            await MainActor.run {
                desktop.accessStillAllowed = { permit.allows(token, kind: .phone) }
                desktop.performAuthorizedInput = { action in try permit.withPermit(token, kind: .phone, action) }
            }
        }
        let beforeTakeover = beforeTakeover
        let session = PhoneTakeoverSession(desktop: bound, leaseSeconds: 600,
            pauseAndDrain: { boundary in
                guard let boundary else { throw PhoneTakeoverError.expired }
                try await bound.begin(boundary: boundary)
                await beforeTakeover()
            }, resumeAfterInspection: { try await bound.end(resume: true) },
            onEndWithoutResume: { try? await bound.end(resume: false) })
        desktop.onStopRequested = { Task { await session.revoke() } }
        let service = try PhoneTakeoverHTTPService(origin: origin, session: session)
        let server = try await PhoneTakeoverHTTPServer(service: service, port: port)
        self.service = service
        self.server = server
    }
}
