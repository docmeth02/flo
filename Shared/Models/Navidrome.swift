//
//  Navidrome.swift
//  Ownwave
//

/// What the server's list of an entity looks like right now: how many items
/// and when the newest one changed. Equal stamps mean an unchanged list.
struct LibraryStamp: Codable, Equatable {
  /// Bumped when cached items gain fields; an older cache is refetched whole.
  static let currentFormat = 2

  let total: Int?  // nil when the server sent no X-Total-Count
  let newestUpdatedAt: String?
  var format: Int? = currentFormat
}

/// A song plus the server's updatedAt, which Song itself neither keeps nor caches.
struct SongPageItem: Decodable {
  let song: Song
  let updatedAt: String?

  private enum Keys: String, CodingKey { case updatedAt }

  init(from decoder: any Decoder) throws {
    song = try Song(from: decoder)
    updatedAt = try decoder.container(keyedBy: Keys.self)
      .decodeIfPresent(String.self, forKey: .updatedAt)
  }
}

/// One counted play in the server's log (Navidrome's /api/scrobble).
struct ScrobbleRow: Decodable, Sendable {
  let id: Int64
  /// Nil or empty once the server lost the file; such a play stays unmatched.
  let mediaFileId: String?
  /// Unix seconds.
  let submissionTime: Int64
}
