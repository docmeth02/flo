//
//  RadioService.swift
//  flo
//

import Alamofire
import Foundation

class RadioService {
  static let shared = RadioService()

  func getAllRadios() async throws -> [Radio] {
    let response: DataResponse<SubsonicEnvelope<RadioList>, AFError> =
      await APIManager.shared.subsonicRequest(
        endpoint: API.SubsonicEndpoint.radios, parameters: nil)
    return try response.result.get().payload { $0?.internetRadioStation ?? [] }
  }

  func getSimilarSongs(id: String, count: Int = 100) async throws -> [Song] {
    let params: [String: Any] = ["id": id, "count": count]

    let response: DataResponse<SubsonicEnvelope<SubsonicSongList<SimilarSongsKey>>, AFError> =
      await APIManager.shared.subsonicRequest(
        endpoint: API.SubsonicEndpoint.similarSongs, parameters: params)
    return try response.result.get().payload { $0?.songs ?? [] }
  }

  /// The artist's most played songs, looked up by id (OpenSubsonic
  /// topSongsByArtistId), so artists that share a name stay apart.
  func getTopSongs(artistId: String, count: Int = 20) async throws -> [Song] {
    let params: [String: Any] = ["id": artistId, "count": count]

    let response: DataResponse<SubsonicEnvelope<SubsonicSongList<TopSongsKey>>, AFError> =
      await APIManager.shared.subsonicRequest(
        endpoint: API.SubsonicEndpoint.topSongs, parameters: params)
    return try response.result.get().payload { $0?.songs ?? [] }
  }
}
