//
//  WatchHomeView+Debug.swift
//  flo Watch App
//

#if DEBUG
  import SwiftUI

  // Simulator verification only. FLO_DEBUG_FETCH_ALBUMS=1 loads the album list
  // two seconds after launch, =now right away (racing the launch re-login), and
  // logs what the request log recorded.
  extension WatchHomeView {
    func runDebugFetchAlbums() async {
      let mode = ProcessInfo.processInfo.environment["FLO_DEBUG_FETCH_ALBUMS"]
      guard mode == "1" || mode == "now" else { return }
      if mode == "1" { try? await Task.sleep(nanoseconds: 2_000_000_000) }
      albumViewModel.fetchAlbums()
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      let entries = RequestLog.shared.entries
      debugLog("request log: \(entries.count) entries")
      for entry in entries.reversed() {
        debugLog(
          "  \(entry.text) status=\(entry.status.map(String.init) ?? "-") retries=\(entry.retries) error=\(entry.error ?? "-")"
        )
      }
    }
  }
#endif
