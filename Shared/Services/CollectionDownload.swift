//
//  CollectionDownload.swift
//  Ownwave
//

import Foundation

/// The one Download of an album or playlist, from a menu or its screen: its
/// songs are asked first, then `DownloadSession` takes the ones still
/// missing here. Each app says the outcome its own way.
enum CollectionDownload {
  enum Outcome {
    /// Handed to the download session with these songs.
    case ready(Album)
    /// No songs: the server is away and none are known.
    case unavailable
    /// Every song is on the device already.
    case downloaded
    /// A logout or another login meanwhile: the songs are the previous
    /// account's.
    case accountChanged
    /// Started another way while the songs were asked, such as the iPhone
    /// sending it to the watch.
    case underway
  }

  /// Downloads the album; `underway` tells, once its songs are known,
  /// whether it is on its way already.
  @MainActor static func start(
    _ album: Album, underway: (String) -> Bool = { _ in false }
  ) async -> Outcome {
    await start(album, underway: underway) { DownloadSession.shared.enqueue($0) }
  }

  /// Downloads the playlist with its mosaic cover.
  @MainActor static func start(
    _ playlist: Playlist, underway: (String) -> Bool = { _ in false }
  ) async -> Outcome {
    await start(Album(from: playlist), underway: underway) { album in
      var playlist = playlist
      playlist.songs = album.songs
      DownloadSession.shared.enqueue(playlist)
    }
  }

  @MainActor private static func start(
    _ album: Album, underway: (String) -> Bool, enqueue: (Album) -> Void
  ) async -> Outcome {
    let outcome = await prepare(album)
    switch outcome {
    case .ready(let album):
      guard !underway(album.id) else { return .underway }
      enqueue(album)
    case .unavailable, .downloaded:
      // Offline the songs known are only those here; the session restarts
      // the failed ones they do not list.
      if DownloadSession.shared.hasFailed(collectionId: album.id) {
        enqueue(album)
        return .ready(album)
      }
    case .accountChanged, .underway: break
    }
    return outcome
  }

  /// The songs of `album` (a playlist when `isPlaylist`), with the account
  /// guard and the check for songs already here.
  @MainActor private static func prepare(_ album: Album) async -> Outcome {
    let account = AuthService.shared.accountKey
    var album = album
    album.songs = await songs(of: album)
    guard AuthService.shared.accountKey == account else { return .accountChanged }
    guard !album.songs.isEmpty else { return .unavailable }
    let here = DownloadStore.downloadedMediaFileIds(collectionId: album.id)
    guard album.songs.contains(where: { !here.contains($0.playbackID) }) else {
      return .downloaded
    }
    return .ready(album)
  }

  /// The album's whole track list from the server: an album screen may show
  /// only the songs downloaded here. A downloaded playlist opened as an album
  /// asks for the playlist's. Without the server, the songs known. Also what
  /// a send to the watch takes.
  static func songs(of album: Album) async -> [Song] {
    guard ConnectivityMonitor.shared.canReachServer else { return album.songs }
    // An empty answer (the album gone from the server) keeps what is known.
    let request = album.isPlaylist ? LibraryAPI.getSongsByPlaylist : LibraryAPI.getSongFromAlbum
    guard let songs = try? await request(album.id), !songs.isEmpty else { return album.songs }
    return songs
  }
}
