import AppKit
import AVFoundation
import ScreenCaptureKit

@MainActor
protocol TaskVideoRecording: AnyObject {
    func windows(app: String) async throws -> [TaskVideoWindow]
    func start(workspace: URL, target: TaskVideoTarget, options: TaskVideoOptions,
               privacyAllowsCapture: @escaping @Sendable () -> Bool,
               onEnd: @escaping @MainActor @Sendable (UUID) -> Void) async throws -> UUID
    func stop(id: UUID) async throws -> TaskVideoArtifact
    func cancel(reason: TaskVideoError) async
}

/// An explicit, short demonstration recorder. This never starts automatically
/// with an agent turn. The caller owns login detection and must invalidate its
/// generation/privacy gate, then await cancel(), before exposing sensitive UI.
@MainActor
final class NativeTaskVideoRecorder: NSObject, TaskVideoRecording {
    private struct Active {
        let id: UUID
        let stream: SCStream
        let sink: TaskVideoCaptureSink
        let writer: TaskVideoWriter
        let directory: URL
        let targetIsValid: @Sendable () -> Bool
        let privacyAllowsCapture: @Sendable () -> Bool
        let started: ContinuousClock.Instant
        let maximumDuration: TimeInterval
        let onEnd: @MainActor @Sendable (UUID) -> Void
    }
    private var active: Active?
    private var transition = false
    private var generation = UUID()
    private var lastFailure: (UUID, TaskVideoError)?
    private var watchdog: Task<Void, Never>?
    private var badge: NSStatusItem?
    private var observers: [NSObjectProtocol] = []
    private var sessionState = CaptureSessionState()

