//
//  JSONFile.swift
//  Ownwave
//

import Foundation

/// A value kept as JSON in one small file, read and written synchronously. A
/// missing file reads as `empty`; a file that cannot be read or saved is noted
/// under `label`, so a lost file shows in Diagnostics.
struct JSONFile<Value: Codable> {
  let fileURL: URL
  /// What the file holds, for the log.
  let label: String
  /// What a missing or unreadable file reads as.
  let empty: Value
  let options: Data.WritingOptions

  init(fileURL: URL, label: String, empty: Value, options: Data.WritingOptions = .atomic) {
    self.fileURL = fileURL
    self.label = label
    self.empty = empty
    self.options = options
  }

  func load() -> Value {
    do {
      return try JSONDecoder().decode(Value.self, from: Data(contentsOf: fileURL))
    } catch CocoaError.fileReadNoSuchFile {
      return empty
    } catch {
      RequestLog.shared.note("\(label) unreadable: \(error)")
      return empty
    }
  }

  func save(_ value: Value) {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(value).write(to: fileURL, options: options)
    } catch {
      RequestLog.shared.note("\(label) not saved: \(error)")
    }
  }
}
