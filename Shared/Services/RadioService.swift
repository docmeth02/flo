//
//  RadioService.swift
//  flo
//

import Alamofire
import Foundation

class RadioService {
  static let shared = RadioService()

  func getAllRadios(completion: @escaping (Result<[Radio], Error>) -> Void) {
    APIManager.shared.subsonicRequest(endpoint: API.SubsonicEndpoint.radios, parameters: nil) {
      (response: DataResponse<SubsonicEnvelope<RadioList>, AFError>) in
      completion(
        response.result.mapError { $0 }.flatMap { $0.result { $0?.internetRadioStation ?? [] } })
    }
  }

  func getSimilarSongs(
    id: String, count: Int = 100, completion: @escaping (Result<[Song], Error>) -> Void
  ) {
    let params: [String: Any] = ["id": id, "count": count]

    APIManager.shared.subsonicRequest(
      endpoint: API.SubsonicEndpoint.similarSongs, parameters: params
    ) {
      (response: DataResponse<SubsonicEnvelope<SubsonicSongList<SimilarSongsKey>>, AFError>) in
      completion(response.result.mapError { $0 }.flatMap { $0.result { $0?.songs ?? [] } })
    }
  }

  /// The artist's most played songs, looked up by id (OpenSubsonic
  /// topSongsByArtistId), so artists that share a name stay apart.
  func getTopSongs(
    artistId: String, count: Int = 20, completion: @escaping (Result<[Song], Error>) -> Void
  ) {
    let params: [String: Any] = ["id": artistId, "count": count]

    APIManager.shared.subsonicRequest(endpoint: API.SubsonicEndpoint.topSongs, parameters: params) {
      (response: DataResponse<SubsonicEnvelope<SubsonicSongList<TopSongsKey>>, AFError>) in
      completion(response.result.mapError { $0 }.flatMap { $0.result { $0?.songs ?? [] } })
    }
  }
}
