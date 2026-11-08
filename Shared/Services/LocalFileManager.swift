//
//  LocalFileManager.swift
//  Ownwave
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
  /// there unless `forceOverride` is false. Every caller hands over a file
  /// of its own, so one that cannot be moved is removed. Everything moved
  /// here can be fetched again, so it stays out of the device's backup.
  @discardableResult
  func moveFile(source: URL, target: URL, forceOverride: Bool = true) throws -> URL {
    do {
      try fileManager.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      if forceOverride, fileManager.fileExists(atPath: target.path) {
        try fileManager.removeItem(at: target)
      }
      try fileManager.moveItem(at: source, to: target)
    } catch {
      try? fileManager.removeItem(at: source)
      throw error
    }
    try? fileManager.setAttributes(
      [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
      ofItemAtPath: target.path)
    excludeFromBackup(target)
    return target
  }

  func excludeFromBackup(_ file: URL) {
    var file = file
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? file.setResourceValues(values)
  }

  /// Downloads saved before they were kept out of the backup, off the main
  /// thread.
  func excludeDownloadsFromBackup() {
    Task.detached(priority: .utility) { self.excludeMediaFromBackup() }
  }

  private func excludeMediaFromBackup() {
    let key = URLResourceKey.isExcludedFromBackupKey
    guard
      let enumerator = fileManager.enumerator(
        at: fileURL(for: "Media"), includingPropertiesForKeys: [key])
    else { return }
    for case let file as URL in enumerator
    where (try? file.resourceValues(forKeys: [key]))?.isExcludedFromBackup != true {
      excludeFromBackup(file)
    }
  }

  func deleteDownloadedAlbums(completion: @escaping (Result<Void, Error>) -> Void) {
    let folderURL = fileURL(for: "Media")
    do {
      if fileManager.fileExists(atPath: folderURL.path) {
        try fileManager.removeItem(at: folderURL)
      }
      completion(.success(()))
    } catch {
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
