//
//  TasteView+Debug.swift
//  Ownwave
//

#if DEBUG
  import SwiftUI

  // Simulator verification only. FLO_DEBUG_TASTE=profile|top|boosted|avoided|
  // skips opens that segment, for screenshots.
  extension TasteView {
    func applyDebugSegment() {
      guard let raw = ProcessInfo.processInfo.environment["FLO_DEBUG_TASTE"],
        let debugSegment = TasteSegment(rawValue: raw)
      else { return }
      segment = debugSegment
      debugLog("taste segment hook: \(raw)")
    }
  }
#endif
