//
//  AlbumViewModel.swift
//  flo
//

import Foundation

class AlbumViewModel: ObservableObject {
  @Published var artists: [Artist] = []
  @Published var playlists: [Playlist] = []
  @Published var playlist: Playlist = Playlist()
  @Published private var artistAlbums: [Album] = []
  @Published var albums: [Album] = []
  @Published var album: Album = Album()
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

  func setActiveAlbum(album: Album) {
    self.album = album

    if !album.id.isEmpty {
      if AlbumService.shared.isPlaylistDownload(id: album.id) {
        self.album.isPlaylist = true
        fetchPlaylistSongs(id: album.id, isShown: { self.album.id == album.id }) {
          self.album.songs = $0
        }
      } else {
        self.fetchSongs(id: album.id)
      }
    }
  }

  func setActivePlaylist(playlist: Playlist) {
    self.playlist = playlist
    fetchPlaylistSongs(id: playlist.id, isShown: { self.playlist.id == playlist.id }) {
      self.playlist.songs = $0
    }
  }

  func fetchSongs(id: String) {
    let checkLocalSongs = AlbumService.shared.getSongsByAlbumId(albumId: id)

    self.album.songs = checkLocalSongs

    AlbumService.shared.getSongFromAlbum(id: id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let songs):
          guard id == self.album.id else { return }
          let remoteSongs = songs.filter { song in
            !self.album.songs.contains(where: { $0.id == song.id })
          }
          self.album.songs.append(contentsOf: remoteSongs)

          self.album.songs.sort { (lhs, rhs) in
            if lhs.discNumber == rhs.discNumber {
              return lhs.trackNumber < rhs.trackNumber
            }
            return lhs.discNumber < rhs.discNumber
          }

        case .failure(let error):
          debugLog("album songs failed: \(error)")
        }
      }
    }
  }

  /// The playlist's downloaded songs at once, then the server's order with
  /// the downloads in place. `assign` is skipped for a late answer once
  /// `isShown` says the playlist was left, so it never replaces the tracks
  /// of the one now shown.
  private func fetchPlaylistSongs(
    id: String, isShown: @escaping () -> Bool, assign: @escaping ([Song]) -> Void
  ) {
    let localSongs = AlbumService.shared.getPlaylistSongs(playlistId: id)
    assign(localSongs)

    AlbumService.shared.getSongsByPlaylist(id: id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let remoteSongs):
          let merged = Self.mergePlaylistSongs(local: localSongs, remote: remoteSongs)
          AlbumService.shared.updatePlaylistPositions(playlistId: id, songs: merged)
          guard isShown() else { return }
          assign(merged)

        case .failure(let error):
          debugLog("playlist songs failed: \(error)")
        }
      }
    }
  }

  // MARK: - Generic cache helpers

  /// Requests the list, assigns it and caches it, then calls `done`, all on
  /// the main thread. An empty answer is a real answer (e.g. every song
  /// unliked) and replaces the cached list too.
  private func requestCached<T: Codable>(
    _ library: Library,
    assign: @escaping ([T]) -> Void,
    request: @escaping (@escaping (Result<[T], Error>) -> Void) -> Void,
    done: @escaping () -> Void
  ) {
    let cacheGeneration = LibraryCacheManager.shared.generation
    // A new attempt takes the list out of its error state.
    listStates[library] = ListState(isLoading: true)
    request { result in
      DispatchQueue.main.async {
        // Logout clears the cache and bumps its generation; an answer for the
        // previous account must not refill the lists either.
        guard LibraryCacheManager.shared.generation == cacheGeneration else {
          done()
          return
        }
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
        done()
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
    request: @escaping (@escaping (Result<[T], Error>) -> Void) -> Void
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
    requestCached(library, assign: assign, request: request) {}
  }

  @MainActor
  private func refreshCached<T: Codable>(
    _ library: Library,
    assign: @escaping ([T]) -> Void,
    request: @escaping (@escaping (Result<[T], Error>) -> Void) -> Void
  ) async {
    await withCheckedContinuation { continuation in
      requestCached(library, assign: assign, request: request) {
        continuation.resume()
      }
    }
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
  private static func starredSongsRequest(_ completion: @escaping (Result<[Song], Error>) -> Void) {
    let since = MainActor.assumeIsolated { StarStore.shared.listRevision }
    AlbumService.shared.getStarred { starred in
      let result = starred.map(\.songs)
      if case .success(let songs) = result {
        DispatchQueue.main.async {
          MainActor.assumeIsolated {
            StarStore.shared.adoptServerStars(songs.map(\.playbackID), since: since)
          }
        }
      }
      completion(result)
    }
  }

  private static let albumsRequest = adoptingStars(AlbumService.shared.getAlbum) {
    ($0.id, $0.starred)
  }
  private static let artistsRequest = adoptingStars(AlbumService.shared.getArtists) {
    ($0.id, $0.starred)
  }

  /// A full list of albums or artists, which also tells StarStore which of
  /// them are starred now.
  private static func adoptingStars<T>(
    _ request: @escaping (@escaping (Result<[T], Error>) -> Void) -> Void,
    star: @escaping (T) -> (id: String, starred: Bool)
  ) -> (@escaping (Result<[T], Error>) -> Void) -> Void {
    { completion in
      let since = MainActor.assumeIsolated { StarStore.shared.listRevision }
      request { result in
        if case .success(let items) = result {
          let stars = items.map(star)
          DispatchQueue.main.async {
            MainActor.assumeIsolated { StarStore.shared.adoptServerList(stars, since: since) }
          }
        }
        completion(result)
      }
    }
  }

  // MARK: - Fetch methods

  func removeDownloadedAlbum(album: Album) {
    AlbumService.shared.removeDownloadedCollection(id: album.id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          self.setActiveAlbum(album: album)
        case .failure(let error):
          debugLog("removing album failed: \(error)")
        }
      }
    }
  }

  func removeDownloadedPlaylist(playlist: Playlist) {
    AlbumService.shared.removeDownloadedCollection(id: playlist.id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          self.setActivePlaylist(playlist: playlist)
        case .failure(let error):
          debugLog("removing playlist failed: \(error)")
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
    AlbumService.shared.getAlbumsByArtist(id: id) { result in
      DispatchQueue.main.async {
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
      assign: { self.playlists = $0 }, request: AlbumService.shared.getPlaylists)
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
      request: AlbumService.shared.getPlaylists)
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
  static func cached<T: Codable>(_ library: Library) async -> [T] {
    await LibraryCacheManager.shared.read { $0.load([T].self, forKey: library.cacheKey) ?? [] }
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
    downloadedAlbums = AlbumService.shared.downloadedAlbums().filter { album in
      !CoreDataManager.shared.getRecordByKey(
        entity: SongEntity.self, key: \SongEntity.albumId, value: album.id, limit: 1
      ).isEmpty
    }
  }
}
