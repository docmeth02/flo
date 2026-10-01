//
//  ConnectivityMonitor.swift
//  flo
//

import Combine
import Foundation
import WatchKit

/// watchOS only allows low-level networking (NWPathMonitor, NWConnection)
/// while audio is streaming; outside of that a path monitor stays unsatisfied
/// even with a working connection. Connectivity is therefore judged by plain
/// HTTP requests to the server, which every app may make.
final class ConnectivityMonitor: ObservableObject {
  static let shared = ConnectivityMonitor()

  @Published private(set) var isOnline: Bool = true
  @Published private(set) var isServerReachable: Bool = true

  private let session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: configuration)
  }()

  private var hasVerdict = false
  private var verdictWaiters: [(Bool) -> Void] = []
  private var lastVerdictAt: Date?
  private var probeWaiters: [() -> Void] = []
  private var serverProbe: URLSessionDataTask?
  // Identifies the latest probe; the answer of a cancelled one must not
  // overwrite its result.
  private var probeGeneration = 0
  private var retryWork: DispatchWorkItem?
  private var retryDelay: TimeInterval = 15

  private init() {
    NotificationCenter.default.addObserver(
      forName: WKApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.probeServerReachability()
    }
    DispatchQueue.main.async { self.probeServerReachability() }
  }

  /// Sends a HEAD request to the configured server. Any HTTP answer means the
  /// server is reachable; a missing network connection means offline. While
  /// the server stays unreachable the probe repeats with a growing delay.
  /// Main thread only.
  func probeServerReachability() {
    serverProbe?.cancel()
    retryWork?.cancel()
    probeGeneration += 1
    let generation = probeGeneration

    guard
      let url = URL(string: UserDefaultsManager.serverBaseURL),
      let host = url.host, !host.isEmpty
    else {
      deliverVerdict(isOnline)
      deliverProbeResult()
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = "HEAD"

    let task = session.dataTask(with: request) { [weak self] _, response, error in
      DispatchQueue.main.async {
        guard let self = self, self.probeGeneration == generation else { return }
        self.apply(response: response, error: error)
      }
    }
    serverProbe = task
    task.resume()
  }

  /// Lets regular API traffic correct the state between probes. `error` is
  /// the URL loading error; a request that failed without one (cancelled or
  /// never sent) says nothing about the connection. Callable from any thread.
  func record(response: HTTPURLResponse?, error: Error?) {
    guard response != nil || (error is URLError && (error as? URLError)?.code != .cancelled)
    else { return }
    DispatchQueue.main.async {
      let reachable = response != nil
      let online = reachable || !Self.isOfflineError(error)
      // A probe still in flight would overwrite this newer evidence when it
      // fails late, so it is replaced even when nothing changes.
      let probeInFlight = self.serverProbe?.state == .running
      guard
        reachable != self.isServerReachable || online != self.isOnline || !self.hasVerdict
          || probeInFlight
      else {
        self.lastVerdictAt = Date()
        return
      }
      self.serverProbe?.cancel()
      self.probeGeneration += 1
      self.apply(response: response, error: error)
    }
  }

  private func apply(response: URLResponse?, error: Error?) {
    if response == nil, (error as? URLError)?.code == .cancelled { return }

    let reachable = response is HTTPURLResponse
    let online = reachable || !Self.isOfflineError(error)
    let cameOnline = online && !isOnline

    debugLog("connectivity online=\(online) reachable=\(reachable)")
    if isOnline != online { isOnline = online }
    // Assigned on every probe: the scrobble outbox delivers on each success.
    isServerReachable = reachable
    lastVerdictAt = Date()
    deliverVerdict(online)
    deliverProbeResult()

    if cameOnline {
      NotificationCenter.default.post(name: .networkBecameOnline, object: nil)
    }

    if reachable {
      retryDelay = 15
    } else {
      let work = DispatchWorkItem { [weak self] in self?.probeServerReachability() }
      retryWork = work
      DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay, execute: work)
      retryDelay = min(retryDelay * 2, 300)
    }
  }

  private static func isOfflineError(_ error: Error?) -> Bool {
    switch (error as? URLError)?.code {
    case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive:
      return true
    default:
      return false
    }
  }

  /// Runs `handler` on the main thread once the first probe has answered
  /// (immediately if it already has). Launch-time decisions must use this
  /// instead of reading `isOnline`, which starts optimistic.
  func onFirstVerdict(_ handler: @escaping (Bool) -> Void) {
    DispatchQueue.main.async {
      if self.hasVerdict {
        handler(self.isOnline)
      } else {
        self.verdictWaiters.append(handler)
      }
    }
  }

  /// Whether songs can be streamed now. A verdict older than `maxAge` is
  /// renewed with a probe first: without a path monitor nothing else notices
  /// a connection that dropped after the last request.
  func canStream(maxAge: TimeInterval = 60) async -> Bool {
    await withCheckedContinuation { continuation in
      DispatchQueue.main.async {
        if let lastVerdictAt = self.lastVerdictAt,
          Date().timeIntervalSince(lastVerdictAt) < maxAge
        {
          continuation.resume(returning: self.isOnline && self.isServerReachable)
          return
        }
        self.probeWaiters.append {
          continuation.resume(returning: self.isOnline && self.isServerReachable)
        }
        self.probeServerReachability()
      }
    }
  }

  private func deliverProbeResult() {
    let waiters = probeWaiters
    probeWaiters = []
    for waiter in waiters { waiter() }
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
