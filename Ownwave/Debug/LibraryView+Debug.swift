//
//  LibraryView+Debug.swift
//  Ownwave
//

#if DEBUG
  import SwiftUI

  // Simulator verification only. FLO_DEBUG_LIBRARY=albums|artists|playlists|
  // radios|liked|downloads opens that chip, for screenshots.
  extension LibraryView {
    func applyDebugChip() {
      guard let raw = ProcessInfo.processInfo.environment["FLO_DEBUG_LIBRARY"],
        let debugChip = LibraryChip(rawValue: raw)
      else { return }
      chip = debugChip
      debugLog("library chip hook: \(raw)")
    }
  }
#endif
