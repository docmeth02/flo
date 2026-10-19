//
//  Radio.swift
//  flo
//

import Foundation

struct RadioList: SubsonicResponseData {
  static let key = "internetRadioStations"
  let internetRadioStation: [Radio]
}

struct Radio: Codable, Identifiable, Hashable {
  let id: String
  let name: String
  let streamUrl: String

  /// The station as a queue of one endless song, with its host as the artist.
  func toPlayable() -> SongCollection {
    SongCollection(
      id: id,
      name: name,
      songs: [
        Song(
          id: id,
          title: name,
          albumId: "",
          albumName: "",
          artist: Radio.displayHost(from: streamUrl),
          trackNumber: 1,
          discNumber: 1,
          bitRate: .zero,
          sampleRate: 0,
          suffix: "",
          duration: .infinity,
          mediaFileId: id
        )
      ]
    )
  }

  private static func displayHost(from urlString: String) -> String {
    guard let url = URL(string: urlString),
      let host = url.host,
      !host.isEmpty
    else {
      return urlString
    }

    return host
  }
}
