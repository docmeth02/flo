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
  private var pending = UserDefaultsManager.pendingRatings
  private var inFlight = Set<String>()
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
          store.flush()
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

    publish()
    loadCache()
    flush()
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
    pending[id] = min(max(rating, 0), 5)
    UserDefaultsManager.pendingRatings = pending
    // A new edit supersedes what the server took before it.
    confirmed[id] = nil
    UserDefaultsManager.confirmedRatings = confirmed
    publish()
    flush()
  }

  /// Replaces the server's ratings with its current list. A failed request
  /// keeps the ones known; edits not confirmed yet stay on top either way.
  func refreshFromServer() async {
    guard AuthService.shared.accountKey != nil else { return }
    let generation = account
    let edits = confirmedEdits
    let cacheGeneration = LibraryCacheManager.shared.generation

    guard
      let songs = try? await withCheckedThrowingContinuation({ continuation in
        AlbumService.shared.getRatedSongs { continuation.resume(with: $0) }
      })
    else {
      debugLog("ratings refresh failed")
      return
    }
    guard account == generation, confirmedEdits == edits else { return }

    server = Self.ratings(of: songs)
    serverFetched = true
    // The server's answer is newer than every edit it took before.
    confirmed = [:]
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.confirmedRatings)
    publish()
    debugLog("ratings refreshed: \(server.count) rated, \(pending.count) pending")
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
    for (id, rating) in pending {
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

  /// Sends every unconfirmed edit while the server is reachable.
  private func flush() {
    let connectivity = ConnectivityMonitor.shared
    guard AuthService.shared.accountKey != nil, !pending.isEmpty else { return }
    guard connectivity.isOnline, connectivity.isServerReachable else {
      debugLog("ratings: \(pending.count) pending while offline")
      return
    }
    for (id, rating) in pending where !inFlight.contains(id) {
      send(rating, playbackID: id)
    }
  }

  private func send(_ rating: Int, playbackID id: String) {
    inFlight.insert(id)
    let generation = account
    AlbumService.shared.setRating(id: id, rating: rating) { result in
      Task { @MainActor in
        RatingStore.shared.finish(rating, playbackID: id, result: result, account: generation)
      }
    }
  }

  private func finish(
    _ rating: Int, playbackID id: String, result: Result<Void, Error>, account generation: Int
  ) {
    guard account == generation else { return }
    inFlight.remove(id)

    switch result {
    case .success:
      debugLog("rating confirmed: \(id)=\(rating)")
      confirmedEdits += 1
      server[id] = rating > 0 ? rating : nil
      // Kept on disk until a refresh stored it in the cache, so a relaunch
      // before then still knows it without sending it again.
      if pending[id] == rating {
        pending[id] = nil
        confirmed[id] = rating
        UserDefaultsManager.confirmedRatings = confirmed
      }
    case .failure(let error):
      // A song the server no longer knows cannot be rated; anything else
      // waits for the next flush.
      guard FloooService.shared.isPermanentScrobbleFailure(error) else {
        debugLog("rating pending: \(id)=\(rating) (\(error.localizedDescription))")
        return
      }
      debugLog("rating dropped: \(id)=\(rating) (\(error.localizedDescription))")
      if pending[id] == rating { pending[id] = nil }
    }
    UserDefaultsManager.pendingRatings = pending
    publish()

    if pending[id] != nil {
      // Changed again while this one was under way.
      flush()
    } else if inFlight.isEmpty, pending.isEmpty {
      // Brings the cached list up to date for the next launch.
      Task { await refreshFromServer() }
    }
  }

  private func forgetAccount() {
    account += 1
    server = [:]
    serverFetched = false
    pending = [:]
    inFlight = []
    confirmed = [:]
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.pendingRatings)
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
