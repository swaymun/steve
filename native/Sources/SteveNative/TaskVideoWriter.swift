import AVFoundation
import Foundation
import ScreenCaptureKit

struct TaskVideoOptions: Sendable {
    var maximumDuration: TimeInterval = 120
    /// A Steve delivery budget, not an advertised iMessage size limit.
    var maximumBytes = 24 * 1024 * 1024
    var maximumWidth = 1280
    var framesPerSecond = 15
    var systemAudio = false

    func validate() throws {
        guard maximumDuration.isFinite, (1...120).contains(maximumDuration),
              (1_048_576...100_663_296).contains(maximumBytes),
              (320...1920).contains(maximumWidth), (5...30).contains(framesPerSecond),
              videoBitRate >= 150_000 else { throw TaskVideoError.invalidOptions }
    }
    var videoBitRate: Int {
        min(4_000_000, Int(Double(maximumBytes) * 8 * 0.8 / maximumDuration) - (systemAudio ? 96_000 : 0))
    }
    func dimensions(width: Int, height: Int) -> (Int, Int) {
        let scale = min(1, Double(maximumWidth) / Double(max(width, height)))
        return (max(2, Int(Double(width) * scale) / 2 * 2), max(2, Int(Double(height) * scale) / 2 * 2))
    }
}

enum TaskVideoError: Error, LocalizedError, Equatable {
    case invalidOptions, unavailable, busy, invalidSession, privacy, durationLimit, sizeLimit, encoding, backpressure, noVideo, missingAudio, validation, workspace
    var errorDescription: String? {
        switch self {
        case .invalidOptions: return "The recording settings are outside Steve’s supported limits."
        case .unavailable: return "Screen recording is unavailable. Unlock the Mac and check Screen Recording permission."
        case .busy: return "A recording is already in progress."
        case .invalidSession: return "This recording session is no longer active."
        case .privacy: return "Recording was canceled at the privacy boundary. No video will be delivered."
        case .durationLimit: return "Recording exceeded its duration budget and was discarded. Start a shorter demonstration."
        case .sizeLimit: return "The video exceeded its delivery budget and was discarded. Start a shorter demonstration."
        case .encoding, .backpressure: return "Recording could not preserve the full demonstration. The incomplete video was discarded."
        case .noVideo: return "No usable video frames were captured."
        case .missingAudio: return "Requested system audio was not captured. No video will be delivered."
        case .validation: return "The recorded video failed playback validation."
        case .workspace: return "The managed recording workspace is unavailable."
        }
    }
}

struct TaskVideoArtifact: Sendable {
    let url: URL
    let duration: TimeInterval
    let bytes: Int
    let width: Int
    let height: Int
    let hasSystemAudio: Bool
    let videoFrames: Int
}

