//
//  AlbumViewModel.swift
//  flo
//
//  Created by rizaldy on 07/06/24.
//

import Foundation

class AlbumViewModel: ObservableObject {
  @Published var artists: [Artist] = []
  @Published var playlists: [Playlist] = []
  @Published var playlist: Playlist = Playlist()
  @Published var artistAlbums: [Album] = []
  @Published var albums: [Album] = []
  @Published var album: Album = Album()
  @Published var starredSongs: [Song] = []
  @Published var downloadedAlbums: [Album] = []
  @Published var isDownloaded = false

  @Published var isLoading = false
  @Published var error: Error?

  init(album: Album = Album(), albums: [Album] = []) {
    self.album = album
    self.albums = albums

    NotificationCenter.default.addObserver(
      self, selector: #selector(handleLogout), name: .didLogout, object: nil)
  }

  /// The next account must not see this account's library.
  @objc private func handleLogout() {
    artists = []
    playlists = []
    artistAlbums = []
    albums = []
    starredSongs = []
  }

  func setActiveAlbum(album: Album) {
    self.album = album
    self.album.albumCover = self.getAlbumCoverArt(id: album.id, albumCover: album.albumCover)

    if !album.id.isEmpty {
      self.getAlbumById()

      if AlbumService.shared.isPlaylistDownload(id: album.id) {
        self.fetchPlaylistSongsIntoAlbum(id: album.id)
      } else {
        self.fetchSongs(id: album.id)
      }
    }
  }

  func setActivePlaylist(playlist: Playlist) {
    self.playlist = playlist
    self.isDownloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: playlist.id)
    self.fetchSongsByPlaylist(id: playlist.id)
  }

  func fetchSongs(id: String) {
    let checkLocalSongs = AlbumService.shared.getSongsByAlbumId(albumId: id)

    self.album.songs = checkLocalSongs

    AlbumService.shared.getSongFromAlbum(id: id) { result in
      self.isLoading = true

      DispatchQueue.main.async {
        self.isLoading = false

        switch result {
        case .success(let songs):
          let remoteSongs = songs.filter { song in
            !self.album.songs.contains(where: { $0.id == song.id })
          }

          guard id == self.album.id else { return }
          self.album.songs.append(contentsOf: remoteSongs)

          self.album.songs.sort { (lhs, rhs) in
            if lhs.discNumber == rhs.discNumber {
              return lhs.trackNumber < rhs.trackNumber
            }
            return lhs.discNumber < rhs.discNumber
          }

        case .failure(let error):
          self.error = error
        }
      }
    }
  }

