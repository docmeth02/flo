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

  func saveListeningHistory(payload: QueueEntity) {
    let currentSession = HistoryEntity(context: CoreDataManager.shared.viewContext)

    currentSession.albumId = payload.albumId
    currentSession.artistName = payload.artistName
    currentSession.trackName = payload.songName
    currentSession.albumName = payload.albumName
    currentSession.songId = payload.id
    currentSession.timestamp = Date()

    CoreDataManager.shared.saveRecord()
  }

  func getAccountLinkStatuses(completion: @escaping (Result<AccountLinkStatus, Error>) -> Void) {
    let group = DispatchGroup()

    var listenBrainzStatus: Bool?
    var lastFMStatus: Bool?
    var requestError: Error?

    group.enter()

    checkListenBrainzAccountStatus { result in
      switch result {
      case .success(let status):
        listenBrainzStatus = status
      case .failure(let error):
        requestError = error
      }

      group.leave()
    }

    group.enter()

    checkLastFMAccountStatus { result in
      switch result {
      case .success(let status):
        lastFMStatus = status
      case .failure(let error):
        requestError = error
      }

      group.leave()
    }

    group.notify(queue: .main) {
      if listenBrainzStatus == nil || lastFMStatus == nil, let requestError = requestError {
        completion(.failure(requestError))
        return
      }

      completion(
        .success(
          AccountLinkStatus(
            listenBrainz: listenBrainzStatus ?? false,
            lastFM: lastFMStatus ?? false)))
    }
  }

  func checkListenBrainzAccountStatus(completion: @escaping (Result<Bool, Error>) -> Void) {
    APIManager.shared.NDEndpointRequest(
      endpoint: API.NDEndpoint.listenBrainzLink, parameters: [:], timeout: 8
    ) {
      (response: DataResponse<AccountStatusResponse, AFError>) in
      switch response.result {
      case .success(let status):
        completion(.success(status.status))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func checkLastFMAccountStatus(completion: @escaping (Result<Bool, Error>) -> Void) {
    APIManager.shared.NDEndpointRequest(
      endpoint: API.NDEndpoint.lastFMLink, parameters: [:], timeout: 8
    ) {
      (response: DataResponse<AccountStatusResponse, AFError>) in
      switch response.result {
      case .success(let status):
        completion(.success(status.status))
      case .failure(let error):
        completion(.failure(error))
      }
    }
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

extension FloooService {
  struct AccountStatusResponse: Decodable {
    let status: Bool
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
