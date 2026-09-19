import Foundation

public enum IMsgError: LocalizedError, CustomStringConvertible, Sendable {
  case permissionDenied(path: String, underlying: Error)
  case invalidISODate(String)
  case invalidService(String)
  case unsupportedService(String)
  case invalidChatTarget(String)
  case appleScriptFailure(String)
  case typingIndicatorFailed(String)
  case invalidReaction(String)
  case unsupportedReaction(String)
  case chatNotFound(chatID: Int64)

  public var errorDescription: String? {
    switch self {
    case .permissionDenied(let path, let underlying):
      return """
        \(underlying)

        ⚠️  Permission Error: Cannot access Messages database

        The Messages database at \(path) requires Full Disk Access permission.

        To fix:
        1. Open System Settings → Privacy & Security → Full Disk Access
        2. Add Steve to the list and enable it
        3. Restart Steve, then try again

        Note: This is required because macOS protects the Messages database.
        For more details, see: https://github.com/steipete/imsg#permissions-troubleshooting
        """
    case .invalidISODate(let value):
      return "Invalid ISO8601 date: \(value)"
    case .invalidService(let value):
      return "Invalid service: \(value)"
    case .unsupportedService(let value):
      return "Unsupported service: \(value)"
    case .invalidChatTarget(let value):
      return "Invalid chat target: \(value)"
    case .appleScriptFailure(let message):
      return "AppleScript failed: \(message)"
    case .typingIndicatorFailed(let message):
      return "Typing indicator failed: \(message)"
    case .invalidReaction(let value):
      return """
        Invalid reaction: \(value)

        Valid reactions: love, like, dislike, laugh, emphasis, question
        """
    case .unsupportedReaction(let message):
      return "Unsupported reaction: \(message)"
    case .chatNotFound(let chatID):
      return "Chat not found: \(chatID)"
    }
  }

  public var description: String {
    errorDescription ?? "Unknown imsg error"
  }
}
