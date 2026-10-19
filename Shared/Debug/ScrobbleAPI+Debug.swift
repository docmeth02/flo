//
//  ScrobbleAPI+Debug.swift
//  flo
//

#if DEBUG
  import Foundation

  // FLO_DEBUG_REPORT=1 logs every playback report with its parameters.
  extension ScrobbleAPI {
    func debugLogReport(_ params: [String: Any]) {
      guard ProcessInfo.processInfo.environment["FLO_DEBUG_REPORT"] == "1" else { return }
      debugLog("reportPlayback \(params.sorted { $0.key < $1.key })")
    }
  }
#endif
