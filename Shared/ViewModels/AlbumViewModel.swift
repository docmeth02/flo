//
//  AlbumViewModel.swift
//  flo
//

import Foundation

class AlbumViewModel: ObservableObject {
  @Published var artists: [Artist] = []
  @Published var playlists: [Playlist] = []
  @Published private var artistAlbums: [Album] = []
  @Published var albums: [Album] = []
  @Published var starredSongs: [Song] = []
  @Published var downloadedAlbums: [Album] = []
  @Published private(set) var recentAlbums: [Album] = []

  /// A library list loaded from the server and cached on the watch.
  enum Library: String {
    case albums, artists, playlists, starredSongs

    /// How long a loaded list is shown again without asking the server, so
    /// popping back from a detail screen does not reload the whole list.
    /// Liked songs change from Now Playing and always reload.
    var maxAge: TimeInterval { self == .starredSongs ? 0 : AlbumViewModel.reloadAfter }

    var cacheKey: LibraryCacheManager.Key {
      switch self {
      case .albums: .albums
      case .artists: .artists
      case .playlists: .playlists
      case .starredSongs: .starredSongs
      }
    }
  }

  private static let reloadAfter: TimeInterval = 5 * 60

  /// A whole library list from the server; run on the main actor so it can
  /// tell StarStore what the list says.
  private typealias ListRequest<T> = @MainActor () async throws -> [T]

  @Published private(set) var listStates: [Library: ListState] = [:]

  /// The artist whose albums `artistAlbums` holds, so a late answer for the
  /// previous artist does not show on this one.
  private var artistAlbumsId = ""
  private var artistAlbumsLoadedAt: Date?

