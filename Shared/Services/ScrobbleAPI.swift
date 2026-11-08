//
//  ScrobbleAPI.swift
//  Ownwave
//

import Foundation

/// A playback state as OpenSubsonic's reportPlayback takes it.
enum PlaybackReportState: String {
  case starting, playing, paused, stopped
}

class ScrobbleAPI {
  static let shared: ScrobbleAPI = ScrobbleAPI()

  func scrobbleToBuiltinEndpoint(submission: Bool, songId: String, time: Date? = nil) async throws {
    var params: [String: Any] = ["submission": String(submission), "id": songId]

    if submission {
      params["time"] = Int64((time ?? Date()).timeIntervalSince1970 * 1000)
    }

    try await APIManager.shared.subsonicAction(
      endpoint: API.SubsonicEndpoint.scrobble, parameters: params)
  }

  /// Tells the server where playback of a song stands, for its now playing
  /// list. Plays are counted by scrobbles alone, so the report never counts one.
  func reportPlayback(mediaId: String, positionMs: Int, state: PlaybackReportState) async throws {
    let params: [String: Any] = [
      "mediaId": mediaId, "mediaType": "song", "positionMs": positionMs,
      "state": state.rawValue, "ignoreScrobble": "true",
    ]
    #if DEBUG
      debugLogReport(params)
    #endif

    try await APIManager.shared.subsonicAction(
      endpoint: API.SubsonicEndpoint.reportPlayback, parameters: params)
  }

  /// Whether a failed scrobble, star or rating edit can never succeed and
  /// should be dropped instead of retried: the server says the item is gone or
  /// the request lacks a parameter. Navidrome answers those with HTTP 200 and a
  /// Subsonic code, so an HTTP error status comes from something in front of it
  /// (a proxy during an upgrade) and stays queued, like offline and timeouts.
  func isPermanentFailure(_ error: Error) -> Bool {
    guard let subsonicError = error as? SubsonicError else { return false }
    // 10: required parameter missing, 70: requested data not found
    return subsonicError.code == 10 || subsonicError.code == 70
  }
}
