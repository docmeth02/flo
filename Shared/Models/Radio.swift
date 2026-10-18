//
//  Radio.swift
//  flo
//
//  Created by Francesco (f-longobardi)
//

import Foundation

struct RadioList: SubsonicResponseData {
  static let key = "internetRadioStations"
  let internetRadioStation: [Radio]
}

struct RadioListResponse: Decodable {
  let subsonicResponse: SubsonicResponse<RadioList>

  private enum CodingKeys: String, CodingKey {
    case subsonicResponse = "subsonic-response"
  }
  var radioStations: [Radio] {
    return subsonicResponse.data?.internetRadioStation ?? []
  }
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
