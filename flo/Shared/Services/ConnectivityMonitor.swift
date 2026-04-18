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

  private init() {
    // Default true (optimistic). pathUpdateHandler fires within milliseconds of start()
    // and will correct to false if actually offline. Reading currentPath before start()
    // returns .unsatisfied on watchOS, which false-seeds the state.

    monitor.pathUpdateHandler = { [weak self] path in
      let online = path.status == .satisfied
      DispatchQueue.main.async {
        guard let self = self, self.isOnline != online else { return }
        self.isOnline = online
      }
    }
    monitor.start(queue: queue)
  }
}
