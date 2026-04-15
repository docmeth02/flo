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
    // Seed synchronously so AuthViewModel.init sees an accurate value on launch
    isOnline = monitor.currentPath.status == .satisfied

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
