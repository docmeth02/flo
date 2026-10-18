//
//  NowPlayingView+Debug.swift
//  Ownwave
//

#if DEBUG
  import SwiftUI

  // Simulator verification only. FLO_DEBUG_UPNEXT=1 turns Now Playing to its
  // Up Next page shortly after it opens, for screenshots.
  extension NowPlayingView {
    func runDebugUpNext(_ show: () -> Void) async {
      guard ProcessInfo.processInfo.environment["FLO_DEBUG_UPNEXT"] == "1" else { return }
      try? await Task.sleep(for: .seconds(2))
      show()
      debugLog("up next hook")
    }
  }
#endif
