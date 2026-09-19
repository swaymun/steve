import Foundation
import SQLite

extension MessageStore {
  func stringValue(_ row: Row, _ column: String) throws -> String {
    try row.get(Expression<String?>(column)) ?? ""
  }

  func int64Value(_ row: Row, _ column: String) throws -> Int64? {
    try row.get(Expression<Int64?>(column))
  }

  func intValue(_ row: Row, _ column: String) throws -> Int? {
    guard let value = try int64Value(row, column) else { return nil }
    return Int(value)
  }

  func boolValue(_ row: Row, _ column: String) throws -> Bool {
    try row.get(Expression<Bool?>(column)) ?? false
  }

  func dataValue(_ row: Row, _ column: String) throws -> Data {
    guard let blob = try row.get(Expression<Blob?>(column)) else { return Data() }
    return Data(blob.bytes)
  }
}
