//
//  StarStore.swift
//  flo
//

import Foundation
import WatchKit

/// Liked songs, albums and artists as the watch knows them: a like made here
/// shows at once and waits, across launches and offline spells, until the
/// server takes it.
@MainActor final class StarStore: ObservableObject {
  static let shared = StarStore()

  /// Stars set on the watch, waiting or taken by the server this session, by
  /// id; any other item keeps the state it was listed with.
  @Published private(set) var stars: [String: Bool] = [:]

  // Stars the server took this session; lists loaded before still carry the
  // old state.
  private var confirmed: [String: Bool] = [:]
  /// Bumped by every edit made here; a server answer asked for before an
  /// edit is older than it.
  private(set) var editCount = 0
  private let edits: PendingEdits<Bool>

  /// `defaults`, `canSend` and `send` are for tests.
  init(
    defaults: UserDefaults = .standard,
    canSend: @escaping () -> Bool = PendingEdits<Bool>.serverReachable,
    send: @escaping PendingEdits<Bool>.Send = { id, starred, completion in
      // Navidrome takes songs, albums and artists alike as `id`.
      if starred {
        AlbumService.shared.star(id: id, completion: completion)
      } else {
        AlbumService.shared.unstar(id: id, completion: completion)
      }
    }
  ) {
    edits = PendingEdits(
      name: "star", key: UserDefaultsKeys.pendingStars, defaults: defaults, canSend: canSend,
      send: send)
    edits.onSettle = { [unowned self] id, starred, accepted in
      // Not when a newer edit for the item waits, as for ratings.
      if accepted, self.edits[id] == nil { self.confirmed[id] = starred }
      self.publish()
    }

    let center = NotificationCenter.default
    for name: Notification.Name in [.networkBecameOnline, WKApplication.didBecomeActiveNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.edits.flush() }
      }
    }
    center.addObserver(forName: .didLogout, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.forgetAccount() }
    }

    publish()
    edits.flush()
  }

  /// The watch's edit, else what the server took this session, else the
  /// state the item was listed with.
  func isStarred(_ id: String, listed: Bool) -> Bool {
    stars[id] ?? listed
  }

  /// A fresh answer from the server: newer than what it took earlier this
  /// session and than the state lists were loaded with. An edit still
  /// waiting stays on top.
  func adoptServerState(_ starred: Bool, id: String) {
    guard confirmed[id] != starred else { return }
    confirmed[id] = starred
    publish()
  }

  /// An edit made here that the server has not taken yet.
  func isPending(_ id: String) -> Bool {
    edits[id] != nil
  }

  func set(_ starred: Bool, id: String) {
    guard !id.isEmpty else { return }
    editCount += 1
    edits.set(starred, id: id)
    publish()
  }

  private func publish() {
    let merged = confirmed.merging(edits.values) { _, pending in pending }
    if merged != stars { stars = merged }
  }

  private func forgetAccount() {
    edits.forgetAccount()
    confirmed = [:]
    publish()
  }
}
