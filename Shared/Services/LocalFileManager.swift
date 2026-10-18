//
//  LocalFileManager.swift
//  flo
//
//  Created by rizaldy on 01/08/24.
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

  func moveFile(
    source: URL, target: URL, forceOverride: Bool = true,
    completion: @escaping (Result<URL, Error>) -> Void
  ) {
    do {
      let parentDirectory = target.deletingLastPathComponent()

      if !self.fileManager.fileExists(atPath: parentDirectory.path) {
        try self.fileManager.createDirectory(
          at: parentDirectory, withIntermediateDirectories: true, attributes: nil)
      }

      if forceOverride {
        if fileManager.fileExists(atPath: target.path) {
          try self.fileManager.removeItem(at: target)
        }
      }

      try self.fileManager.moveItem(at: source, to: target)
      try? self.fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
      completion(.success(target))
    } catch {
      completion(.failure(error))
    }
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
