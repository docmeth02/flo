//
//  StarStore.swift
//  flo
//

import Foundation

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
  // Ids known to be songs: a full list of starred songs speaks for these
  // and for no album or artist. The songs of edits still waiting are kept
  // across launches with them.
  private var songIds = Set<String>()
  private var pendingSongs: Set<String>
  /// Bumped by every edit made here; a server answer asked for before an
  /// edit is older than it.
  private(set) var editCount = 0
  /// Bumped by every edit and by every one the server took: a full list
  /// asked for before either may lack it.
  private(set) var listRevision = 0
  private let edits: PendingEdits<Bool>
  private let defaults: UserDefaults

  /// `defaults`, `canSend` and `send` are for tests.
  init(
    defaults: UserDefaults = .standard,
    canSend: @escaping () -> Bool = PendingEdits<Bool>.serverReachable,
    send: @escaping PendingEdits<Bool>.Send = { id, starred in
      // Navidrome takes songs, albums and artists alike as `id`.
      if starred {
        try await LibraryAPI.star(id: id)
      } else {
        try await LibraryAPI.unstar(id: id)
      }
    }
  ) {
    self.defaults = defaults
    let edits = PendingEdits<Bool>(
      name: "star", key: UserDefaultsKeys.pendingStars, defaults: defaults, canSend: canSend,
      send: send)
    self.edits = edits
    // Saved apart from the edits, so one can outlive the other in a kill.
    let stored = Set(defaults.stringArray(forKey: UserDefaultsKeys.pendingStarSongs) ?? [])
    pendingSongs = stored.filter { edits[$0] != nil }
    songIds = pendingSongs
    if pendingSongs.count != stored.count { savePendingSongs() }
    edits.onSettle = { [unowned self] id, starred, accepted in
      // Not when a newer edit for the item waits, as for ratings.
      if accepted, self.edits[id] == nil { self.confirmed[id] = starred }
      if accepted { self.listRevision += 1 }
      if self.edits[id] == nil, self.pendingSongs.remove(id) != nil { self.savePendingSongs() }
      self.publish()
    }

    let center = NotificationCenter.default
    for name: Notification.Name in [.networkBecameOnline, AppPlatform.didBecomeActive] {
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

  /// `isStarred` over a whole list: the starred ids among `listed` and the
  /// items this store knows of.
  func starred(listed: Set<String>) -> Set<String> {
    stars.reduce(into: listed) { result, star in
      if star.value { result.insert(star.key) } else { result.remove(star.key) }
    }
  }

  /// A fresh answer from the server: newer than what it took earlier this
  /// session and than the state lists were loaded with. An edit still
  /// waiting stays on top.
  /// Only songs are looked up one by one.
  func adoptServerState(_ starred: Bool, id: String) {
    songIds.insert(id)
    guard confirmed[id] != starred else { return }
    confirmed[id] = starred
    publish()
  }

  /// The server's full list of starred songs, asked for when `listRevision`
  /// was `since`: newer than earlier lookups, and any song known here that
  /// it lacks was unstarred. Ignored when an edit was made or taken
  /// meanwhile; edits still waiting stay on top.
  func adoptServerStars(_ ids: [String], since: Int) {
    guard since == listRevision else { return }
    let starred = Set(ids)
    songIds.formUnion(starred)
    for id in songIds.subtracting(starred) { confirmed[id] = false }
    for id in starred { confirmed[id] = true }
    publish()
  }

  /// The server's full list of albums or artists with their stars, asked
  /// for when `listRevision` was `since`: newer than what it took earlier
  /// this session, so an item unstarred elsewhere since shows unstarred.
  /// Ignored when an edit was made or taken meanwhile; edits still waiting
  /// stay on top.
  func adoptServerList(_ items: [(id: String, starred: Bool)], since: Int) {
    guard since == listRevision else { return }
    for item in items where confirmed[item.id] != nil { confirmed[item.id] = item.starred }
    publish()
  }

  /// An edit made here that the server has not taken yet.
  func isPending(_ id: String) -> Bool {
    edits[id] != nil
  }

  /// `set` for a song, which a later full list of starred songs covers.
  func setSong(_ starred: Bool, id: String) {
    guard !id.isEmpty else { return }
    songIds.insert(id)
    if pendingSongs.insert(id).inserted { savePendingSongs() }
    set(starred, id: id)
  }

  func set(_ starred: Bool, id: String) {
    guard !id.isEmpty else { return }
    editCount += 1
    listRevision += 1
    edits.set(starred, id: id)
    publish()
  }

  private func publish() {
    let merged = confirmed.merging(edits.values) { _, pending in pending }
    if merged != stars { stars = merged }
  }

  private func savePendingSongs() {
    defaults.set(Array(pendingSongs), forKey: UserDefaultsKeys.pendingStarSongs)
  }

  private func forgetAccount() {
    // A list asked for by the previous account is not this one's.
    listRevision += 1
    edits.forgetAccount()
    confirmed = [:]
    songIds = []
    pendingSongs = []
    defaults.removeObject(forKey: UserDefaultsKeys.pendingStarSongs)
    publish()
  }
}
