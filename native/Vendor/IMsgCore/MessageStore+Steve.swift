import SQLite

extension MessageStore {
  /// Resolves the stable Messages chat row used by MessageWatcher from the
  /// chat GUID Steve stores as its trust boundary.
  public func steveChatID(forGUID guid: String) throws -> Int64? {
    let rows = try withConnection { db in
      try db.prepareRowIterator("SELECT ROWID AS chat_rowid FROM chat WHERE guid = ? LIMIT 1", bindings: [guid])
    }
    guard let row = try rows.failableNext() else { return nil }
    return try int64Value(row, "chat_rowid")
  }
}
