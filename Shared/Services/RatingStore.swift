//
//  RatingStore.swift
//  flo
//

import Foundation

/// The account's song ratings by playback id: the server's, overlaid with
/// edits made here that it has not confirmed yet. An edit is shown at once
/// and kept until the server accepts it, across launches and offline spells.
/// Album ratings come from the server only and stand in for songs rated
/// nowhere. Artist ratings are kept apart from the songs', so an artist id
/// never reads as a song's rating.
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
  /// 1 to 5 per artist id, the server's overlaid with edits; unrated
  /// artists are absent.
  private(set) var artistRatings: [String: Int] = [:]

  private var server: [String: Int] = [:]
  private var artistServer: [String: Int] = [:]
  // When the server last answered for all three lists; nil after a login
  // until it does.
  private var refreshedAt: Date?
  private var refreshing: (id: UUID, task: Task<Void, Never>)?
  private let edits: PendingEdits<Int>
  private let artistEdits: PendingEdits<Int>
  private let defaults: UserDefaults
  // Edits the server took but no refresh has stored in the cache yet; a
  // successful refresh is newer than all of them, whatever it says.
  private var confirmed: [String: Int]
  private var artistConfirmed: [String: Int]
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
    confirmed =
      defaults.dictionary(forKey: UserDefaultsKeys.confirmedRatings) as? [String: Int] ?? [:]
    artistConfirmed =
      defaults.dictionary(forKey: UserDefaultsKeys.confirmedArtistRatings) as? [String: Int] ?? [:]
    edits = PendingEdits(
      name: "rating", key: UserDefaultsKeys.pendingRatings, defaults: defaults, canSend: canSend,
      send: send)
    // Navidrome rates artists through the same call as songs.
    artistEdits = PendingEdits(
      name: "artist rating", key: UserDefaultsKeys.pendingArtistRatings, defaults: defaults,
      canSend: canSend, send: send)
    edits.onSettle = { [unowned self] id, rating, accepted in
      self.settle(rating, id: id, accepted: accepted, artist: false)
    }
    artistEdits.onSettle = { [unowned self] id, rating, accepted in
      self.settle(rating, id: id, accepted: accepted, artist: true)
    }

    let center = NotificationCenter.default
    for name: Notification.Name in [.networkBecameOnline, AppPlatform.didBecomeActive] {
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in
          guard let self else { return }
          self.edits.flush()
          self.artistEdits.flush()
          if ConnectivityMonitor.shared.canReachServer { self.refreshIfStale() }
        }
      }
    }
    center.addObserver(forName: .didLogout, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in self?.forgetAccount() }
    }

    publish()
    edits.flush()
    artistEdits.flush()
  }

  func rating(for playbackID: String) -> Int {
    ratings[playbackID] ?? 0
  }

  /// An artist's own rating 1...5, else 0. Main thread.
  func artistRating(_ artistId: String) -> Int {
    artistRatings[artistId] ?? 0
  }

  /// Rates the artist 1 to 5; 0 clears its rating.
  func setArtist(_ rating: Int, artistId id: String) {
    guard !id.isEmpty else { return }
    artistEdits.set(min(max(rating, 0), 5), id: id)
    artistConfirmed[id] = nil
    defaults.set(artistConfirmed, forKey: UserDefaultsKeys.confirmedArtistRatings)
    publish()
  }

  /// Whether a rating edit for this song or artist waits for the server.
  func isPending(_ id: String) -> Bool {
    edits[id] != nil || artistEdits[id] != nil
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

  /// Replaces the server's song, album and artist ratings with its current
  /// lists. A failed request keeps the ones known; edits not confirmed yet
  /// stay on top either way.
  func refreshFromServer() async {
    await startRefresh().value
  }

  /// Refreshes ratings older than five minutes, waiting for at most `limit`;
  /// past it the caller goes on with the ones known.
  func refreshIfStale(waitingAtMost limit: Duration) async {
    guard let refresh = refreshIfStale() else { return }
    _ = await withTimeout(limit) { await refresh.value }
  }

  /// The server's ratings, newer than the cache and than every edit it took
  /// before. Main thread.
  func adoptServer(songs: [Song], albums: [Album], artists: [Artist]) {
    server = Self.ratings(of: songs)
    albumRatings = Self.ratings(of: albums)
    artistServer = Self.ratings(of: artists)
    refreshedAt = Date()
    confirmed = [:]
    artistConfirmed = [:]
    defaults.removeObject(forKey: UserDefaultsKeys.confirmedRatings)
    defaults.removeObject(forKey: UserDefaultsKeys.confirmedArtistRatings)
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

    async let ratedSongs = AlbumService.shared.getRatedSongs()
    async let ratedAlbums = AlbumService.shared.getRatedAlbums()
    async let ratedArtists = AlbumService.shared.getRatedArtists()
    guard let songs = try? await ratedSongs, let albums = try? await ratedAlbums,
      let artists = try? await ratedArtists
    else {
      debugLog("ratings refresh failed")
      return
    }
    guard account == generation, confirmedEdits == confirmations else { return }

    adoptServer(songs: songs, albums: albums, artists: artists)
    debugLog(
      "ratings refreshed: \(server.count) songs, \(albumRatings.count) albums, "
        + "\(artistServer.count) artists, \(edits.values.count + artistEdits.values.count) pending")
    await Task.detached(priority: .utility) {
      LibraryCacheManager.shared.save(songs, forKey: .ratedSongs, generation: cacheGeneration)
      LibraryCacheManager.shared.save(albums, forKey: .ratedAlbums, generation: cacheGeneration)
      LibraryCacheManager.shared.save(artists, forKey: .ratedArtists, generation: cacheGeneration)
    }.value
  }

  private func publish() {
    let merged = Self.merge(server, confirmed, edits.values)
    if merged != ratings { ratings = merged }
    artistRatings = Self.merge(artistServer, artistConfirmed, artistEdits.values)
  }

  /// The server's ratings with the confirmed and then the waiting edits on top.
  private static func merge(
    _ server: [String: Int], _ confirmed: [String: Int], _ pending: [String: Int]
  ) -> [String: Int] {
    var merged = server
    for (id, rating) in confirmed.merging(pending, uniquingKeysWith: { _, pending in pending }) {
      merged[id] = rating > 0 ? rating : nil
    }
    return merged
  }

  private func loadCache() {
    let generation = account
    Task(priority: .utility) {
      let (songs, albums, artists) = await LibraryCacheManager.read(qos: .utility) { cache in
        (
          cache.load([Song].self, forKey: .ratedSongs),
          cache.load([Album].self, forKey: .ratedAlbums),
          cache.load([Artist].self, forKey: .ratedArtists)
        )
      }
      self.adoptCached(
        songs: Self.ratings(of: songs ?? []), albums: Self.ratings(of: albums ?? []),
        artists: Self.ratings(of: artists ?? []), account: generation)
      // No cache yet (first launch with ratings, or an upgrade): the next
      // activation may be far away.
      if songs == nil || albums == nil || artists == nil { await self.refreshFromServer() }
    }
  }

  private func adoptCached(
    songs: [String: Int], albums: [String: Int], artists: [String: Int], account generation: Int
  ) {
    // A refresh that landed first is newer than the cache.
    guard account == generation, refreshedAt == nil else { return }
    server = songs
    albumRatings = albums
    artistServer = artists
    publish()
  }

  private func settle(_ rating: Int, id: String, accepted: Bool, artist: Bool) {
    let (pending, server, confirmed, key) =
      artist
      ? (
        artistEdits, \RatingStore.artistServer, \RatingStore.artistConfirmed,
        UserDefaultsKeys.confirmedArtistRatings
      )
      : (edits, \RatingStore.server, \RatingStore.confirmed, UserDefaultsKeys.confirmedRatings)
    if accepted {
      confirmedEdits += 1
      self[keyPath: server][id] = rating > 0 ? rating : nil
      // Kept on disk until a refresh stored it in the cache, so a relaunch
      // before then still knows it without sending it again. Not when a
      // newer edit for the item waits.
      if pending[id] == nil {
        self[keyPath: confirmed][id] = rating
        defaults.set(self[keyPath: confirmed], forKey: key)
      }
    }
    publish()
    // Brings the cached lists up to date for the next launch.
    if edits.isIdle, artistEdits.isIdle { Task { await refreshFromServer() } }
  }

  /// Called on logout; internal for tests.
  func forgetAccount() {
    account += 1
    server = [:]
    albumRatings = [:]
    refreshedAt = nil
    refreshing = nil
    artistServer = [:]
    edits.forgetAccount()
    artistEdits.forgetAccount()
    confirmed = [:]
    artistConfirmed = [:]
    defaults.removeObject(forKey: UserDefaultsKeys.confirmedRatings)
    defaults.removeObject(forKey: UserDefaultsKeys.confirmedArtistRatings)
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

  private nonisolated static func ratings(of artists: [Artist]) -> [String: Int] {
    ratings(of: artists, id: \.id, rating: \.rating)
  }
}
