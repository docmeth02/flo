//
//  ArtistRadio.swift
//  flo
//

import Foundation

/// Selects the payload key of a Subsonic song list response.
protocol SubsonicSongListKey {
  static var key: String { get }
}

enum SimilarSongsKey: SubsonicSongListKey {
  static let key = "similarSongs2"
}

enum TopSongsKey: SubsonicSongListKey {
  static let key = "topSongs"
}

/// A Subsonic song list payload (getSimilarSongs2, getTopSongs).
struct SubsonicSongList<Key: SubsonicSongListKey>: SubsonicResponseData {
  static var key: String { Key.key }
  let song: [SubsonicSong]?

  var songs: [Song] {
    (song ?? []).map { $0.toSong() }
  }
}
