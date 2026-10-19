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
}

struct SubsonicSongListResponse<Key: SubsonicSongListKey>: Decodable {
  let subsonicResponse: SubsonicResponse<SubsonicSongList<Key>>

  private enum CodingKeys: String, CodingKey {
    case subsonicResponse = "subsonic-response"
  }

  var songs: [Song] {
    (subsonicResponse.data?.song ?? []).map { $0.toSong() }
  }
}

typealias SimilarSongsResponse = SubsonicSongListResponse<SimilarSongsKey>
typealias TopSongsResponse = SubsonicSongListResponse<TopSongsKey>
