//
//  PendingEdits.swift
//  flo
//

import Foundation

/// Edits made on the watch that the server has not confirmed yet, kept
/// across launches and sent while the server is reachable. Shared by the
/// ratings and the stars. `Value` must be a property list type, since the
/// edits are stored in UserDefaults.
@MainActor final class PendingEdits<Value: Equatable> {
  typealias Send = (
    _ id: String, _ value: Value, _ completion: @escaping (Result<Void, Error>) -> Void
  ) -> Void

  /// The latest unconfirmed edit per id.
  private(set) var values: [String: Value]

  /// Called once the server took an edit (`accepted`) or refused it for
  /// good; a newer edit for the same id may still be waiting. Not called
  /// for a failure that is retried later.
  var onSettle: (_ id: String, _ value: Value, _ accepted: Bool) -> Void = { _, _, _ in }

  private let name: String
  private let key: String
  private let defaults: UserDefaults
  private let canSend: () -> Bool
  private let send: Send
  private var inFlight = Set<String>()
  // Bumped on logout; answers for the previous account are dropped.
  private var account = 0

  /// `name` labels the debug log; `defaults` and `canSend` are for tests.
  init(
    name: String, key: String, defaults: UserDefaults = .standard,
    canSend: @escaping () -> Bool = PendingEdits.serverReachable, send: @escaping Send
  ) {
    self.name = name
    self.key = key
    self.defaults = defaults
    self.canSend = canSend
    self.send = send
    values = defaults.dictionary(forKey: key) as? [String: Value] ?? [:]
  }

  /// Sends only while logged in and the server answers.
  nonisolated static func serverReachable() -> Bool {
    AuthService.shared.accountKey != nil && ConnectivityMonitor.shared.canReachServer
  }

  subscript(id: String) -> Value? { values[id] }

  /// Nothing waiting and nothing under way.
  var isIdle: Bool { values.isEmpty && inFlight.isEmpty }

  /// Keeps the edit until the server takes it and sends it if it can.
  func set(_ value: Value, id: String) {
    values[id] = value
    save()
    flush()
  }

  /// Sends every unconfirmed edit while the server is reachable.
  func flush() {
    guard !values.isEmpty else { return }
    guard canSend() else {
      debugLog("\(name): \(values.count) pending while the server is unreachable")
      return
    }
    for (id, value) in values where !inFlight.contains(id) {
      inFlight.insert(id)
      let generation = account
      send(id, value) { result in
        Task { @MainActor [weak self] in
          self?.finish(value, id: id, result: result, account: generation)
        }
      }
    }
  }

  /// Drops every edit; they belong to the account that logged out.
  func forgetAccount() {
    account += 1
    values = [:]
    inFlight = []
    defaults.removeObject(forKey: key)
  }

  private func finish(_ value: Value, id: String, result: Result<Void, Error>, account generation: Int) {
    guard account == generation else { return }
    inFlight.remove(id)

    let accepted: Bool
    switch result {
    case .success:
      debugLog("\(name) confirmed: \(id)=\(value)")
      accepted = true
    case .failure(let error):
      // An item the server no longer knows cannot take the edit; anything
      // else waits for the next flush.
      guard FloooService.shared.isPermanentScrobbleFailure(error) else {
        debugLog("\(name) pending: \(id)=\(value) (\(error.localizedDescription))")
        // A newer edit made meanwhile goes now; this one waits for the next flush.
        if let newer = values[id], newer != value { flush() }
        return
      }
      debugLog("\(name) dropped: \(id)=\(value) (\(error.localizedDescription))")
      accepted = false
    }
    if values[id] == value { values[id] = nil }
    // The owner stores what the server took before the edit leaves the
    // disk, so a kill in between loses neither.
    onSettle(id, value, accepted)
    save()

    // Changed again while this one was under way.
    if values[id] != nil { flush() }
  }

  private func save() {
    defaults.set(values, forKey: key)
  }
}
