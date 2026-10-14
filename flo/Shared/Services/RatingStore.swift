//
//  RatingStore.swift
//  flo
//

import Foundation
import WatchKit

/// The account's song ratings by playback id: the server's, overlaid with
/// edits made here that it has not confirmed yet. An edit is shown at once
/// and kept until the server accepts it, across launches and offline spells.
/// Album ratings come from the server only and stand in for songs rated
/// nowhere.
@MainActor final class RatingStore: ObservableObject {
  static let shared: RatingStore = {
    let store = RatingStore()
    store.loadCache()
    return store
  }()

  /// 1 to 5 per playback id; unrated songs are absent.
  @Published private(set) var ratings: [String: Int] = [:]
  /// 1 to 5 per album id; unrated albums are absent.
  private(set) var albumRatings: [String: Int] = [:]

  private var server: [String: Int] = [:]
  // When the server last answered for songs and albums; nil after a login
  // until it does.
  private var refreshedAt: Date?
  private var refreshing: (id: UUID, task: Task<Void, Never>)?
  private let edits: PendingEdits<Int>
  private let defaults: UserDefaults
  // Edits the server took but no refresh has stored in the cache yet; a
  // successful refresh is newer than all of them, whatever it says.
  private var confirmed: [String: Int]
  // Bumped when the server confirms an edit; a refresh asked for before that
  // may answer with the old rating and is dropped.
  private var confirmedEdits = 0
  // Bumped on logout; answers for the previous account are dropped.
  private var account = 0

  // Ratings changed in another client show up within this on activation.
  private static let maxAge: TimeInterval = 5 * 60

