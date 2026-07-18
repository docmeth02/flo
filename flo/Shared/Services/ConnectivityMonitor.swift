//
//  ConnectivityMonitor.swift
//  flo
//

import Combine
import Network

final class ConnectivityMonitor: ObservableObject {
  static let shared = ConnectivityMonitor()

  @Published private(set) var isOnline: Bool = true

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "net.faultables.flo.connectivity")
  private var offlineDebounce: DispatchWorkItem?
  private var hasVerdict = false
  private var verdictWaiters: [(Bool) -> Void] = []

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let online = path.status == .satisfied
      DispatchQueue.main.async {
        guard let self = self else { return }

        self.offlineDebounce?.cancel()

        if online {
          // Going online: apply immediately
          self.isOnline = true
          self.deliverVerdict(true)
        } else {
          // Going offline: debounce to ignore transient .unsatisfied during
          // watchOS network-stack warm-up after deploy/launch
          let work = DispatchWorkItem { [weak self] in
            self?.isOnline = false
            self?.deliverVerdict(false)
          }
          self.offlineDebounce = work
          DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
      }
    }
    monitor.start(queue: queue)
  }

  /// Runs `handler` on the main thread once the first debounced connectivity
  /// verdict is in (immediately if it already is). Launch-time decisions must
  /// use this instead of reading `isOnline`, which starts optimistic and can
  /// still be flipping during network-stack warm-up.
  func onFirstVerdict(_ handler: @escaping (Bool) -> Void) {
    DispatchQueue.main.async {
      if self.hasVerdict {
        handler(self.isOnline)
      } else {
        self.verdictWaiters.append(handler)
      }
    }
  }

  private func deliverVerdict(_ online: Bool) {
    hasVerdict = true
    guard !verdictWaiters.isEmpty else { return }
    let waiters = verdictWaiters
    verdictWaiters = []
    for waiter in waiters { waiter(online) }
  }
}
