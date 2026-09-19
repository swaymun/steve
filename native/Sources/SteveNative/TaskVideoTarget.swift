import CoreGraphics
import Foundation

/// Capture scope is always explicit. An unavailable window never becomes a
/// display recording, and window-only capture never opts into system audio.
enum TaskVideoTarget: Equatable, Sendable {
    case display(UInt32)
    case window(UInt32, app: String)

    static func parse(_ options: [String: String]) throws -> Self {
        if let raw = options["display"] {
            guard options["window"] == nil, options["app"] == nil, let id = UInt32(raw), id != 0 else { throw TaskVideoError.invalidOptions }
            return .display(id)
        }
        guard let raw = options["window"], let id = UInt32(raw), id != 0,
              let app = options["app"], validAppID(app), options["audio"] != "true" else {
            throw RPCError(message: "Select one task window with --window ID --app BUNDLE_ID. Window-only recording does not capture system audio. Full-display capture requires explicit --display ID authorization.")
        }
        return .window(id, app: app)
    }
    static func validAppID(_ app: String) -> Bool {
        app.utf8.count <= 255 && app.range(of: "^[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)+$", options: .regularExpression) != nil
    }
    var label: String { switch self { case .display: return "display"; case .window: return "window" } }
}

struct TaskVideoWindow: Codable, Equatable, Sendable {
    let windowID: UInt32
    let processID: Int32
    let app: String
    let title: String
    let width: Int
    let height: Int

    static func selected(id: UInt32, app: String, from windows: [Self]) throws -> Self {
        let matches = windows.filter { $0.windowID == id }
        guard matches.count == 1, let match = matches.first, match.app == app,
              match.processID > 0, match.width > 0, match.height > 0 else {
            throw RPCError(message: "The selected task window is missing or ambiguous. Inspect the app's current windows again; display capture was not started.")
        }
        return match
    }

    /// Check the exact existing window before appending frames. Moving is fine;
    /// closing, hiding, replacing, or resizing discards the recording.
    func stillMatches(_ info: [String: Any]) -> Bool {
        guard (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID,
              (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processID,
              info[kCGWindowIsOnscreen as String] as? Bool == true,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
              rect.width.isFinite, rect.height.isFinite, rect.width >= 0, rect.height >= 0,
              rect.width < CGFloat(Int.max), rect.height < CGFloat(Int.max) else { return false }
        return Int(rect.width.rounded(.up)) == width && Int(rect.height.rounded(.up)) == height
    }
}
