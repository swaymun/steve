import XCTest
import ImageIO
import CoreGraphics
@testable import SteveNative

final class NativeCaptureTests: XCTestCase {
    private func workspace() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.path
    }
    private func image(_ mime: String = "image/png") throws -> [String: Any] {
        let bytes = Data(repeating: 255, count: 16)
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        let image = try XCTUnwrap(CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, (mime == "image/png" ? "public.png" : mime == "image/tiff" ? "public.tiff" : "public.jpeg") as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return ["type": "image", "mimeType": mime, "data": (data as Data).base64EncodedString()]
    }
    private func event(_ content: [[String: Any]], id: String = "one", server: String = "cua_repl", tool: String = "js", status: String = "completed", thread: String = "thread", turn: String = "turn") -> [String: Any] {
        ["method": "item/completed", "params": ["threadId": thread, "turnId": turn,
            "item": ["id": id, "type": "mcpToolCall", "server": server, "tool": tool, "status": status,
                "result": ["content": content]]]]
    }
    func testNativeImagesKeepEmissionOrderAndDeduplicateCompletedItems() throws {
        let root = try workspace()
        var accumulator = CodexTurnAccumulator(threadID: "thread", turnID: "turn", workspace: root)
        let first = event([try image(), try image("image/jpeg")])
        _ = accumulator.consume(first); _ = accumulator.consume(first)
        let result = accumulator.result()
        XCTAssertEqual(result.nativeCapturePaths.count, 2)
        XCTAssertTrue(result.nativeCapturePaths[0].hasSuffix(".png"))
        XCTAssertTrue(result.nativeCapturePaths[1].hasSuffix(".jpg"))
        for path in result.nativeCapturePaths {
            XCTAssertTrue(path.hasPrefix(root + "/.steve-artifacts/"))
            XCTAssertNotNil(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        }
        XCTAssertTrue(result.attachments.isEmpty, "Capture registration does not automatically select attachments")
        XCTAssertTrue(accumulator.result(wasInterrupted: true).nativeCapturePaths.isEmpty)
    }
    func testOnlySuccessfulCurrentTurnOfficialCUAEmissionsAreRegistered() throws {
        var accumulator = CodexTurnAccumulator(threadID: "thread", turnID: "turn", workspace: try workspace())
        let content = [try image()]
        for bad in [event(content, server: "other"), event(content, tool: "other"), event(content, status: "failed"), event(content, thread: "other"), event(content, turn: "other")] {
            _ = accumulator.consume(bad)
        }
        var argumentsOnly = event([])
        var params = argumentsOnly["params"] as! [String: Any]
        var item = params["item"] as! [String: Any]
        item["arguments"] = ["content": content]
        params["item"] = item; argumentsOnly["params"] = params
        _ = accumulator.consume(argumentsOnly)
        XCTAssertTrue(accumulator.result().nativeCapturePaths.isEmpty)
    }
    func testReencodedNativeCaptureUsesDecodedFormatInsteadOfStaleMIME() throws {
        var accumulator = CodexTurnAccumulator(threadID: "thread", turnID: "turn", workspace: try workspace())
        // Observed live CUA output: JPEG bytes advertised as image/png.
        var reencoded = try image("image/jpeg")
        reencoded["mimeType"] = "image/png"
        _ = accumulator.consume(event([try image()]))
        _ = accumulator.consume(event([reencoded], id: "final"))
        let paths = accumulator.result().nativeCapturePaths
        XCTAssertEqual(paths.count, 2)
        let path = try XCTUnwrap(paths.last)
        XCTAssertTrue(path.hasSuffix(".jpg"))
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.jpeg")
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }
    func testInvalidFinalImageNeverFallsBackToAnEarlierCapture() throws {
        let valid = try image()
        var unsupportedBytes = try image("image/tiff")
        unsupportedBytes["mimeType"] = "image/png"
        let invalids: [[String: Any]] = [
            ["type": "image", "mimeType": "image/gif", "data": "AA=="],
            ["type": "image", "mimeType": "image/png", "data": "not base64"],
            ["type": "image", "mimeType": "image/png", "data": Data("not an image".utf8).base64EncodedString()], unsupportedBytes]
        for invalid in invalids {
            var accumulator = CodexTurnAccumulator(threadID: "thread", turnID: "turn", workspace: try workspace())
            _ = accumulator.consume(event([valid]))
            XCTAssertEqual(accumulator.result().nativeCapturePaths.count, 1)
            _ = accumulator.consume(event([invalid], id: "last"))
            XCTAssertTrue(accumulator.result().nativeCapturePaths.isEmpty)
        }
    }
    func testCaptureLimitFailsClosedAndNoWorkspaceCannotCapture() throws {
        let content = try image()
        var accumulator = CodexTurnAccumulator(threadID: "thread", turnID: "turn", workspace: try workspace())
        _ = accumulator.consume(event(Array(repeating: content, count: 33)))
        XCTAssertTrue(accumulator.result().nativeCapturePaths.isEmpty)
        var noWorkspace = CodexTurnAccumulator(threadID: "thread", turnID: "turn")
        _ = noWorkspace.consume(event([content]))
        XCTAssertTrue(noWorkspace.result().nativeCapturePaths.isEmpty)
        XCTAssertTrue(CodexTurnResult(text: "fixture", attachmentPaths: []).nativeCapturePaths.isEmpty)
    }
}
