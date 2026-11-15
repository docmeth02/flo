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
    /// Handed to the download session.
    case ready
    /// No songs: the server is away and none are known.
    case unavailable
    /// Every song is on the device already.
    case downloaded
    /// A logout or another login meanwhile: the songs are the previous
    /// account's.
    case accountChanged
    /// Started another way while the songs were asked, such as the iPhone
    /// sending it to the watch, or by an earlier tap still asking them.
    case underway
  }

  /// Downloads the album; `underway` tells, once its songs are known,
  /// whether it is on its way already.
  @MainActor static func start(
    _ album: Album, underway: (String) -> Bool = { _ in false }
  ) async -> Outcome {
    await start(album, underway: underway) {
      DownloadSession.shared.enqueue($0, complete: $1)
    }
  }

  /// Downloads the playlist with its mosaic cover.
  @MainActor static func start(
    _ playlist: Playlist, underway: (String) -> Bool = { _ in false }
  ) async -> Outcome {
    await start(Album(from: playlist), underway: underway) { album, complete in
      var playlist = playlist
      playlist.songs = album.songs
      DownloadSession.shared.enqueue(playlist, complete: complete)
    }
  }

  /// The collections whose songs are being asked.
  @MainActor private static var preparing: Set<String> = []

  /// `enqueue` takes the album and whether its songs are the server's whole
  /// list of it.
  @MainActor private static func start(
    _ album: Album, underway: (String) -> Bool, enqueue: (Album, Bool) -> Void
  ) async -> Outcome {
    guard preparing.insert(album.id).inserted else { return .underway }
    defer { preparing.remove(album.id) }
    let (outcome, prepared, complete) = await prepare(album)
    switch outcome {
    case .ready:
      guard !underway(album.id) else { return .underway }
      enqueue(prepared, complete)
    case .downloaded where complete:
      // Every song the server lists is here: a job left over is for a song
      // it no longer has.
      DownloadSession.shared.cancel(collectionId: album.id)
    case .unavailable, .downloaded:
      // Offline the songs known are only those here; the session restarts
      // the failed ones they do not list.
      if DownloadSession.shared.hasFailed(collectionId: album.id) {
        enqueue(album, false)
        return .ready
      }
    case .accountChanged, .underway: break
    }
    return outcome
  }

  /// The outcome for `album` (a playlist when `isPlaylist`) with its songs,
  /// with the account guard and the check for songs already here; `complete`
  /// when the songs are the list the server just gave.
  @MainActor private static func prepare(
    _ album: Album
  ) async -> (outcome: Outcome, album: Album, complete: Bool) {
    let account = AuthService.shared.accountKey
    var album = album
    let listed = await serverSongs(of: album)
    album.songs = listed ?? album.songs
    let complete = listed != nil
    guard AuthService.shared.accountKey == account else {
      return (.accountChanged, album, complete)
    }
    guard !album.songs.isEmpty else { return (.unavailable, album, complete) }
    let here = DownloadStore.downloadedMediaFileIds(collectionId: album.id)
    guard album.songs.contains(where: { !here.contains($0.playbackID) }) else {
      return (.downloaded, album, complete)
    }
    return (.ready, album, complete)
  }

  /// The album's whole track list from the server: an album screen may show
  /// only the songs downloaded here. A downloaded playlist opened as an album
  /// asks for the playlist's. Without the server, the songs known. Also what
  /// a send to the watch takes.
  static func songs(of album: Album) async -> [Song] {
    await serverSongs(of: album) ?? album.songs
  }

  /// The server's list of the album's songs; nil without the server, when
  /// the request failed and for an empty answer (the album gone from the
  /// server), which keeps what is known.
  private static func serverSongs(of album: Album) async -> [Song]? {
    guard ConnectivityMonitor.shared.canReachServer else { return nil }
    let request = album.isPlaylist ? LibraryAPI.getSongsByPlaylist : LibraryAPI.getSongFromAlbum
    guard let songs = try? await request(album.id), !songs.isEmpty else { return nil }
    return songs
  }
}