    override init() {
        super.init()
        for name in CaptureSessionState.notifications {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.sessionState.receive(name)
                    if !self.sessionState.isAvailable {
                        self.active?.sink.invalidate()
                        self.active?.writer.cancel(.privacy)
                        Task { await self.cancel() }
                    }
                }
            })
        }
    }

    func windows(app: String) async throws -> [TaskVideoWindow] {
        guard TaskVideoTarget.validAppID(app), sessionIsUsable(), CGPreflightScreenCaptureAccess() else { throw TaskVideoError.unavailable }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard sessionIsUsable() else { throw TaskVideoError.privacy }
        return content.windows.compactMap(Self.windowDescription).filter { $0.app == app }.sorted { $0.windowID < $1.windowID }
    }
    private static func windowDescription(_ window: SCWindow) -> TaskVideoWindow? {
        guard window.isOnScreen, window.windowLayer == 0, let owner = window.owningApplication,
              window.frame.width.isFinite, window.frame.height.isFinite, window.frame.width > 0, window.frame.height > 0 else { return nil }
        return .init(windowID: window.windowID, processID: owner.processID, app: owner.bundleIdentifier,
                     title: String((window.title ?? "").prefix(240)), width: Int(window.frame.width.rounded(.up)), height: Int(window.frame.height.rounded(.up)))
    }

    func start(workspace: URL, target: TaskVideoTarget, options: TaskVideoOptions = TaskVideoOptions(),
               privacyAllowsCapture: @escaping @Sendable () -> Bool,
               onEnd: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }) async throws -> UUID {
        guard active == nil, !transition else { throw TaskVideoError.busy }
        try options.validate()
        guard privacyAllowsCapture(), sessionIsUsable(), CGPreflightScreenCaptureAccess() else { throw TaskVideoError.unavailable }
        transition = true
        let id = UUID()
        generation = id
        var preparedDirectory: URL?
        var preparedWriter: TaskVideoWriter?
        var preparedStream: SCStream?
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            try Task.checkCancellation()
            guard generation == id, privacyAllowsCapture(), sessionIsUsable() else { throw TaskVideoError.privacy }
            let filter: SCContentFilter
            let targetIsValid: @Sendable () -> Bool
            let sourceWidth: Int, sourceHeight: Int
            switch target {
            case .display(let displayID):
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw TaskVideoError.privacy }
                filter = SCContentFilter(display: display, excludingWindows: [])
                sourceWidth = display.width; sourceHeight = display.height
                let bounds = CGDisplayBounds(displayID)
                targetIsValid = { CGDisplayBounds(displayID) == bounds }
            case .window(let windowID, let app):
                guard !options.systemAudio else { throw TaskVideoError.invalidOptions }
                let selected = try TaskVideoWindow.selected(id: windowID, app: app, from: content.windows.compactMap(Self.windowDescription))
                guard let window = content.windows.first(where: { $0.windowID == selected.windowID }) else { throw TaskVideoError.privacy }
                // SDK contract: captures just this independent window, without
                // the desktop, dock, other apps, or an encompassing display crop.
                filter = SCContentFilter(desktopIndependentWindow: window)
                sourceWidth = Int((filter.contentRect.width * CGFloat(filter.pointPixelScale)).rounded(.up))
                sourceHeight = Int((filter.contentRect.height * CGFloat(filter.pointPixelScale)).rounded(.up))
                targetIsValid = {
                    guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, selected.windowID) as? [[String: Any]], list.count == 1, let info = list.first else { return false }
                    return selected.stillMatches(info)
                }
            }
            guard targetIsValid(), sourceWidth > 0, sourceHeight > 0 else { throw TaskVideoError.privacy }
            let directory = try Self.makeDirectory(workspace: workspace, id: id)
            preparedDirectory = directory
            let (width, height) = options.dimensions(width: sourceWidth, height: sourceHeight)
            let sink = TaskVideoCaptureSink(allowsCapture: { privacyAllowsCapture() && targetIsValid() })
            let writer = try TaskVideoWriter(url: directory.appendingPathComponent("capture.partial.mp4"), width: width, height: height, options: options, allowsCapture: { [weak sink] in sink?.mayCapture() == true })
            sink.writer = writer
            preparedWriter = writer
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
            configuration.queueDepth = 5
            configuration.showsCursor = target.label == "display"
            configuration.ignoreShadowsSingleWindow = true
            configuration.ignoreGlobalClipSingleWindow = true
            if #available(macOS 14.2, *) { configuration.includeChildWindows = false }
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.capturesAudio = options.systemAudio
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
            configuration.excludesCurrentProcessAudio = true
            // There is deliberately no microphone capture option or input.
            let stream = SCStream(filter: filter, configuration: configuration, delegate: sink)
            preparedStream = stream
            try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
            if options.systemAudio { try stream.addStreamOutput(sink, type: .audio, sampleHandlerQueue: sink.queue) }
            active = Active(id: id, stream: stream, sink: sink, writer: writer, directory: directory, targetIsValid: targetIsValid, privacyAllowsCapture: privacyAllowsCapture, started: .now, maximumDuration: options.maximumDuration, onEnd: onEnd)
            showBadge()
            try await stream.startCapture()
            try Task.checkCancellation()
            guard generation == id, privacyAllowsCapture(), sessionIsUsable() else { throw TaskVideoError.privacy }
            transition = false
            lastFailure = nil
            watchdog = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                    guard let self, let current = self.active, current.id == id else { return }
                    let reason: TaskVideoError?
                    if !current.privacyAllowsCapture() || !self.sessionIsUsable() || !current.targetIsValid() { reason = .privacy }
                    else if current.started.duration(to: .now) >= .seconds(current.maximumDuration) { reason = .durationLimit }
                    else { reason = current.writer.currentFailure() }
                    if let reason { await self.cancel(reason: reason); return }
                }
            }
            return id
        } catch {
            preparedWriter?.cancel((error as? TaskVideoError) ?? .encoding)
            if let preparedStream { try? await preparedStream.stopCapture() }
            if let preparedDirectory { try? FileManager.default.removeItem(at: preparedDirectory) }
            hideBadge()
            active = nil
            transition = false
            onEnd(id)
            throw error
        }
    }

    func stop(id: UUID) async throws -> TaskVideoArtifact {
        guard let current = active, current.id == id, !transition else {
            if let lastFailure, lastFailure.0 == id { throw lastFailure.1 }
            throw TaskVideoError.invalidSession
        }
        transition = true
        watchdog?.cancel(); watchdog = nil
        do {
            current.sink.prepareToStop()
            try await current.stream.stopCapture()
            await current.sink.drain()
            let end = CMClockGetTime(CMClockGetHostTimeClock())
            try Task.checkCancellation()
            guard generation == id, current.privacyAllowsCapture(), current.targetIsValid(), sessionIsUsable() else { throw TaskVideoError.privacy }
            let artifact = try await Task.detached { try await current.writer.finish(at: end) }.value
            try Task.checkCancellation()
            guard generation == id, current.privacyAllowsCapture(), current.targetIsValid(), sessionIsUsable() else { throw TaskVideoError.privacy }
            let destination = current.directory.appendingPathComponent("demo-\(id.uuidString.lowercased()).mp4")
            try FileManager.default.moveItem(at: artifact.url, to: destination)
            active = nil; transition = false; hideBadge()
            current.onEnd(id)
            return TaskVideoArtifact(url: destination, duration: artifact.duration, bytes: artifact.bytes, width: artifact.width, height: artifact.height, hasSystemAudio: artifact.hasSystemAudio, videoFrames: artifact.videoFrames)
        } catch {
            current.sink.invalidate()
            current.writer.cancel((error as? TaskVideoError) ?? .encoding)
            try? await current.stream.stopCapture()
            await current.sink.drain()
            try? FileManager.default.removeItem(at: current.directory)
            active = nil; transition = false; hideBadge()
            lastFailure = (id, (error as? TaskVideoError) ?? .encoding)
            current.onEnd(id)
            throw error
        }
    }

    /// Returns only after no capture callback can append another byte. Await this
    /// before starting phone takeover, authentication, or a revoked worker turn.
    func cancel(reason: TaskVideoError = .privacy) async {
        generation = UUID()
        guard let current = active else { return }
        current.sink.invalidate()
        current.writer.cancel(reason)
        watchdog?.cancel(); watchdog = nil
        lastFailure = (current.id, reason)
        if transition {
            // stop() owns export cleanup. Invalidation makes that operation fail.
            await current.sink.drain()
            return
        }
        transition = true
        try? await current.stream.stopCapture()
        await current.sink.drain()
        try? FileManager.default.removeItem(at: current.directory)
        active = nil; transition = false; hideBadge()
        current.onEnd(current.id)
    }

    private func sessionIsUsable() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let protected: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.authorizationhost", "com.apple.systempreferences"]
        return sessionState.isAvailable && session?[kCGSessionOnConsoleKey as String] as? Bool == true && session?[kCGSessionLoginDoneKey as String] as? Bool == true && !protected.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
    }

    static func makeDirectory(workspace: URL, id: UUID) throws -> URL {
        let manager = FileManager.default
        let root = workspace.standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard root.isFileURL, manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else { throw TaskVideoError.workspace }
        var directory = root
        for component in [".steve-artifacts", "task-recordings", id.uuidString.lowercased()] {
            directory.appendPathComponent(component, isDirectory: true)
            if manager.fileExists(atPath: directory.path) {
                let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                guard values.isSymbolicLink != true, values.isDirectory == true else { throw TaskVideoError.workspace }
            } else {
                try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            }
            guard directory.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw TaskVideoError.workspace }
        }
        return directory
    }

    private func showBadge() {
        hideBadge()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.attributedTitle = NSAttributedString(string: "● REC", attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)])
        item.button?.toolTip = "Steve is recording this demonstration. Click to cancel and discard."
        item.button?.target = self
        item.button?.action = #selector(cancelFromBadge)
        badge = item
    }
    private func hideBadge() { if let badge { NSStatusBar.system.removeStatusItem(badge) }; badge = nil }
    @objc private func cancelFromBadge() { Task { await cancel() } }
}

