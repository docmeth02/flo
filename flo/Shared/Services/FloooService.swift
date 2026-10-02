import Alamofire
import Foundation

//
//  FloooService.swift
//  flo
//
//  Created by rizaldy on 22/11/24.
//

/// A playback state as OpenSubsonic's reportPlayback takes it.
enum PlaybackReportState: String {
  case starting, playing, paused, stopped
}

class FloooService {
  static let shared: FloooService = FloooService()

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

  /// Tells the server where playback of a song stands, for its now playing
  /// list. Plays are counted by scrobbles alone, so the report never counts one.
  func reportPlayback(
    mediaId: String, positionMs: Int, state: PlaybackReportState,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    let params: [String: Any] = [
      "mediaId": mediaId, "mediaType": "song", "positionMs": positionMs,
      "state": state.rawValue, "ignoreScrobble": "true",
    ]
    #if DEBUG
      if ProcessInfo.processInfo.environment["FLO_DEBUG_REPORT"] == "1" {
        debugLog("reportPlayback \(params.sorted { $0.key < $1.key })")
      }
    #endif

    APIManager.shared.SubsonicActionRequest(
      endpoint: API.SubsonicEndpoint.reportPlayback, parameters: params, completion: completion)
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
