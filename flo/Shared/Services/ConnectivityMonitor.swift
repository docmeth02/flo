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

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let online = path.status == .satisfied
      DispatchQueue.main.async {
        guard let self = self else { return }

        self.offlineDebounce?.cancel()

        if online {
          // Going online: apply immediately
          self.isOnline = true
        } else {
          // Going offline: debounce to ignore transient .unsatisfied during
          // watchOS network-stack warm-up after deploy/launch
          let work = DispatchWorkItem { [weak self] in
            self?.isOnline = false
          }
          self.offlineDebounce = work
          DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
      }
    }
    monitor.start(queue: queue)
  }
}