private final class TaskVideoCaptureSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "Steve.task-video.samples", qos: .userInitiated)
    var writer: TaskVideoWriter? // Assigned before registering with SCStream.
    private let lock = NSLock()
    private var valid = true
    private var stopping = false
    private let allowsCapture: @Sendable () -> Bool
    init(allowsCapture: @escaping @Sendable () -> Bool) { self.allowsCapture = allowsCapture }
    func invalidate() { lock.lock(); valid = false; lock.unlock() }
    func prepareToStop() { lock.lock(); stopping = true; lock.unlock() }
    private func isStopping() -> Bool { lock.lock(); defer { lock.unlock() }; return stopping }
    func mayCapture() -> Bool { lock.lock(); let active = valid; lock.unlock(); return active && allowsCapture() }
    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    func stream(_ stream: SCStream, didStopWithError error: Error) { invalidate(); writer?.cancel(.encoding) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard mayCapture() else { writer?.cancel(.privacy); return }
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else { writer?.cancel(.encoding); return }
            switch status {
            case .complete: writer?.append(sampleBuffer, video: true)
            case .idle, .started: break
            case .stopped: if !isStopping() { invalidate(); writer?.cancel(.privacy) }
            case .blank, .suspended: invalidate(); writer?.cancel(.privacy)
            @unknown default: invalidate(); writer?.cancel(.encoding)
            }
        case .audio: writer?.append(sampleBuffer, video: false)
        default: break
        }
    }
}
