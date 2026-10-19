//
//  LibraryCacheManager.swift
//  flo
//

import Foundation

class LibraryCacheManager {
  static let shared = LibraryCacheManager()

  /// One JSON file per key, named after the raw value.
  enum Key: String {
    case albums, artists, playlists, starredSongs, starredCollections, songs, ratedSongs,
      ratedAlbums, ratedArtists
    case songsStamp = "songs.stamp"
  }

  private let fileManager = FileManager.default
  private let cacheDirectory = URL.cacheDirectory(named: "LibraryCache")
  // Fetches save from any task, and reads run on a GCD queue.
  private let lock = NSLock()
  private var currentGeneration = 0

  private init() {}

  /// Bumped by `clearCache()`. Capture it before a library request and pass it
  /// to `save`, so a fetch that outlived a logout cannot refill the cache with
  /// the previous account's library.
  var generation: Int {
    lock.withLock { currentGeneration }
  }

  func save<T: Encodable>(_ items: T, forKey key: Key, generation: Int) {
    guard let data = try? JSONEncoder().encode(items) else { return }
    lock.withLock {
      guard generation == currentGeneration else { return }
      try? data.write(to: fileURL(key), options: .atomic)
    }
  }

  func load<T: Decodable>(_ type: T.Type, forKey key: Key) -> T? {
    guard let data = try? Data(contentsOf: fileURL(key)) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
  }

  /// Runs `body`, which loads from the cache, on a GCD queue, so the
  /// cooperative thread pool never blocks on disk.
  static func read<T>(
    qos: DispatchQoS.QoSClass = .userInitiated, _ body: @escaping (LibraryCacheManager) -> T
  ) async -> T {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: qos).async { continuation.resume(returning: body(shared)) }
    }
  }

  /// When the entry for `key` was last written, or nil if there is none.
  func modificationDate(forKey key: Key) -> Date? {
    (try? fileManager.attributesOfItem(atPath: fileURL(key).path))?[.modificationDate] as? Date
  }

  func clearCache() {
    lock.withLock {
      currentGeneration += 1
      try? fileManager.removeItem(at: cacheDirectory)
      try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
  }

  private func fileURL(_ key: Key) -> URL {
    cacheDirectory.appendingPathComponent("\(key.rawValue).json")
  }
}
