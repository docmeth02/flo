//
//  LibraryCacheManager.swift
//  flo
//

import Foundation

class LibraryCacheManager {
  static let shared = LibraryCacheManager()

  /// One JSON file per key, named after the raw value.
  enum Key: String {
    case albums, artists, playlists, starredSongs, songs, ratedSongs, ratedAlbums
    case songsStamp = "songs.stamp"
  }

  private let fileManager = FileManager.default
  private let cacheDirectory: URL?
  private let lock = NSLock()
  private var currentGeneration = 0

  private init() {
    self.cacheDirectory =
      fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?
      .appendingPathComponent("LibraryCache")

    if let dir = cacheDirectory, !fileManager.fileExists(atPath: dir.path) {
      try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }

  /// Bumped by `clearCache()`. Capture it before a library request and pass it
  /// to `save`, so a fetch that outlived a logout cannot refill the cache with
  /// the previous account's library.
  var generation: Int {
    lock.withLock { currentGeneration }
  }

  func save<T: Encodable>(_ items: T, forKey key: Key, generation: Int) {
    guard let dir = cacheDirectory, let data = try? JSONEncoder().encode(items) else { return }
    let file = dir.appendingPathComponent("\(key.rawValue).json")
    lock.withLock {
      guard generation == currentGeneration else { return }
      try? data.write(to: file, options: .atomic)
    }
  }

  func load<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
    guard let dir = cacheDirectory else { return nil }
    let file = dir.appendingPathComponent("\(key.rawValue).json")
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  /// When the entry for `key` was last written, or nil if there is none.
  func modificationDate(forKey key: Key) -> Date? {
    guard let dir = cacheDirectory else { return nil }
    let file = dir.appendingPathComponent("\(key.rawValue).json")
    return (try? fileManager.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date
  }

  func clearCache() {
    lock.withLock {
      currentGeneration += 1
      guard let dir = cacheDirectory, fileManager.fileExists(atPath: dir.path) else { return }
      try? fileManager.removeItem(at: dir)
      try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }
  }
}
