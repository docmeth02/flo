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
    submission: Bool, songId: String, time: Date? = nil,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    var params: [String: Any] = ["submission": String(submission), "id": songId]

    if submission {
      params["time"] = Int64((time ?? Date()).timeIntervalSince1970 * 1000)
    }

    APIManager.shared.SubsonicActionRequest(
      endpoint: API.SubsonicEndpoint.scrobble, parameters: params, completion: completion)
  }

  /// Whether a failed scrobble can never succeed and should be dropped instead
  /// of retried: the song is gone or the server refuses the request itself.
  /// Offline, timeouts, server errors, rate limits and expired sessions all
  /// stay queued.
  func isPermanentScrobbleFailure(_ error: Error) -> Bool {
    if let subsonicError = error as? SubsonicError {
      // 10: required parameter missing, 70: requested data not found
      return subsonicError.code == 10 || subsonicError.code == 70
    }
    guard let status = (error as? AFError)?.responseCode else { return false }
    return (400..<500).contains(status) && ![401, 403, 408, 429].contains(status)
  }
}
