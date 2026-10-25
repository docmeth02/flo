//
//  WatchHomeView+Debug.swift
//  Ownwave Watch App
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

  /// FLO_DEBUG_HOME_SCROLL=<anchor> (a `WatchHomeView.Anchor`) scrolls that
  /// row to the bottom of the screen five seconds after Home appears.
  struct DebugHomeScroll: ViewModifier {
    func body(content: Content) -> some View {
      ScrollViewReader { proxy in
        content.task {
          guard
            let anchor = ProcessInfo.processInfo.environment["FLO_DEBUG_HOME_SCROLL"]
              .flatMap(WatchHomeView.Anchor.init)
          else { return }
          try? await Task.sleep(for: .seconds(5))
          proxy.scrollTo(anchor, anchor: .bottom)
          debugLog("home scroll hook: \(anchor)")
        }
      }
    }
  }
#endif
