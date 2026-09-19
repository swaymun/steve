import CoreGraphics
import Foundation

@MainActor
final class SteveTaskVideoControl {
    private let capturePermit: SteveCapturePermit
    private let authorize: @MainActor () async throws -> SteveVideoAuthorization
    private let recorder: any TaskVideoRecording
    private var authorization: SteveVideoAuthorization?
    private var recordingID: UUID?
    private var starting = false
    private var generation = UUID()

    convenience init(runtime: SteveRuntime) {
        self.init(capturePermit: runtime.capturePermit, authorize: { try await runtime.authorizeVideo() }, recorder: NativeTaskVideoRecorder())
    }

    init(capturePermit: SteveCapturePermit, authorize: @escaping @MainActor () async throws -> SteveVideoAuthorization, recorder: any TaskVideoRecording) {
        self.capturePermit = capturePermit
        self.authorize = authorize
        self.recorder = recorder
    }

    func handle(_ request: SteveControlRequest) async -> SteveControlResponse {
        do {
            guard let action = request.options["action"] else { throw TaskVideoError.invalidOptions }
            switch action {
            case "windows":
                guard Set(request.options.keys) == ["action", "app"], let app = request.options["app"], TaskVideoTarget.validAppID(app), !starting, authorization == nil else { throw TaskVideoError.invalidOptions }
                starting = true
                defer { starting = false }
                let captured = generation
                let grant = try await authorize()
                defer { capturePermit.revoke(grant.token) }
                guard generation == captured, capturePermit.allows(grant.token, kind: .video) else { throw TaskVideoError.privacy }
                let windows = try await recorder.windows(app: app)
                guard generation == captured, capturePermit.allows(grant.token, kind: .video) else { throw TaskVideoError.privacy }
                return SteveControlResponse(state: "ready", summary: "Choose the exact task window from this app. No recording has started.", values: ["windows": String(decoding: try JSONEncoder().encode(windows), as: UTF8.self)])
            case "start":
                let allowed: Set<String> = ["action", "demonstration", "audio", "display", "window", "app", "seconds", "max-mib"]
                guard Set(request.options.keys).isSubset(of: allowed), request.options["demonstration"] == "true" else {
                    throw RPCError(message: "Recording requires --demonstration for an explicitly requested, non-sensitive task demonstration. Stop before any login or password entry.")
                }
                guard authorization == nil, !starting else { throw TaskVideoError.busy }
                starting = true
                defer { starting = false }
                let captured = generation
                var options = TaskVideoOptions()
                options.maximumDuration = 30
                options.systemAudio = request.options["audio"] == "true"
                if let seconds = request.options["seconds"] {
                    guard let number = Double(seconds) else { throw TaskVideoError.invalidOptions }
                    options.maximumDuration = number
                }
                if let budget = request.options["max-mib"] {
                    guard let number = Int(budget), (1...96).contains(number) else { throw TaskVideoError.invalidOptions }
                    options.maximumBytes = number * 1024 * 1024
                }
                let target = try TaskVideoTarget.parse(request.options)
                try options.validate()
                let grant = try await authorize()
                guard generation == captured else { capturePermit.revoke(grant.token); throw TaskVideoError.privacy }
                authorization = grant
                let permit = capturePermit
                do {
                    let id = try await recorder.start(workspace: grant.workspace, target: target, options: options,
                        privacyAllowsCapture: { permit.allows(grant.token, kind: .video) }, onEnd: { [weak self] id in
                            self?.clearAuthorization(token: grant.token, recordingID: id)
                        })
                    guard authorization?.token == grant.token else { throw TaskVideoError.privacy }
                    recordingID = id
                    return SteveControlResponse(state: "ready", summary: "Recording only the selected \(target.label). Stop before login or sensitive content. The time limit discards an unfinished recording.", values: ["recordingID": id.uuidString, "captureScope": target.label, "systemAudio": String(options.systemAudio), "maximumSeconds": String(options.maximumDuration)])
                } catch {
                    clearAuthorization(token: grant.token)
                    throw error
                }
            case "stop":
                guard Set(request.options.keys) == ["action", "id"],
                      let raw = request.options["id"], let id = UUID(uuidString: raw), id == recordingID,
                      let grant = authorization else { throw TaskVideoError.invalidSession }
                guard capturePermit.allows(grant.token, kind: .video) else { await cancel(); throw TaskVideoError.privacy }
                defer { clearAuthorization(token: grant.token, recordingID: id) }
                let artifact = try await recorder.stop(id: id)
                return SteveControlResponse(state: "ready", summary: "Video decoded and verified locally. Inspect the task outcome before selecting this file for iMessage delivery.", values: ["path": artifact.url.path, "mimeType": "video/mp4", "durationSeconds": String(artifact.duration), "bytes": String(artifact.bytes), "width": String(artifact.width), "height": String(artifact.height), "systemAudio": String(artifact.hasSystemAudio), "decodedFrames": String(artifact.videoFrames)])
            case "cancel":
                guard Set(request.options.keys) == ["action"] else { throw TaskVideoError.invalidOptions }
                await cancel()
                return SteveControlResponse(state: "ready", summary: "Recording canceled. No video will be delivered.")
            default: throw TaskVideoError.invalidOptions
            }
        } catch { return SteveControlResponse(state: "failed", summary: error.localizedDescription) }
    }

    private func clearAuthorization(token: String, recordingID endedID: UUID? = nil) {
        guard authorization?.token == token,
              endedID == nil || recordingID == nil || recordingID == endedID else { return }
        capturePermit.revoke(token)
        authorization = nil
        recordingID = nil
    }

    func cancel() async {
        generation = UUID()
        if let authorization { capturePermit.revoke(authorization.token) }
        authorization = nil
        recordingID = nil
        await recorder.cancel(reason: .privacy)
    }
}
