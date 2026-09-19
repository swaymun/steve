struct MessageID: RawRepresentable, Hashable, Sendable {
  let rawValue: Int64
}

struct ChatID: RawRepresentable, Hashable, Sendable {
  let rawValue: Int64
}

struct HandleID: RawRepresentable, Hashable, Sendable {
  let rawValue: Int64
}
