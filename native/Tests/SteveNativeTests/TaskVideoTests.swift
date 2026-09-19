import AVFoundation
import XCTest
@testable import SteveNative

private final class VideoPrivacyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return allowed }
    func invalidate() { lock.lock(); allowed = false; lock.unlock() }
}

final class TaskVideoTests: XCTestCase {
    private func temp() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Steve-video-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
    private func frame(at seconds: Double) throws -> CMSampleBuffer {
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) { memset(base, Int32(Int(seconds * 200) % 255), CVPixelBufferGetDataSize(buffer)) }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescriptionOut: &format), noErr)
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 15), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 60_000), decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer, formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
    private func audio(at seconds: Double) throws -> CMSampleBuffer {
        let count = 4_800
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        XCTAssertEqual(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format), noErr)
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: count * 4, flags: 0, blockBufferOut: &block), noErr)
        let data = (0..<(count * 2)).map { Int16(sin(Double($0 / 2) * 440 * 2 * .pi / 48_000) * 1000) }
        data.withUnsafeBytes { bytes in XCTAssertEqual(CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes.count), noErr) }
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(seconds: seconds, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
        var sampleSize = 4
        XCTAssertEqual(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: count, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }

    func testSyntheticH264ExportHasActualDurationAndSize() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try TaskVideoWriter(url: directory.appendingPathComponent("fixture.mp4"), width: 320, height: 240, options: TaskVideoOptions(), allowsCapture: { true })
        writer.append(try frame(at: 10), video: true)
        try await Task.sleep(for: .milliseconds(100))
        writer.append(try frame(at: 10.2), video: true)
        try await Task.sleep(for: .milliseconds(100))
        let artifact = try await writer.finish(at: CMTime(seconds: 10.6, preferredTimescale: 60_000))
        XCTAssertEqual(artifact.duration, 0.6, accuracy: 0.1)
        XCTAssertEqual(artifact.width, 320)
        XCTAssertEqual(artifact.height, 240)
        XCTAssertEqual(artifact.videoFrames, 2)
        XCTAssertFalse(artifact.hasSystemAudio)
        XCTAssertEqual(artifact.bytes, try Data(contentsOf: artifact.url).count)
    }

    func testSyntheticSystemAudioIsAACAndDecodable() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        var options = TaskVideoOptions(); options.systemAudio = true
        let writer = try TaskVideoWriter(url: directory.appendingPathComponent("audio.mp4"), width: 320, height: 240, options: options, allowsCapture: { true })
        writer.append(try frame(at: 10), video: true)
        for i in 0..<5 {
            try await Task.sleep(for: .milliseconds(100))
            writer.append(try audio(at: 10 + Double(i) / 10), video: false)
        }
        let artifact = try await writer.finish(at: CMTime(seconds: 10.5, preferredTimescale: 60_000))
        XCTAssertTrue(artifact.hasSystemAudio)
        XCTAssertEqual(artifact.duration, 0.5, accuracy: 0.1)
    }

    func testPrivacyInvalidationPreventsAppendAndFinish() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let gate = VideoPrivacyGate()
        let writer = try TaskVideoWriter(url: directory.appendingPathComponent("private.mp4"), width: 320, height: 240, options: TaskVideoOptions(), allowsCapture: { gate.read() })
        gate.invalidate()
        writer.append(try frame(at: 10), video: true)
        XCTAssertEqual(writer.currentFailure(), .privacy)
        do { _ = try await writer.finish(at: CMTime(seconds: 11, preferredTimescale: 60_000)); XCTFail("Invalidated capture cannot export") }
        catch { XCTAssertEqual(error as? TaskVideoError, .privacy) }
    }

    func testDurationLimitDoesNotReturnTrimmedArtifact() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        var options = TaskVideoOptions(); options.maximumDuration = 1
        let writer = try TaskVideoWriter(url: directory.appendingPathComponent("long.mp4"), width: 320, height: 240, options: options, allowsCapture: { true })
        writer.append(try frame(at: 10), video: true)
        writer.append(try frame(at: 12), video: true)
        XCTAssertEqual(writer.currentFailure(), .durationLimit)
        do { _ = try await writer.finish(at: CMTime(seconds: 12, preferredTimescale: 60_000)); XCTFail("Cannot silently truncate") } catch { XCTAssertEqual(error as? TaskVideoError, .durationLimit) }
    }

    func testRequestedAudioMissingFails() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        var options = TaskVideoOptions(); options.systemAudio = true
        let writer = try TaskVideoWriter(url: directory.appendingPathComponent("silent.mp4"), width: 320, height: 240, options: options, allowsCapture: { true })
        writer.append(try frame(at: 10), video: true)
        do { _ = try await writer.finish(at: CMTime(seconds: 10.5, preferredTimescale: 60_000)); XCTFail("Missing requested audio") } catch { XCTAssertEqual(error as? TaskVideoError, .missingAudio) }
    }

    @MainActor func testManagedDirectoryRejectsSymlinks() throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let outside = try temp(); defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent(".steve-artifacts"), withDestinationURL: outside)
        XCTAssertThrowsError(try NativeTaskVideoRecorder.makeDirectory(workspace: directory, id: UUID()))
    }

    func testOversizedArtifactFailsBeforePlaybackValidation() async throws {
        let directory = try temp(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oversize.mp4")
        var options = TaskVideoOptions(); options.maximumBytes = 1_048_576; options.maximumDuration = 5
        try Data(repeating: 0, count: options.maximumBytes + 1).write(to: url)
        do { _ = try await TaskVideoWriter.verify(url: url, options: options, expectedDuration: 1, frames: 1); XCTFail("Oversized artifact must fail") }
        catch { XCTAssertEqual(error as? TaskVideoError, .sizeLimit) }
    }

    func testOptionsBoundDurationDimensionsAndBudget() throws {
        var options = TaskVideoOptions()
        XCTAssertNoThrow(try options.validate())
        XCTAssertEqual(options.dimensions(width: 3840, height: 2160).0, 1280)
        XCTAssertEqual(options.dimensions(width: 3840, height: 2160).1, 720)
        options.maximumDuration = .infinity
        XCTAssertThrowsError(try options.validate())
        options.maximumDuration = 121
        XCTAssertThrowsError(try options.validate())
    }
}
