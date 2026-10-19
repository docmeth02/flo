//
//  ListeningHistoryStore+Debug.swift
//  flo
//

#if DEBUG
  import Foundation

  // FLO_DEBUG_HISTORY_PAGE_DELAY=<s> waits that long after each imported page,
  // which leaves time to interrupt a bootstrap.
  extension ListeningHistoryStore {
    func debugPageDelay() async {
      guard
        let delay = ProcessInfo.processInfo.environment["FLO_DEBUG_HISTORY_PAGE_DELAY"]
          .flatMap(Double.init)
      else { return }
      try? await Task.sleep(for: .seconds(delay))
    }
  }
#endif