  /// `defaults`, `canSend` and `send` are for tests.
  init(
    defaults: UserDefaults = .standard,
    canSend: @escaping () -> Bool = PendingEdits<Int>.serverReachable,
    send: @escaping PendingEdits<Int>.Send = AlbumService.shared.setRating
  ) {
    self.defaults = defaults
    confirmed = defaults.dictionary(forKey: UserDefaultsKeys.confirmedRatings) as? [String: Int] ?? [:]
    edits = PendingEdits(
      name: "rating", key: UserDefaultsKeys.pendingRatings, defaults: defaults, canSend: canSend,
      send: send)
    edits.onSettle = { [unowned self] id, rating, accepted in
      self.settle(rating, playbackID: id, accepted: accepted)
    }

    let center = NotificationCenter.default
    for name: Notification.Name in [.networkBecameOnline, WKApplication.didBecomeActiveNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.edits.flush()
          if ConnectivityMonitor.shared.canReachServer { self.refreshIfStale() }
        }
      }
    }
    center.addObserver(forName: .didLogout, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.forgetAccount() }
    }

    publish()
    edits.flush()
  }

  func rating(for playbackID: String) -> Int {
    ratings[playbackID] ?? 0
  }

  /// A song's rating for recommendations: its own (pending or confirmed) 1...5,
  /// else its album's 1...5, else 0. Main thread.
  func effectiveRating(songId: String, albumId: String?) -> Int {
    ratings[songId] ?? albumId.flatMap { albumRatings[$0] } ?? 0
  }

  /// An artist's own rating 1...5, else 0. Main thread.
  func artistRating(_ artistId: String) -> Int {
    0  // interface stub, implemented on the ratings branch
  }

  /// Rates the artist 1 to 5; 0 clears its rating.
  func setArtist(_ rating: Int, artistId: String) {
    // interface stub, implemented on the ratings branch
  }

  /// Whether a rating edit for this song or artist waits for the server.
  func isPending(_ id: String) -> Bool {
    edits[id] != nil
  }

  /// Rates the song 1 to 5; 0 clears its rating.
  func set(_ rating: Int, for song: QueueEntity) {
    guard let id = song.id, !id.isEmpty else { return }
    set(rating, playbackID: id)
  }

  func set(_ rating: Int, playbackID id: String) {
    // Stored first, so a kill in between cannot lose the edit.
    edits.set(min(max(rating, 0), 5), id: id)
    // A new edit supersedes what the server took before it.
    confirmed[id] = nil
    defaults.set(confirmed, forKey: UserDefaultsKeys.confirmedRatings)
    publish()
  }

  /// Replaces the server's song and album ratings with its current lists. A
  /// failed request keeps the ones known; edits not confirmed yet stay on
  /// top either way.
  func refreshFromServer() async {
    await startRefresh().value
  }

  /// Refreshes ratings older than five minutes, waiting for at most `limit`;
  /// past it the caller goes on with the ones known.
  func refreshIfStale(waitingAtMost limit: Duration) async {
    guard let refresh = refreshIfStale() else { return }
    // A task group would wait for the refresh too; the stream ends the wait
    // at whichever finishes first.
    let (done, finish) = AsyncStream<Void>.makeStream()
    Task { await refresh.value; finish.yield() }
    Task {
      try? await Task.sleep(for: limit)
      finish.yield()
    }
    for await _ in done { break }
  }

  /// The server's ratings, newer than the cache and than every edit it took
  /// before. Main thread.
  func adoptServer(songs: [Song], albums: [Album]) {
    server = Self.ratings(of: songs)
    albumRatings = Self.ratings(of: albums)
    refreshedAt = Date()
    confirmed = [:]
    defaults.removeObject(forKey: UserDefaultsKeys.confirmedRatings)
    publish()
  }

  /// Starts a refresh when the ratings are stale, or joins the one under
  /// way; nil while they are fresh.
  @discardableResult func refreshIfStale() -> Task<Void, Never>? {
    if let refreshing { return refreshing.task }
    guard refreshedAt.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true else {
      return nil
    }
    return startRefresh()
  }

  // MARK: - Private

  private func startRefresh() -> Task<Void, Never> {
    let id = UUID()
    let task = Task {
      await fetchFromServer()
      if refreshing?.id == id { refreshing = nil }
    }
    refreshing = (id, task)
    return task
  }

  private func fetchFromServer() async {
    guard AuthService.shared.accountKey != nil else { return }
    let generation = account
    let confirmations = confirmedEdits
    let cacheGeneration = LibraryCacheManager.shared.generation

    async let ratedSongs = Self.fetch(AlbumService.shared.getRatedSongs)
    async let ratedAlbums = Self.fetch(AlbumService.shared.getRatedAlbums)
    guard let songs = try? await ratedSongs, let albums = try? await ratedAlbums else {
      debugLog("ratings refresh failed")
      return
    }
    guard account == generation, confirmedEdits == confirmations else { return }

    adoptServer(songs: songs, albums: albums)
    debugLog(
      "ratings refreshed: \(server.count) songs, \(albumRatings.count) albums, "
        + "\(edits.values.count) pending")
    await Task.detached(priority: .utility) {
      LibraryCacheManager.shared.save(songs, forKey: .ratedSongs, generation: cacheGeneration)
      LibraryCacheManager.shared.save(albums, forKey: .ratedAlbums, generation: cacheGeneration)
    }.value
  }

  private nonisolated static func fetch<T>(
    _ request: (@escaping (Result<T, Error>) -> Void) -> Void
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      request { continuation.resume(with: $0) }
    }
  }

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
      let songs = LibraryCacheManager.shared.load([Song].self, forKey: .ratedSongs)
      let albums = LibraryCacheManager.shared.load([Album].self, forKey: .ratedAlbums)
      await self.adoptCached(
        songs: Self.ratings(of: songs ?? []), albums: Self.ratings(of: albums ?? []),
        account: generation)
      // No cache yet (first launch with ratings, or an upgrade): the next
      // activation may be far away.
      if songs == nil || albums == nil { await self.refreshFromServer() }
    }
  }

  private func adoptCached(songs: [String: Int], albums: [String: Int], account generation: Int) {
    // A refresh that landed first is newer than the cache.
    guard account == generation, refreshedAt == nil else { return }
    server = songs
    albumRatings = albums
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
        defaults.set(confirmed, forKey: UserDefaultsKeys.confirmedRatings)
      }
    }
    publish()
    // Brings the cached list up to date for the next launch.
    if edits.isIdle { Task { await refreshFromServer() } }
  }

  private func forgetAccount() {
    account += 1
    server = [:]
    albumRatings = [:]
    refreshedAt = nil
    refreshing = nil
    edits.forgetAccount()
    confirmed = [:]
    defaults.removeObject(forKey: UserDefaultsKeys.confirmedRatings)
    publish()
  }

  /// 1 to 5 by id, without the unrated.
  private nonisolated static func ratings<Item>(
    of items: [Item], id: (Item) -> String, rating: (Item) -> Int?
  ) -> [String: Int] {
    var result: [String: Int] = [:]
    for item in items {
      if let rating = rating(item), rating > 0 { result[id(item)] = min(rating, 5) }
    }
    return result
  }

  private nonisolated static func ratings(of songs: [Song]) -> [String: Int] {
    ratings(of: songs, id: \.playbackID, rating: \.rating)
  }

  private nonisolated static func ratings(of albums: [Album]) -> [String: Int] {
    ratings(of: albums, id: \.id, rating: \.rating)
  }
}
