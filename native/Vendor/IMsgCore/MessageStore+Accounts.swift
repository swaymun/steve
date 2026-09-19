import Foundation
import SQLite

/// A messaging account observed in the local Messages database.
public struct LocalAccount: Sendable, Equatable {
  /// The account login (typically your Apple ID email or phone), from `chat.account_login`.
  public let login: String
  /// The full account identifier (e.g. `iMessage;+;you@icloud.com`), from `chat.account_id`.
  public let accountID: String
  /// Number of local chats routed through this account (useful to rank the primary account).
  public let chatCount: Int

  public init(login: String, accountID: String, chatCount: Int) {
    self.login = login
    self.accountID = accountID
    self.chatCount = chatCount
  }
}

extension MessageStore {
  /// Enumerate the messaging accounts seen in the local `chat.db`.
  ///
  /// This reads `chat.account_login` / `chat.account_id` recorded on each chat,
  /// grouped and ranked by how many chats use them. It reflects accounts
  /// *observed in history*, not a live "currently signed-in" list — for a
  /// single-account Mac these are equivalent, and the result is factual rather
  /// than inferred. Returns an empty array on schemas without account columns.
  public func localAccounts() throws -> [LocalAccount] {
    guard schema.hasChatAccountLoginColumn || schema.hasChatAccountIDColumn else {
      return []
    }
    let loginColumn = schema.hasChatAccountLoginColumn ? "IFNULL(c.account_login, '')" : "''"
    let accountIDColumn = schema.hasChatAccountIDColumn ? "IFNULL(c.account_id, '')" : "''"
    let sql = """
      SELECT \(loginColumn) AS account_login,
             \(accountIDColumn) AS account_id,
             COUNT(*) AS chat_count
      FROM chat c
      GROUP BY account_login, account_id
      HAVING account_login != '' OR account_id != ''
      ORDER BY chat_count DESC
      """
    return try withConnection { db in
      let rows = try db.prepareRowIterator(sql)
      var accounts: [LocalAccount] = []
      while let row = try rows.failableNext() {
        let login = try stringValue(row, "account_login")
        let accountID = try stringValue(row, "account_id")
        let count = try intValue(row, "chat_count") ?? 0
        accounts.append(
          LocalAccount(login: login, accountID: accountID, chatCount: count)
        )
      }
      return accounts
    }
  }
}
