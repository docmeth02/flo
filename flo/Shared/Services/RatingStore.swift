//
//  RatingStore.swift
//  flo
//

import Foundation
import WatchKit

/// The account's song ratings by playback id: the server's, overlaid with
/// edits made here that it has not confirmed yet. An edit is shown at once
/// and kept until the server accepts it, across launches and offline spells.
@MainActor final class RatingStore: ObservableObject {
  static let shared = RatingStore()

  /// 1 to 5 per playback id; unrated songs are absent.
  @Published private(set) var ratings: [String: Int] = [:]

  private var server: [String: Int] = [:]
  private var serverFetched = false
  private let edits = PendingEdits<Int>(
    name: "rating", key: UserDefaultsKeys.pendingRatings, send: AlbumService.shared.setRating)
  // Edits the server took but no refresh has stored in the cache yet; a
  // successful refresh is newer than all of them, whatever it says.
  private var confirmed = UserDefaultsManager.confirmedRatings
  // Bumped when the server confirms an edit; a refresh asked for before that
  // may answer with the old rating and is dropped.
  private var confirmedEdits = 0
  // Bumped on logout; answers for the previous account are dropped.
  private var account = 0

  private init() {
    let center = NotificationCenter.default
    for name: Notification.Name in [.networkBecameOnline, WKApplication.didBecomeActiveNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { _ in
        Task { @MainActor in
          let store = RatingStore.shared
          store.edits.flush()
          // After a login the server set is unknown until the next song sync.
          if !store.serverFetched, AuthService.shared.accountKey != nil {
            await store.refreshFromServer()
          }
        }
      }
    }
    center.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in RatingStore.shared.forgetAccount() }
    }

    edits.onSettle = { [unowned self] id, rating, accepted in
      self.settle(rating, playbackID: id, accepted: accepted)
    }
    publish()
    loadCache()
    edits.flush()
  }

  func rating(for playbackID: String) -> Int {
    ratings[playbackID] ?? 0
  }

  /// Rates the song 1 to 5; 0 clears its rating.
  func set(_ rating: Int, for song: QueueEntity) {
    guard let id = song.id, !id.isEmpty else { return }
    set(rating, playbackID: id)
  }

  func set(_ rating: Int, playbackID id: String) {
    // A new edit supersedes what the server took before it.
    confirmed[id] = nil
    UserDefaultsManager.confirmedRatings = confirmed
    edits.set(min(max(rating, 0), 5), id: id)
    publish()
  }

  /// Replaces the server's ratings with its current list. A failed request
  /// keeps the ones known; edits not confirmed yet stay on top either way.
  func refreshFromServer() async {
    guard AuthService.shared.accountKey != nil else { return }
    let generation = account
    let confirmations = confirmedEdits
    let cacheGeneration = LibraryCacheManager.shared.generation

    guard
      let songs = try? await withCheckedThrowingContinuation({ continuation in
        AlbumService.shared.getRatedSongs { continuation.resume(with: $0) }
      })
    else {
      debugLog("ratings refresh failed")
      return
    }
    guard account == generation, confirmedEdits == confirmations else { return }

    server = Self.ratings(of: songs)
    serverFetched = true
    // The server's answer is newer than every edit it took before.
    confirmed = [:]
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.confirmedRatings)
    publish()
    debugLog("ratings refreshed: \(server.count) rated, \(edits.values.count) pending")
    await Task.detached(priority: .utility) {
      LibraryCacheManager.shared.save(songs, forKey: "ratedSongs", generation: cacheGeneration)
    }.value
  }

  // MARK: - Private

  private func publish() {
    var merged = server
    for (id, rating) in confirmed {
      merged[id] = rating > 0 ? rating : nil
    }
    for (id, rating) in edits.values {
      merged[id] = rating > 0 ? rating : nil
    }
    if merged != ratings { ratings = merged }
  }

  private func loadCache() {
    let generation = account
    Task.detached(priority: .utility) {
      let songs = LibraryCacheManager.shared.load([Song].self, forKey: "ratedSongs")
      await RatingStore.shared.adoptCached(Self.ratings(of: songs ?? []), account: generation)
      // No cache yet (first launch with ratings, or an upgrade): the song
      // sync that refreshes ratings may be a day away.
      if songs == nil { await RatingStore.shared.refreshFromServer() }
    }
  }

  private func adoptCached(_ cached: [String: Int], account generation: Int) {
    // A refresh that landed first is newer than the cache.
    guard account == generation, !serverFetched else { return }
    server = cached
    publish()
  }

  private func settle(_ rating: Int, playbackID id: String, accepted: Bool) {
    if accepted {
      confirmedEdits += 1
      server[id] = rating > 0 ? rating : nil
      // Kept on disk until a refresh stored it in the cache, so a relaunch
      // before then still knows it without sending it again. Not when a
      // newer edit for the song waits.
      if edits[id] == nil {
        confirmed[id] = rating
        UserDefaultsManager.confirmedRatings = confirmed
      }
    }
    publish()
    // Brings the cached list up to date for the next launch.
    if edits.isIdle { Task { await refreshFromServer() } }
  }

  private func forgetAccount() {
    account += 1
    server = [:]
    serverFetched = false
    edits.forgetAccount()
    confirmed = [:]
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.confirmedRatings)
    publish()
  }

  private nonisolated static func ratings(of songs: [Song]) -> [String: Int] {
    var result: [String: Int] = [:]
    for song in songs {
      if let rating = song.rating, rating > 0 { result[song.playbackID] = min(rating, 5) }
    }
    return result
  }
}