/// All AVAssetWriter mutation is protected by this lock. Capture callbacks never
/// wait for asynchronous model work. The caller must invalidate its privacy gate
/// and await recorder.cancel() BEFORE opening a login or takeover surface.
final class TaskVideoWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let options: TaskVideoOptions
    private let allowsCapture: @Sendable () -> Bool
    let outputURL: URL
    private var failure: TaskVideoError?
    private var finishing = false
    private var firstTime: CMTime?
    private var lastVideo: CMSampleBuffer?
    private var lastAudioTime: CMTime?
    private var frames = 0
    private var audioSamples = 0

    init(url: URL, width: Int, height: Int, options: TaskVideoOptions,
         allowsCapture: @escaping @Sendable () -> Bool) throws {
        try options.validate()
        self.options = options
        self.allowsCapture = allowsCapture
        outputURL = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: options.videoBitRate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                AVVideoExpectedSourceFrameRateKey: options.framesPerSecond,
                AVVideoMaxKeyFrameIntervalKey: options.framesPerSecond * 2]
        ])
        video.expectsMediaDataInRealTime = true
        guard writer.canAdd(video) else { throw TaskVideoError.encoding }
        writer.add(video)
        if options.systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw TaskVideoError.encoding }
            writer.add(input)
            audio = input
        } else { audio = nil }
        guard writer.startWriting() else { throw TaskVideoError.encoding }
    }

    func append(_ sample: CMSampleBuffer, video isVideo: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard failure == nil, !finishing else { return }
        guard allowsCapture() else { fail(.privacy); return }
        guard sample.isValid, CMSampleBufferDataIsReady(sample) else { fail(.encoding); return }
        let time = sample.presentationTimeStamp
        guard time.isValid, time.isNumeric else { fail(.encoding); return }
        if firstTime == nil {
            // The recorded interval begins with its first usable video frame.
            // Audio preceding that interval is intentionally not included.
            guard isVideo else { return }
            writer.startSession(atSourceTime: time)
            firstTime = time
        }
        guard let start = firstTime, time >= start else { return }
        guard (time - start).seconds <= options.maximumDuration else { fail(.durationLimit); return }
        if isVideo {
            if let previous = lastVideo, time <= previous.presentationTimeStamp { fail(.encoding); return }
            guard video.isReadyForMoreMediaData else { fail(.backpressure); return }
            guard video.append(sample) else { fail(.encoding); return }
            lastVideo = sample
            frames += 1
        } else if let audio {
            if let previous = lastAudioTime, time <= previous { fail(.encoding); return }
            guard audio.isReadyForMoreMediaData else { fail(.backpressure); return }
            guard audio.append(sample) else { fail(.encoding); return }
            lastAudioTime = time
            audioSamples += CMSampleBufferGetNumSamples(sample)
        }
        if let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attributes[.size] as? NSNumber, size.intValue > options.maximumBytes { fail(.sizeLimit) }
    }

    func currentFailure() -> TaskVideoError? { lock.lock(); defer { lock.unlock() }; return failure }
    func cancel(_ reason: TaskVideoError = .privacy) {
        lock.lock(); defer { lock.unlock() }
        fail(reason)
    }
    private func fail(_ reason: TaskVideoError) {
        if failure == nil { failure = reason }
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    }

    private func prepareFinish(at end: CMTime) throws -> (TimeInterval, Int) {
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard !finishing else { throw TaskVideoError.invalidSession }
        guard allowsCapture() else { fail(.privacy); throw TaskVideoError.privacy }
        guard let firstTime, let lastVideo, frames > 0 else { throw TaskVideoError.noVideo }
        guard end.isNumeric, end > lastVideo.presentationTimeStamp else { throw TaskVideoError.validation }
        let duration = (end - firstTime).seconds
        guard duration > 0, duration <= options.maximumDuration else { throw TaskVideoError.durationLimit }
        if options.systemAudio && audioSamples == 0 { throw TaskVideoError.missingAudio }
        // ScreenCaptureKit emits idle frames for a static display. Extend the last
        // observed image to the explicit stop time instead of silently shortening.
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(options.framesPerSecond))
        let finalTime = end - min(frameDuration, CMTimeMultiplyByFloat64(end - lastVideo.presentationTimeStamp, multiplier: 0.5))
        if finalTime > lastVideo.presentationTimeStamp {
            var timing = CMSampleTimingInfo(duration: end - finalTime, presentationTimeStamp: finalTime, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: lastVideo, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                  let copy, video.isReadyForMoreMediaData, video.append(copy) else { throw TaskVideoError.backpressure }
        }
        writer.endSession(atSourceTime: end)
        video.markAsFinished()
        audio?.markAsFinished()
        finishing = true
        return (duration, frames)
    }

    func finish(at end: CMTime) async throws -> TaskVideoArtifact {
        do {
            let (expectedDuration, frameCount) = try prepareFinish(at: end)
            await writer.finishWriting()
            try Task.checkCancellation()
            if let error = currentFailure() { throw error }
            guard writer.status == .completed, allowsCapture() else { throw TaskVideoError.privacy }
            return try await Self.verify(url: outputURL, options: options, expectedDuration: expectedDuration, frames: frameCount)
        } catch {
            cancel((error as? TaskVideoError) ?? .encoding)
            throw error
        }
    }

    static func verify(url: URL, options: TaskVideoOptions, expectedDuration: TimeInterval, frames: Int) async throws -> TaskVideoArtifact {
        // URL resource values cache file size, which may still be zero from
        // an in-progress encoding check. Stat the completed file afresh.
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let number = attributes[.size] as? NSNumber, number.intValue > 0 else { throw TaskVideoError.validation }
        let bytes = number.intValue
        guard bytes <= options.maximumBytes else { throw TaskVideoError.sizeLimit }
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else { throw TaskVideoError.validation }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, duration <= options.maximumDuration + 0.1,
              abs(duration - expectedDuration) <= 0.15 else { throw TaskVideoError.validation }
        let videos = try await asset.loadTracks(withMediaType: .video)
        let audios = try await asset.loadTracks(withMediaType: .audio)
        guard videos.count == 1, let track = videos.first else { throw TaskVideoError.noVideo }
        guard !options.systemAudio || audios.count == 1 else { throw TaskVideoError.missingAudio }
        let formats = try await track.load(.formatDescriptions)
        guard formats.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264 }) else { throw TaskVideoError.validation }
        if let audio = audios.first {
            let descriptions = try await audio.load(.formatDescriptions)
            guard descriptions.contains(where: { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC }) else { throw TaskVideoError.validation }
        }
        // Decode every track, not just container metadata. This also catches an
        // audio track advertised by a container but containing no readable samples.
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        guard reader.canAdd(videoOutput) else { throw TaskVideoError.validation }
        reader.add(videoOutput)
        var audioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audios.first {
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            guard reader.canAdd(output) else { throw TaskVideoError.validation }
            reader.add(output); audioOutput = output
        }
        guard reader.startReading() else { throw TaskVideoError.validation }
        var videoCount = 0, audioCount = 0
        var videoDone = false, audioDone = audioOutput == nil
        while !videoDone || !audioDone {
            try Task.checkCancellation()
            if !videoDone { if videoOutput.copyNextSampleBuffer() != nil { videoCount += 1 } else { videoDone = true } }
            if !audioDone { if audioOutput?.copyNextSampleBuffer() != nil { audioCount += 1 } else { audioDone = true } }
        }
        guard reader.status == .completed, videoCount > 0, !options.systemAudio || audioCount > 0 else { reader.cancelReading(); throw TaskVideoError.validation }
        let size = try await track.load(.naturalSize)
        return TaskVideoArtifact(url: url, duration: duration, bytes: bytes, width: Int(size.width), height: Int(size.height), hasSystemAudio: !audios.isEmpty, videoFrames: frames)
    }
}
