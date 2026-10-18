//
//  LibrarySearch.swift
//  flo
//

import Foundation

/// Searches the library already on the device, so it works offline.
enum LibrarySearch {
  struct Results {
    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }
  }

  /// How many results of each kind a screen lists.
  struct Limits {
    let artists: Int
    let albums: Int
    let songs: Int

    static let watch = Limits(artists: 5, albums: 5, songs: 15)
    static let phone = Limits(artists: 20, albums: 20, songs: 50)
  }

  /// Artists by name, albums by name and album artist, songs by title,
  /// artist and album, ignoring case and accents. Nil for a blank query,
  /// which searches nothing.
  static func search(
    _ query: String, artists: [Artist], albums: [Album], songs: [Song], limits: Limits
  ) -> Results? {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return nil }
    return Results(
      artists: matches(query, in: artists, limit: limits.artists, fields: [\.name]),
      albums: matches(query, in: albums, limit: limits.albums, fields: [\.name, \.albumArtist]),
      songs: matches(
        query, in: songs, limit: limits.songs, fields: [\.title, \.artist, \.albumName]))
  }

  /// Up to `limit` items with a field containing `query`. Those whose first
  /// field, the name, starts with it come first ("love" lists "Lovesong"
  /// before "Glove" and the songs of an album called "Love"); otherwise the
  /// list's order is kept.
  private static func matches<T>(
    _ query: String, in items: [T], limit: Int, fields: [KeyPath<T, String>]
  ) -> [T] {
    guard let name = fields.first else { return [] }
    var leading: [T] = []
    var rest: [T] = []
    for item in items {
      if item[keyPath: name].range(
        of: query, options: [.caseInsensitive, .diacriticInsensitive, .anchored], locale: .current)
        != nil
      {
        leading.append(item)
        if leading.count == limit { break }
      } else if rest.count < limit,
        fields.contains(where: { item[keyPath: $0].localizedStandardContains(query) })
      {
        rest.append(item)
      }
    }
    return Array((leading + rest).prefix(limit))
  }
}
