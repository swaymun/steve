import AppKit
import ApplicationServices
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Shares only the display containing the existing Chrome window. Display scope
/// deliberately includes password-manager and browser authentication popups.
@MainActor
final class NativePhoneDesktopControl: NSObject, PhoneDesktopControl {
    var onStopRequested: (@Sendable () -> Void)?
    var performAuthorizedInput: (_ action: () -> Void) throws -> Void = { _ in throw PhoneTakeoverError.expired }
    var accessStillAllowed: @Sendable () -> Bool = { true }
    private var display: SCDisplay?
    private var frameID: String?
    private var capturedBounds: CGRect?
    private var indicator: NSPanel?
    private var observers: [NSObjectProtocol] = []
    private var sessionUnavailable = false

    override init() {
        super.init()
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.screensDidSleepNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sessionUnavailable = true
                    self?.onStopRequested?()
                }
            })
        }
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.sessionUnavailable = false }
        })
    }

    func missingPermissions() async -> [String] {
        var missing: [String] = []
        if !CGPreflightScreenCaptureAccess() { missing.append("Screen Recording") }
        if !AXIsProcessTrusted() { missing.append("Accessibility") }
        return missing
    }

    func start() async throws {
        try Task.checkCancellation()
        try requireUserSession()
        guard await missingPermissions().isEmpty else { throw PhoneTakeoverError.unavailable("Enable Screen Recording and Accessibility for Steve on the Mac.") }
        guard let chrome = NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first else {
            throw PhoneTakeoverError.unavailable("Open Google Chrome on the Mac, then pair again.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let ids = order.compactMap { info -> CGWindowID? in
            guard info[kCGWindowOwnerPID as String] as? Int32 == chrome.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        guard let window = ids.lazy.compactMap({ id in content.windows.first(where: { $0.windowID == id && $0.frame.width > 100 && $0.frame.height > 100 }) }).first,
              let screen = content.displays.max(by: { left, right in
                  Self.area(left.frame.intersection(window.frame)) < Self.area(right.frame.intersection(window.frame))
              }), screen.frame.intersects(window.frame) else {
            throw PhoneTakeoverError.unavailable("Make an existing Chrome window visible on the Mac, then pair again.")
        }
        display = screen
        frameID = nil
        capturedBounds = nil
        chrome.activate()
        showIndicator(on: screen)
    }

    func frame() async throws -> PhoneTakeoverFrame {
        try requireUserSession()
        guard let display, CGPreflightScreenCaptureAccess() else { throw PhoneTakeoverError.expired }
        let id = display.displayID
        let bounds = CGDisplayBounds(id)
        guard !bounds.isEmpty, bounds == display.frame else { throw PhoneTakeoverError.unavailable("The display changed. Pair again on the Mac.") }
        let configuration = SCStreamConfiguration()
        let scale = min(1, 1440 / bounds.width)
        configuration.width = max(1, Int(bounds.width * scale))
        configuration.height = max(1, Int(bounds.height * scale))
        configuration.showsCursor = true
        configuration.capturesAudio = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        try requireUserSession()
        guard self.display?.displayID == id else { throw PhoneTakeoverError.expired }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw PhoneTakeoverError.unavailable("Screen capture could not be encoded.") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
        guard CGImageDestinationFinalize(destination), data.length <= 2_000_000 else { throw PhoneTakeoverError.unavailable("The screen image is unavailable or too large.") }
        let identifier = UUID().uuidString
        frameID = identifier
        capturedBounds = bounds
        return PhoneTakeoverFrame(id: identifier, jpeg: data as Data)
    }

    func apply(_ input: PhoneTakeoverInput) async throws {
        try Task.checkCancellation()
        try requireUserSession()
        try input.validate()
        guard AXIsProcessTrusted(), let display, let bounds = capturedBounds,
              bounds == CGDisplayBounds(display.displayID), input.frameID == frameID else { throw PhoneTakeoverError.staleFrame }
        let source = CGEventSource(stateID: .privateState)
        switch input.kind {
        case "click":
            let point = CGPoint(x: bounds.minX + min(bounds.width - 1, input.x! * bounds.width), y: bounds.minY + min(bounds.height - 1, input.y! * bounds.height))
            guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw PhoneTakeoverError.invalidInput }
            try performAuthorizedInput {
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        case "scroll":
            guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: Int32(input.delta!), wheel2: 0, wheel3: 0) else { throw PhoneTakeoverError.invalidInput }
            event.location = CGPoint(x: bounds.midX, y: bounds.midY)
            try performAuthorizedInput { event.post(tap: .cghidEventTap) }
        case "key":
            let codes: [String: CGKeyCode] = ["return": 36, "tab": 48, "backspace": 51, "escape": 53, "left": 123, "right": 124, "up": 126, "down": 125]
            guard let code = codes[input.key!] else { throw PhoneTakeoverError.invalidInput }
            try postKey(code, source: source)
        case "text":
            for character in input.text! {
                try postKey(0, source: source, text: Array(String(character).utf16))
            }
        default: throw PhoneTakeoverError.invalidInput
        }
    }

    func stop() async {
        display = nil
        frameID = nil
        capturedBounds = nil
        indicator?.close()
        indicator = nil
    }

    private func requireUserSession() throws {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let protectedApps: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.authorizationhost", "com.apple.systempreferences"]
        guard accessStillAllowed(), !sessionUnavailable,
              session?[kCGSessionOnConsoleKey as String] as? Bool == true,
              session?[kCGSessionLoginDoneKey as String] as? Bool == true,
              !protectedApps.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else {
            throw PhoneTakeoverError.unavailable("Unlock or finish the system permission prompt directly on the Mac. Steve stays paused.")
        }
    }

    private func postKey(_ code: CGKeyCode, source: CGEventSource?, text: [UniChar]? = nil) throws {
        try requireUserSession()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) else { throw PhoneTakeoverError.invalidInput }
        if let text {
            down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
            up.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
        }
        try performAuthorizedInput {
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
    }

    private func showIndicator(on display: SCDisplay) {
        indicator?.close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 390, height: 56), styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Steve screen sharing"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let label = NSTextField(labelWithString: "Your phone can see and control this display.")
        label.font = .systemFont(ofSize: 12)
        let button = NSButton(title: "Stop sharing", target: self, action: #selector(stopRequested))
        let stack = NSStackView(views: [label, button])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12), stack.centerYAnchor.constraint(equalTo: content.centerYAnchor)])
        }
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
        if let visible = screen?.visibleFrame { panel.setFrameTopLeftPoint(NSPoint(x: visible.midX - 195, y: visible.maxY - 8)) }
        panel.orderFrontRegardless()
        indicator = panel
    }

    @objc private func stopRequested() { onStopRequested?() }
    private static func area(_ rect: CGRect) -> CGFloat { rect.isNull ? 0 : rect.width * rect.height }
}
