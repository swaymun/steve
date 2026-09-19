import Foundation

enum TypedStreamParser {
  static func parseAttributedBody(_ data: Data) -> String {
    guard !data.isEmpty else { return "" }
    let bytes = [UInt8](data)
    if bytes.count >= 2, bytes[0] == 0xff, bytes[1] == 0xfe {
      let payload = data.dropFirst(2)
      if let text = String(data: payload, encoding: .utf16LittleEndian) {
        return text.trimmingLeadingControlCharacters()
      }
    }
    let start = [UInt8(0x01), UInt8(0x2b)]
    let end = [UInt8(0x86), UInt8(0x84)]
    var best = ""

    var index = 0
    while index + 1 < bytes.count {
      if bytes[index] == start[0], bytes[index + 1] == start[1] {
        let sliceStart = index + 2
        if let sliceEnd = findSequence(end, in: bytes, from: sliceStart) {
          let segment = Array(bytes[sliceStart..<sliceEnd])
          let candidate = decodeSegment(segment)
          if candidate.count > best.count {
            best = candidate
          }
        }
      }
      index += 1
    }

    if !best.isEmpty {
      return best
    }

    let text = String(decoding: bytes, as: UTF8.self)
    return text.trimmingLeadingControlCharacters()
  }

  /// Strips a typedstream length prefix from `segment` and returns the longest valid UTF-8 decoding.
  /// Length prefix forms (BER-style): single byte (< 0x80), `0x81 NN`, or `0x82 NN NN`.
  /// Structured prefixes always win over the raw `prefixLen = 0` decode: otherwise, when the
  /// length byte is itself a printable-ASCII character (body length 32–126), the unstripped decode
  /// produces an N+1 character string that beats the correct N-character body.
  private static func decodeSegment(_ segment: [UInt8]) -> String {
    guard let first = segment.first else { return "" }

    var structuredPrefixes: [Int] = []
    if first < 0x80, Int(first) == segment.count - 1 {
      structuredPrefixes.append(1)
    }
    if first == 0x81, segment.count >= 2 {
      structuredPrefixes.append(2)
    }
    if first == 0x82, segment.count >= 3 {
      structuredPrefixes.append(3)
    }

    var bestStructured = ""
    var anyStructuredValid = false
    for prefixLen in structuredPrefixes {
      let body = Array(segment[prefixLen...])
      guard
        let candidate = String(bytes: body, encoding: .utf8)?
          .trimmingLeadingControlCharacters()
      else { continue }
      anyStructuredValid = true
      if candidate.count > bestStructured.count {
        bestStructured = candidate
      }
    }
    if anyStructuredValid {
      return bestStructured
    }

    return String(bytes: segment, encoding: .utf8)?
      .trimmingLeadingControlCharacters() ?? ""
  }

  private static func findSequence(_ needle: [UInt8], in haystack: [UInt8], from start: Int)
    -> Int?
  {
    guard !needle.isEmpty else { return nil }
    guard start >= 0, start < haystack.count else { return nil }
    let limit = haystack.count - needle.count
    if limit < start { return nil }
    var index = start
    while index <= limit {
      var matched = true
      for offset in 0..<needle.count {
        if haystack[index + offset] != needle[offset] {
          matched = false
          break
        }
      }
      if matched { return index }
      index += 1
    }
    return nil
  }
}

extension String {
  fileprivate func trimmingLeadingControlCharacters() -> String {
    var scalars = unicodeScalars
    while let first = scalars.first,
      CharacterSet.controlCharacters.contains(first) || first == "\n" || first == "\r"
    {
      scalars.removeFirst()
    }
    return String(String.UnicodeScalarView(scalars))
  }
}
