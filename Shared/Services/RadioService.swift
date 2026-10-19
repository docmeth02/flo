//
//  RadioService.swift
//  flo
//

import Foundation
import Alamofire

class RadioService {
  static let shared = RadioService()

  func getAllRadios(completion: @escaping (Result<[Radio], Error>) -> Void) {
    APIManager.shared.SubsonicEndpointRequest(endpoint: API.SubsonicEndpoint.radios, parameters: nil) {
      (response: DataResponse<SubsonicEnvelope<RadioList>, AFError>) in
      completion(response.result.map { $0.data?.internetRadioStation ?? [] }.mapError { $0 })
    }
  }

  func getSimilarSongs(id: String, count: Int = 100, completion: @escaping (Result<[Song], Error>) -> Void) {
    let params: [String: Any] = ["id": id, "count": count]

    APIManager.shared.SubsonicEndpointRequest(endpoint: API.SubsonicEndpoint.similarSongs, parameters: params) {
      (response: DataResponse<SubsonicEnvelope<SubsonicSongList<SimilarSongsKey>>, AFError>) in
      completion(response.result.map { $0.data?.songs ?? [] }.mapError { $0 })
    }
  }

  /// The artist's most played songs, looked up by id (OpenSubsonic
  /// topSongsByArtistId), so artists that share a name stay apart.
  func getTopSongs(artistId: String, count: Int = 20, completion: @escaping (Result<[Song], Error>) -> Void) {
    let params: [String: Any] = ["id": artistId, "count": count]

    APIManager.shared.SubsonicEndpointRequest(endpoint: API.SubsonicEndpoint.topSongs, parameters: params) {
      (response: DataResponse<SubsonicEnvelope<SubsonicSongList<TopSongsKey>>, AFError>) in
      completion(response.result.map { $0.data?.songs ?? [] }.mapError { $0 })
    }
  }
}