  init() {
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: nil) {
      [weak self] _ in
      self?.handleLogout()
    }
  }

  /// The next account must not see this account's library.
  private func handleLogout() {
    artists = []
    playlists = []
    artistAlbums = []
    artistAlbumsId = ""
    albums = []
    starredSongs = []
    recentAlbums = []
    listStates = [:]
  }

  func state(_ library: Library) -> ListState {
    listStates[library] ?? ListState()
  }

  func albums(byArtist id: String) -> [Album] {
    id == artistAlbumsId ? artistAlbums : []
  }

  // MARK: - Album and playlist songs

  /// An album's songs for its screen: the downloaded ones at once, then the
  /// server's list with them in disc and track order. A downloaded playlist
  /// shown as an album loads as a playlist.
  @MainActor func loadSongs(of album: Album) -> AsyncStream<[Song]> {
    if album.isPlaylist { return loadPlaylistSongs(id: album.id) }
    let id = album.id
    return Self.downloadedThenServer(DownloadStore.getSongsByAlbumId(albumId: id)) { local in
      Self.mergeAlbumSongs(local: local, remote: try await LibraryAPI.getSongFromAlbum(id: id))
    }
  }

  /// A playlist's downloaded songs at once, then the server's order with the
  /// downloads in place.
  @MainActor func loadSongs(of playlist: Playlist) -> AsyncStream<[Song]> {
    loadPlaylistSongs(id: playlist.id)
  }

  private func loadPlaylistSongs(id: String) -> AsyncStream<[Song]> {
    Self.downloadedThenServer(DownloadStore.getPlaylistSongs(playlistId: id)) { local in
      let remote = try await LibraryAPI.getSongsByPlaylist(id: id)
      let merged = Self.mergePlaylistSongs(local: local, remote: remote)
      DownloadStore.updatePlaylistPositions(playlistId: id, songs: merged)
      return merged
    }
  }

  /// `local`, then what `merge` makes of it with the server's answer. The
  /// request runs to its end when the screen leaves, so a playlist's
  /// download positions are still written. Without the server the
  /// downloaded songs stay.
  private static func downloadedThenServer(
    _ local: [Song], merge: @escaping @MainActor ([Song]) async throws -> [Song]
  ) -> AsyncStream<[Song]> {
    AsyncStream { continuation in
      continuation.yield(local)
      Task { @MainActor in
        do {
          continuation.yield(try await merge(local))
        } catch {
          debugLog("collection songs failed: \(error)")
        }
        continuation.finish()
      }
    }
  }

  /// The downloaded songs with the server's others, in disc and track order.
  static func mergeAlbumSongs(local: [Song], remote: [Song]) -> [Song] {
    let localIds = Set(local.map(\.id))
    return (local + remote.filter { !localIds.contains($0.id) }).sorted { lhs, rhs in
      if lhs.discNumber == rhs.discNumber {
        return lhs.trackNumber < rhs.trackNumber
      }
      return lhs.discNumber < rhs.discNumber
    }
  }

  // MARK: - Generic cache helpers

  /// Requests the list, assigns it and caches it on the main thread; the
  /// task ends when that is done. An empty answer is a real answer (e.g.
  /// every song unliked) and replaces the cached list too.
  @discardableResult
  private func requestCached<T: Codable>(
    _ library: Library,
    assign: @escaping ([T]) -> Void,
    request: @escaping ListRequest<T>
  ) -> Task<Void, Never> {
    let cacheGeneration = LibraryCacheManager.shared.generation
    // A new attempt takes the list out of its error state.
    listStates[library] = ListState(isLoading: true)
    return Task { @MainActor in
      let result = await Result { try await request() }
      // Logout clears the cache and bumps its generation; an answer for the
      // previous account must not refill the lists either.
      guard LibraryCacheManager.shared.generation == cacheGeneration else { return }
      switch result {
      case .success(let items):
        debugLog("\(library.rawValue) loaded: \(items.count)")
        assign(items)
        self.listStates[library] = ListState(loadedAt: Date())
        DispatchQueue.global(qos: .utility).async {
          LibraryCacheManager.shared.save(
            items, forKey: library.cacheKey, generation: cacheGeneration)
          // Siri reads the artist names for "Play <artist>" from this cache.
          if library == .artists { FloShortcuts.updateAppShortcutParameters() }
        }
      case .failure:
        self.listStates[library] = ListState(failed: true)
      }
    }
  }

  /// Shows the cached list right away when nothing is loaded yet, then
  /// replaces it with the server's unless that is under way or younger than
  /// `maxAge`, the list's own by default.
  private func fetchCached<T: Codable>(
    _ library: Library,
    maxAge: TimeInterval? = nil,
    current: [T],
    assign: @escaping ([T]) -> Void,
    request: @escaping ListRequest<T>
  ) {
    let state = state(library)
    if state.isLoading { return }
    if let loadedAt = state.loadedAt,
      Date().timeIntervalSince(loadedAt) < maxAge ?? library.maxAge
    {
      return
    }
    if current.isEmpty,
      let cached = LibraryCacheManager.shared.load([T].self, forKey: library.cacheKey)
    {
      assign(cached)
    }
    requestCached(library, assign: assign, request: request)
  }

  @MainActor
  private func refreshCached<T: Codable>(
    _ library: Library,
    assign: @escaping ([T]) -> Void,
    request: @escaping ListRequest<T>
  ) async {
    await requestCached(library, assign: assign, request: request).value
  }

  func fetchStarredSongs() {
    fetchStarredSongs(maxAge: nil)
  }

  /// Liked Songs at most every few minutes, for the iPhone's Home, which
  /// shows them on every return; the Liked screens always reload.
  func fetchStarredSongsIfStale() {
    fetchStarredSongs(maxAge: Self.reloadAfter)
  }

  private func fetchStarredSongs(maxAge: TimeInterval?) {
    fetchCached(
      .starredSongs, maxAge: maxAge, current: starredSongs,
      assign: { self.starredSongs = $0 }, request: Self.starredSongsRequest)
  }

  /// The server's Liked Songs, which also tell StarStore what is starred now
  /// (the cached copy shown meanwhile does not).
  @MainActor private static func starredSongsRequest() async throws -> [Song] {
    let since = StarStore.shared.listRevision
    let songs = try await LibraryAPI.getStarred().songs
    StarStore.shared.adoptServerStars(songs.map(\.playbackID), since: since)
    return songs
  }

  private static let albumsRequest = adoptingStars(LibraryAPI.getAlbum) {
    ($0.id, $0.starred)
  }
  private static let artistsRequest = adoptingStars(LibraryAPI.getArtists) {
    ($0.id, $0.starred)
  }

  /// A full list of albums or artists, which also tells StarStore which of
  /// them are starred now.
  private static func adoptingStars<T>(
    _ request: @escaping () async throws -> [T],
    star: @escaping (T) -> (id: String, starred: Bool)
  ) -> ListRequest<T> {
    {
      let since = StarStore.shared.listRevision
      let items = try await request()
      StarStore.shared.adoptServerList(items.map(star), since: since)
      return items
    }
  }

  // MARK: - Fetch methods

  /// Removes a downloaded album or playlist, then calls `removed` on the
  /// main thread so its screen can load the server's songs instead.
  func removeDownload(id: String, removed: @escaping () -> Void = {}) {
    DownloadStore.removeDownloadedCollection(id: id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          removed()
        case .failure(let error):
          debugLog("removing download failed: \(error)")
        }
      }
    }
  }

  func fetchAlbums() {
    fetchCached(
      .albums, current: albums,
      assign: { self.albums = $0 }, request: Self.albumsRequest)
  }

  func fetchAlbumsByArtist(id: String) {
    if id != artistAlbumsId {
      artistAlbumsId = id
      artistAlbums = []
      artistAlbumsLoadedAt = nil
    } else if let loadedAt = artistAlbumsLoadedAt,
      Date().timeIntervalSince(loadedAt) < Self.reloadAfter
    {
      return
    }
    Task { @MainActor in
      let result = await Result { try await LibraryAPI.getAlbumsByArtist(id: id) }
      guard id == self.artistAlbumsId else { return }
      switch result {
      case .success(let albums):
        self.artistAlbums = albums
        self.artistAlbumsLoadedAt = Date()
      case .failure(let error):
        debugLog("artist albums failed: \(error)")
      }
    }
  }

  /// Preserves the server-defined playlist order, substituting locally downloaded
  /// versions in place so the download indicator/offline playback still work.
  static func mergePlaylistSongs(local: [Song], remote: [Song]) -> [Song] {
    var localByMediaFileId: [String: Song] = [:]

    for song in local where localByMediaFileId[song.mediaFileId] == nil {
      localByMediaFileId[song.mediaFileId] = song
    }

    var merged: [Song] = []
    var consumedMediaFileIds = Set<String>()

    for remoteSong in remote {
      if let localSong = localByMediaFileId[remoteSong.mediaFileId],
        !consumedMediaFileIds.contains(remoteSong.mediaFileId)
      {
        merged.append(localSong)
        consumedMediaFileIds.insert(remoteSong.mediaFileId)
      } else {
        merged.append(remoteSong)
      }
    }

    // Keep any downloaded songs that are no longer part of the server playlist.
    for localSong in local where !consumedMediaFileIds.contains(localSong.mediaFileId) {
      merged.append(localSong)
    }

    return merged
  }

  func getPlaylists() {
    fetchCached(
      .playlists, current: playlists,
      assign: { self.playlists = $0 }, request: LibraryAPI.getPlaylists)
  }

  func getArtists() {
    fetchCached(
      .artists, current: artists,
      assign: { self.artists = $0 }, request: Self.artistsRequest)
  }

  /// Siri and Shortcuts know only the cached artists. After a login nothing
  /// is cached until the Artists list loads, so Home asks for it once.
  @MainActor func cacheArtistsIfNeeded() async {
    guard artists.isEmpty else { return }
    let cached: [Artist] = await Self.cached(.artists)
    if !cached.isEmpty {
      // Kept, so the next return to Home does not read the cache again.
      artists = cached
    } else if ConnectivityMonitor.shared.canReachServer {
      // Not offline: a failed load would be asked again on every return.
      getArtists()
    }
  }

  // MARK: - Async refresh variants

  @MainActor func refreshAlbums() async {
    await refreshCached(
      .albums, assign: { self.albums = $0 },
      request: Self.albumsRequest)
  }

  @MainActor func refreshArtists() async {
    await refreshCached(
      .artists, assign: { self.artists = $0 },
      request: Self.artistsRequest)
  }

  @MainActor func refreshPlaylists() async {
    await refreshCached(
      .playlists, assign: { self.playlists = $0 },
      request: LibraryAPI.getPlaylists)
  }

  @MainActor func refreshStarredSongs() async {
    await refreshCached(
      .starredSongs, assign: { self.starredSongs = $0 }, request: Self.starredSongsRequest)
  }

  /// `list` as loaded, or while it is empty its cached copy, read off the
  /// main thread. Never asks the server.
  @MainActor func loadedOrCached<T: Codable>(_ list: [T], _ library: Library) async -> [T] {
    guard list.isEmpty else { return list }
    return await Self.cached(library)
  }

  /// The cached copy of a library list, read off the main thread, for code
  /// without a view model (the App Intents).
  nonisolated(nonsending) static func cached<T: Codable>(_ library: Library) async -> [T] {
    await LibraryCacheManager.read { $0.load([T].self, forKey: library.cacheKey) ?? [] }
  }

  /// The last four albums played, from the server's mirrored plays and the
  /// local ones not mirrored yet. Never asks the server.
  @MainActor func loadRecentAlbums() async {
    let cacheGeneration = LibraryCacheManager.shared.generation
    async let mirrored = ListeningHistoryStore.shared.recentSongIds(limit: 100)
    async let journal = PlaybackJournal.shared.snapshot()
    async let index = SmartPlaybackService.shared.libraryIndex(allowSync: false)
    let plays = await mirrored + (await journal).lastHeardAt.map { (id: $0.key, at: $0.value) }
    let songs = await index.songs
    let library = await loadedOrCached(albums, .albums)
    // A logout meanwhile must not show the previous account's albums.
    guard LibraryCacheManager.shared.generation == cacheGeneration else { return }
    let byId = Dictionary(library.map { ($0.id, $0) }) { first, _ in first }
    var seen = Set<String>()
    recentAlbums = Array(
      plays.sorted { $0.at > $1.at }
        .compactMap { songs[$0.id].flatMap { byId[$0.albumId] } }
        .filter { seen.insert($0.id).inserted }
        .prefix(4))
  }

  func fetchDownloadedAlbums() {
    // One row per album is enough to tell it still has songs.
    downloadedAlbums = DownloadStore.downloadedAlbums().filter { album in
      !CoreDataManager.shared.getRecordByKey(
        entity: SongEntity.self, key: \SongEntity.albumId, value: album.id, limit: 1
      ).isEmpty
    }
  }
}
