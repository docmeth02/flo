//
//  ConnectivityMonitor.swift
//  flo
//

import Combine
import Foundation
import Network

final class ConnectivityMonitor: ObservableObject {
  static let shared = ConnectivityMonitor()

  @Published private(set) var isOnline: Bool = true
  @Published private(set) var isServerReachable: Bool = true

  private let monitor = NWPathMonitor()
  private let queue = DispatchQueue(label: "net.faultables.flo.connectivity")
  private var offlineDebounce: DispatchWorkItem?
  private var hasVerdict = false
  private var verdictWaiters: [(Bool) -> Void] = []
  private var serverProbe: NWConnection?

  private init() {
    monitor.pathUpdateHandler = { [weak self] path in
      let online = path.status == .satisfied
      DispatchQueue.main.async {
        guard let self = self else { return }

        if online {
          // Going online: apply immediately
          self.offlineDebounce?.cancel()
          self.offlineDebounce = nil
          let wasOnline = self.isOnline
          self.isOnline = true
          self.deliverVerdict(true)
          if !wasOnline {
            self.probeServerReachability()
            NotificationCenter.default.post(name: .networkBecameOnline, object: nil)
          }
        } else {
          // Going offline: debounce to ignore transient .unsatisfied during
          // watchOS network-stack warm-up after deploy/launch. A pending
          // debounce is left running — repeated .unsatisfied updates must not
          // keep pushing the verdict out indefinitely.
          guard self.offlineDebounce == nil else { return }
          let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.offlineDebounce = nil
            self.isOnline = false
            self.deliverVerdict(false)
          }
          self.offlineDebounce = work
          DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
        }
      }
    }
    monitor.start(queue: queue)
    DispatchQueue.main.async { self.probeServerReachability() }
  }

  /// TCP-connects to the configured server to tell "online but server down"
  /// apart from a working connection. Main thread only.
  func probeServerReachability() {
    serverProbe?.cancel()

    guard isOnline else {
      isServerReachable = false
      return
    }

    guard
      let url = URL(string: UserDefaultsManager.serverBaseURL),
      let host = url.host, !host.isEmpty
    else {
      return
    }

    let scheme = url.scheme?.lowercased() ?? ""
    let port =
      NWEndpoint.Port(rawValue: UInt16(url.port ?? (scheme == "https" ? 443 : 80))) ?? .https

    let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    serverProbe = connection

    var didResolve = false

    connection.stateUpdateHandler = { [weak self] state in
      DispatchQueue.main.async {
        guard let self = self else { return }

        switch state {
        case .ready:
          didResolve = true
          self.isServerReachable = true
          connection.cancel()
        case .failed:
          self.isServerReachable = false
        default:
          break
        }
      }
    }

    connection.start(queue: queue)

    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
      guard let self = self, !didResolve else { return }
      self.isServerReachable = false
      connection.cancel()
    }
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

  /// Async variant of `onFirstVerdict`. After the first verdict this returns
  /// the current state immediately.
  func firstVerdict() async -> Bool {
    await withCheckedContinuation { continuation in
      onFirstVerdict { continuation.resume(returning: $0) }
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

extension Notification.Name {
  static let networkBecameOnline = Notification.Name("net.faultables.flo.networkBecameOnline")
}