  func fetchPlaylistSongsIntoAlbum(id: String) {
    let localSongs = AlbumService.shared.getPlaylistSongs(playlistId: id)

    self.album.songs = localSongs

    AlbumService.shared.getSongsByPlaylist(id: id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let remoteSongs):
          let merged = Self.mergePlaylistSongs(local: localSongs, remote: remoteSongs)
          AlbumService.shared.updatePlaylistPositions(playlistId: id, songs: merged)
          // A late response for a playlist the user already left must not
          // replace the tracks of the one now shown.
          guard self.album.id == id else { return }
          self.album.songs = merged

        case .failure(let error):
          self.error = error
        }
      }
    }
  }

  // MARK: - Generic cache helpers

  private enum CacheKey: String {
    case albums, artists, playlists, starredSongs
  }

  /// Requests the list, assigns it and caches it, then calls `done`, all on
  /// the main thread. An empty answer is a real answer (e.g. every song
  /// unliked) and replaces the cached list too.
  private func requestCached<T: Codable>(
    cacheKey: CacheKey,
    assign: @escaping ([T]) -> Void,
    request: @escaping (@escaping (Result<[T], Error>) -> Void) -> Void,
    done: @escaping () -> Void
  ) {
    let cacheGeneration = LibraryCacheManager.shared.generation
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
          debugLog("\(cacheKey.rawValue) loaded: \(items.count)")
          assign(items)
          DispatchQueue.global(qos: .utility).async {
            LibraryCacheManager.shared.save(
              items, forKey: cacheKey.rawValue, generation: cacheGeneration)
          }
        case .failure(let error):
          self.error = error
        }
        done()
      }
    }
  }

  /// Shows the cached list right away when nothing is loaded yet, then
  /// replaces it with the server's.
  private func fetchCached<T: Codable>(
    current: [T],
    cacheKey: CacheKey,
    showsLoading: Bool = false,
    assign: @escaping ([T]) -> Void,
    request: @escaping (@escaping (Result<[T], Error>) -> Void) -> Void
  ) {
    if current.isEmpty,
      let cached = LibraryCacheManager.shared.load([T].self, forKey: cacheKey.rawValue)
    {
      assign(cached)
    }
    if showsLoading { isLoading = true }
    requestCached(cacheKey: cacheKey, assign: assign, request: request) {
      if showsLoading { self.isLoading = false }
    }
  }

  @MainActor
  private func refreshCached<T: Codable>(
    cacheKey: CacheKey,
    assign: @escaping ([T]) -> Void,
    request: @escaping (@escaping (Result<[T], Error>) -> Void) -> Void
  ) async {
    isLoading = true
    defer { isLoading = false }
    await withCheckedContinuation { continuation in
      requestCached(cacheKey: cacheKey, assign: assign, request: request) {
        continuation.resume()
      }
    }
  }

  func fetchStarredSongs() {
    fetchCached(
      current: starredSongs, cacheKey: .starredSongs,
      assign: { self.starredSongs = $0 }, request: AlbumService.shared.getStarredSongs)
  }

  // MARK: - Fetch methods

  func getAlbumCoverArt(
    id: String, artistName: String = "", albumName: String = "", albumCover: String = ""
  ) -> String {
    return AlbumService.shared.getAlbumCover(
      artistName: artistName, albumName: albumName, albumId: id, albumCover: albumCover)
  }

  func getAlbumById() {
    self.isDownloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: self.album.id)
  }

  func downloadAlbum(_ albumToDownload: Album) {
    // The album record must exist even when its cover cannot be fetched,
    // otherwise its downloaded songs never show up in Downloads.
    AlbumService.shared.saveAlbum(albumToDownload)

    AlbumService.shared.downloadAlbumCover(albumId: albumToDownload.id) { result in
      if case .failure(let error) = result {
        print("Failed to save album cover: \(error.localizedDescription)")
      }
    }
  }

  func downloadPlaylist(_ playlistToDownload: Playlist, targetIdx: Int = -1) {
    let maxConcurrentDownloads = ProcessInfo.processInfo.activeProcessorCount / 2
    let downloadSemaphore = DispatchSemaphore(value: maxConcurrentDownloads)

    let songs = targetIdx == -1 ? playlistToDownload.songs : [playlistToDownload.songs[targetIdx]]

    // Core Data work stays on the main thread with the view context; only the
    // cover downloads below go to a background queue.
    AlbumService.shared.savePlaylist(playlistToDownload)

    // The playlist's own cover lives next to its tracks so the Downloads tab
    // can pick it up; failure must not affect the song downloads.
    AlbumService.shared.downloadPlaylistCover(
      playlistId: playlistToDownload.id, coverArtId: playlistToDownload.coverArtId
    ) { result in
      if case .failure(let error) = result {
        print("Failed to save playlist cover: \(error.localizedDescription)")
      }
    }

    songs.forEach { song in
      DispatchQueue.global(qos: .background).async {
        downloadSemaphore.wait()

        AlbumService.shared.downloadAlbumCoverForPlaylist(albumId: song.albumId) { _ in
          downloadSemaphore.signal()
        }
      }
    }
  }

  func removeDownloadedAlbum(album: Album) {
    AlbumService.shared.removeDownloadedCollection(
      id: album.id, legacyDirectory: "Media/\(album.artist)/\(album.name)"
    ) { result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          self.setActiveAlbum(album: album)
        case .failure(let error):
          print("error >>>", error)
        }
      }
    }
  }

  func removeDownloadedPlaylist(playlist: Playlist) {
    AlbumService.shared.removeDownloadedCollection(
      id: playlist.id, legacyDirectory: "Media/Various Artists/\(playlist.name)"
    ) { result in
      DispatchQueue.main.async {
        switch result {
        case .success:
          self.setActivePlaylist(playlist: playlist)
        case .failure(let error):
          print("error >>>", error)
        }
      }
    }
  }

  func fetchAlbums() {
    fetchCached(
      current: albums, cacheKey: .albums, showsLoading: true,
      assign: { self.albums = $0 }, request: AlbumService.shared.getAlbum)
  }

  func fetchAlbumsByArtist(id: String) {
    AlbumService.shared.getAlbumsByArtist(id: id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let albums):
          self.artistAlbums = albums
        case .failure(let error):
          self.error = error
        }
      }
    }
  }

  func fetchSongsByPlaylist(id: String) {
    let localSongs = AlbumService.shared.getPlaylistSongs(playlistId: id)

    self.playlist.songs = localSongs

    AlbumService.shared.getSongsByPlaylist(id: id) { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let remoteSongs):
          let merged = Self.mergePlaylistSongs(local: localSongs, remote: remoteSongs)
          AlbumService.shared.updatePlaylistPositions(playlistId: id, songs: merged)
          guard self.playlist.id == id else { return }
          self.playlist.songs = merged

        case .failure(let error):
          self.error = error
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
      current: playlists, cacheKey: .playlists,
      assign: { self.playlists = $0 }, request: AlbumService.shared.getPlaylists)
  }

  func getArtists() {
    fetchCached(
      current: artists, cacheKey: .artists,
      assign: { self.artists = $0 }, request: AlbumService.shared.getArtists)
  }

  // MARK: - Async refresh variants

  @MainActor func refreshAlbums() async {
    await refreshCached(
      cacheKey: .albums, assign: { self.albums = $0 },
      request: AlbumService.shared.getAlbum)
  }

  @MainActor func refreshArtists() async {
    await refreshCached(
      cacheKey: .artists, assign: { self.artists = $0 },
      request: AlbumService.shared.getArtists)
  }

  @MainActor func refreshPlaylists() async {
    await refreshCached(
      cacheKey: .playlists, assign: { self.playlists = $0 },
      request: AlbumService.shared.getPlaylists)
  }

  @MainActor func refreshStarredSongs() async {
    await refreshCached(
      cacheKey: .starredSongs, assign: { self.starredSongs = $0 },
      request: AlbumService.shared.getStarredSongs)
  }

  func fetchDownloadedAlbums() {
    AlbumService.shared.getDownloadedAlbum { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let albums):
          // TODO: is this expensive?
          self.downloadedAlbums = albums.filter { album in
            let songs = AlbumService.shared.getSongsByAlbumId(albumId: album.id)

            return !songs.isEmpty
          }

        case .failure(let error):
          self.error = error
        }
      }
    }
  }
}
