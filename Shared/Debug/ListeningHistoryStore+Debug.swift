//
//  ListeningHistoryStore+Debug.swift
//  Ownwave
//

#if DEBUG
  import CoreData

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

    /// Plays the server stamped in the future; they count as played now.
    func debugFuturePlays() async -> Int {
      guard let key = AuthService.shared.accountKey else { return 0 }
      let now = Date()
      return await CoreDataManager.shared.performBackground { context in
        let future = NSFetchRequest<PlayEntity>(entityName: "PlayEntity")
        future.predicate = NSPredicate(
          format: "accountKey == %@ AND submissionTime > %@", key, now as NSDate)
        return (try? context.count(for: future)) ?? 0
      }
    }
  }
#endif
