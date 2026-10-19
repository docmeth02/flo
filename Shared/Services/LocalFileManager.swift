//
//  LocalFileManager.swift
//  flo
//

import Foundation

class LocalFileManager {
  static let shared = LocalFileManager()

  let fileManager = FileManager.default
  let documentsDirectory = URL.documentsDirectory

  private init() {}

  func fileURL(for fileName: String) -> URL {
    documentsDirectory.appendingPathComponent(fileName)
  }

  /// The size of the downloads folder, measured off the main thread.
  func calculateDirectorySize() async -> String {
    bytesToMBOrGB(await downloadsBytes())
  }

  func downloadsBytes() async -> Int64 {
    await Task.detached(priority: .userInitiated) { self.directorySize() }.value
  }

  private func directorySize() -> Int64 {
    guard
      let enumerator = fileManager.enumerator(
        at: fileURL(for: "Media"),
        includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
        options: [.skipsHiddenFiles])
    else {
      return 0
    }

    var totalSize: Int64 = 0
    for case let fileURL as URL in enumerator {
      do {
        let resourceValues = try fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey])

        if let size = resourceValues.totalFileAllocatedSize {
          totalSize += Int64(size)
        }
      } catch {
        debugLog("Error calculating size for \(fileURL.path): \(error)")
      }
    }

    return totalSize
  }

  func fileExists(fileName: String) -> Bool {
    fileManager.fileExists(atPath: fileURL(for: fileName).path)
  }

  /// Moves the file into place with its parent folders, replacing what is
  /// there unless `forceOverride` is false.
  @discardableResult
  func moveFile(source: URL, target: URL, forceOverride: Bool = true) throws -> URL {
    try fileManager.createDirectory(
      at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    if forceOverride, fileManager.fileExists(atPath: target.path) {
      try fileManager.removeItem(at: target)
    }
    try fileManager.moveItem(at: source, to: target)
    try? fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
    return target
  }

  func deleteDownloadedAlbums(completion: @escaping (Result<Bool, Error>) -> Void) {
    let folderURL = fileURL(for: "Media")

    do {
      if fileManager.fileExists(atPath: folderURL.path) {
        try fileManager.removeItem(at: folderURL)
        debugLog("Folder media deleted successfully")

        completion(.success(true))
      } else {
        debugLog("Folder media somehow does not exist")

        completion(.success(false))
      }
    } catch {
      debugLog("Error deleting folder: \(error.localizedDescription)")

      completion(.failure(error))
    }
  }
}

extension URL {
  /// A folder in the app's caches, created when missing.
  static func cacheDirectory(named name: String) -> URL {
    let url = URL.cachesDirectory.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
