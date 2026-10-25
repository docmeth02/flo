//
//  CollectionDownload.swift
//  flo
//

import Foundation

/// What a Download asks before `DownloadSession` takes an album or playlist:
/// its songs and whether any of them is still missing here.
enum CollectionDownload {
  enum Outcome {
    /// The album with its songs, ready to enqueue.
    case ready(Album)
    /// No songs: the server is away and none are known.
    case unavailable
    /// Every song is on the device already.
    case downloaded
    /// A logout or another login meanwhile: the songs are the previous
    /// account's.
    case accountChanged
  }

  /// The songs of `album` (a playlist when `isPlaylist`), with the account
  /// guard and the check for songs already here.
  @MainActor static func prepare(_ album: Album) async -> Outcome {
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
