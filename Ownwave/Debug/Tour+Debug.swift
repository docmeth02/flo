//
//  Tour+Debug.swift
//  Ownwave
//

#if DEBUG
  import SwiftUI

  // Simulator verification only. FLO_DEBUG_TOUR=play|rate|why|peek|taste|send
  // starts the tour at that step, seen or not, a few seconds after launch so a
  // FLO_DEBUG_PLAY_SOMETHING mix is queued by then.
  extension AppTabs {
    func debugTourStep() async -> TourStep? {
      guard let name = ProcessInfo.processInfo.environment["FLO_DEBUG_TOUR"],
        let step = TourStep.allCases.first(where: { "\($0)" == name })
      else { return nil }
      try? await Task.sleep(for: .seconds(4))
      debugLog("tour hook: \(name)")
      return step
    }
  }
#endif
