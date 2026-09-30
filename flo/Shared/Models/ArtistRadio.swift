//    flo

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

/// A Subsonic song list payload (getSimilarSongs2, getTopSongs), decoded
/// leniently: optional fields fall back to empty values.
struct SubsonicSongList<Key: SubsonicSongListKey>: SubsonicResponseData {
  static var key: String { Key.key }
  let song: [Song]

  private enum CodingKeys: String, CodingKey {
    case song
  }

  private enum SubsonicSongKeys: String, CodingKey {
    case id, title, artist, albumId, album, track, discNumber, bitRate, samplingRate, suffix,
      duration, mediaFileId, explicitStatus
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)

    guard var songsContainer = try? container.nestedUnkeyedContainer(forKey: .song) else {
      self.song = []
      return
    }

    var songs: [Song] = []
    while !songsContainer.isAtEnd {
      let s = try songsContainer.nestedContainer(keyedBy: SubsonicSongKeys.self)
      songs.append(
        Song(
          id: try s.decode(String.self, forKey: .id),
          title: try s.decode(String.self, forKey: .title),
          albumId: try s.decodeIfPresent(String.self, forKey: .albumId) ?? "",
          albumName: try s.decodeIfPresent(String.self, forKey: .album) ?? "",
          artist: try s.decode(String.self, forKey: .artist),
          trackNumber: try s.decodeIfPresent(Int.self, forKey: .track) ?? 0,
          discNumber: try s.decodeIfPresent(Int.self, forKey: .discNumber) ?? 0,
          bitRate: try s.decodeIfPresent(Int.self, forKey: .bitRate) ?? 0,
          sampleRate: try s.decodeIfPresent(Int.self, forKey: .samplingRate) ?? 0,
          suffix: try s.decodeIfPresent(String.self, forKey: .suffix) ?? "",
          duration: try s.decode(Double.self, forKey: .duration),
          mediaFileId: try s.decodeIfPresent(String.self, forKey: .mediaFileId) ?? "",
          explicitStatus: ExplicitStatus(
            from: try s.decodeIfPresent(String.self, forKey: .explicitStatus))
        ))
    }
    self.song = songs
  }
}

struct SubsonicSongListResponse<Key: SubsonicSongListKey>: Codable {
  let subsonicResponse: SubsonicResponse<SubsonicSongList<Key>>

  private enum CodingKeys: String, CodingKey {
    case subsonicResponse = "subsonic-response"
  }

  var songs: [Song] {
    return subsonicResponse.data?.song ?? []
  }
}

typealias SimilarSongsResponse = SubsonicSongListResponse<SimilarSongsKey>
typealias TopSongsResponse = SubsonicSongListResponse<TopSongsKey>
