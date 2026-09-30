import Alamofire
import Foundation

//
//  FloooService.swift
//  flo
//
//  Created by rizaldy on 22/11/24.
//

class FloooService {
  static let shared: FloooService = FloooService()

  func saveListeningHistory(payload: QueueEntity, skipped: Bool = false) {
    let currentSession = HistoryEntity(context: CoreDataManager.shared.viewContext)

    currentSession.albumId = payload.albumId
    currentSession.artistName = payload.artistName
    currentSession.trackName = payload.songName
    currentSession.albumName = payload.albumName
    currentSession.songId = payload.id
    currentSession.timestamp = Date()
    currentSession.skipped = skipped

    CoreDataManager.shared.saveRecord()
  }

  func scrobbleToBuiltinEndpoint(
    submission: Bool, songId: String, time: Date? = nil, timeout: TimeInterval? = nil,
    completion: @escaping (Result<BasicSubsonicResponse, Error>) -> Void
  ) {
    var params: [String: Any] = ["submission": String(submission), "id": songId]

    if submission {
      params["time"] = Int64((time ?? Date()).timeIntervalSince1970 * 1000)
    }

    APIManager.shared.SubsonicEndpointRequest(
      endpoint: API.SubsonicEndpoint.scrobble, parameters: params, timeout: timeout
    ) {
      (response: DataResponse<BasicSubsonicResponse, AFError>) in
      switch response.result {
      case .success(let response):
        completion(.success(response))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }
}

extension AFError {
  var receivedServerResponse: Bool {
    switch self {
    case .responseValidationFailed, .responseSerializationFailed:
      return true
    default:
      return false
    }
  }
}

extension FloooService {
  func shouldQueueOfflineScrobble(_ error: Error) -> Bool {
    guard let afError = error as? AFError else { return true }
    return !afError.receivedServerResponse
  }
}
