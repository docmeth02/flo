//
//  MenuTarget.swift
//  flo
//

import Foundation

/// What a hold (or the ••• button) opens the item menu for. Songs carry the
/// collection they were listed in, which the queue keeps as their origin.
enum MenuTarget: Identifiable {
  case song(Song, context: String, isFromPlaylist: Bool)
  case album(Album)
  case artist(Artist)
  case playlist(Playlist)
  case radio(Radio)

  var id: String {
    switch self {
    case .song(let song, _, _): "song-" + song.playbackID
    case .album(let album): "album-" + album.id
    case .artist(let artist): "artist-" + artist.id
    case .playlist(let playlist): "playlist-" + playlist.id
    case .radio(let radio): "radio-" + radio.id
    }
  }

  var title: String {
    switch self {
    case .song(let song, _, _): song.title
    case .album(let album): album.name
    case .artist(let artist): artist.name
    case .playlist(let playlist): playlist.name
    case .radio(let radio): radio.name
    }
  }

  var subtitle: String {
    switch self {
    case .song(let song, _, _): song.artist
    case .album(let album): album.albumArtist
    case .artist(let artist): artist.albumCount > 0 ? counted(artist.albumCount, "album") : ""
    case .playlist: "Playlist"
    case .radio: "Radio"
    }
  }

  /// Songs cannot be pinned.
  var pin: (id: String, kind: PinStore.Kind)? {
    switch self {
    case .song: nil
    case .album(let album): (album.id, .album)
    case .artist(let artist): (artist.id, .artist)
    case .playlist(let playlist): (playlist.id, .playlist)
    case .radio(let radio): (radio.id, .radio)
    }
  }

  /// A station is one endless stream: it is not queued after other songs.
  var canQueue: Bool {
    if case .radio = self { return false }
    return true
  }

  /// Navidrome stars songs, albums and artists only.
  var canLike: Bool {
    switch self {
    case .song, .album, .artist: true
    case .playlist, .radio: false
    }
  }

  /// What Play Next and Add to Queue put in the queue, in play order, and
  /// the collection the queue names as their origin. Albums and artists come
  /// from the cached library (synced first for an artist when it is empty);
  /// an album or playlist missing there from the server, or offline from its
  /// download.
  func queueSongs(
    serverReachable: Bool
  ) async -> (songs: [Song], context: String, isFromPlaylist: Bool) {
    switch self {
    case .song(let song, let context, let isFromPlaylist):
      return ([song], context, isFromPlaylist)
    case .album(let album):
      var songs = await SmartPlaybackService.shared.loadCachedLibrary().songs
        .filter { $0.albumId == album.id }
      if songs.isEmpty, serverReachable {
        songs = (try? await LibraryAPI.getSongFromAlbum(id: album.id)) ?? []
      }
      if songs.isEmpty {
        // Offline: the downloaded tracks, which may be only some of them.
        // The view context, so on main.
        songs = await MainActor.run { DownloadStore.getSongsByAlbumId(albumId: album.id) }
      }
      return (
        songs.sorted { ($0.discNumber, $0.trackNumber) < ($1.discNumber, $1.trackNumber) },
        album.name, false
      )
    case .artist(let artist):
      var library = await SmartPlaybackService.shared.loadCachedLibrary().songs
      if library.isEmpty, serverReachable {
        library = await SmartPlaybackService.shared.syncSongLibrary()
      }
      let keys = await SmartPlaybackService.shared.libraryIndex(allowSync: false).artistKeys
      let songs = library.filter { $0.isBy(artistId: artist.id, name: artist.name, keys: keys) }
      return (
        songs.sorted {
          ($0.year ?? 0, $0.albumName, $0.discNumber, $0.trackNumber)
            < ($1.year ?? 0, $1.albumName, $1.discNumber, $1.trackNumber)
        },
        artist.name, false
      )
    case .playlist(let playlist):
      var songs: [Song] = []
      if serverReachable {
        songs = (try? await LibraryAPI.getSongsByPlaylist(id: playlist.id)) ?? []
      }
      if songs.isEmpty {
        songs = await MainActor.run {
          DownloadStore.getPlaylistSongs(playlistId: playlist.id)
        }
      }
      return (songs, playlist.name, true)
    case .radio:
      return ([], "", false)
    }
  }
}

/// The item menu's actions, carried out the same way on watch and phone.
@MainActor
struct MenuActions {
  enum Action {
    case pin, playNext, addToQueue, like
  }

  let player: PlayerViewModel
  let pins: PinStore
  let stars: StarStore

  /// Nil for an item that cannot be pinned.
  func isPinned(_ target: MenuTarget) -> Bool? {
    target.pin.map { pins.isPinned($0.id, $0.kind) }
  }

  /// Songs ask the player, which knows the heart; albums and artists ask
  /// StarStore over the state they were listed with.
  func isLiked(_ target: MenuTarget) -> Bool {
    switch target {
    case .song(let song, _, _): player.isStarred(song)
    case .album(let album): stars.isStarred(album.id, listed: album.starred)
    case .artist(let artist): stars.isStarred(artist.id, listed: artist.starred)
    case .playlist, .radio: false
    }
  }

  /// Carries out `action` and returns the confirmation to show, nil for none.
  func perform(_ action: Action, on target: MenuTarget) async -> String? {
    switch action {
    case .pin:
      guard let pin = target.pin else { return nil }
      pins.toggle(pin.id, pin.kind)
      return pins.isPinned(pin.id, pin.kind) ? "Pinned" : "Unpinned"
    case .playNext, .addToQueue:
      guard target.canQueue else { return nil }
      let generation = LibraryCacheManager.shared.generation
      let reachable = ConnectivityMonitor.shared.isServerReachable
      let (songs, context, isFromPlaylist) = await target.queueSongs(serverReachable: reachable)
      // A logout meanwhile: these are the previous account's songs.
      guard LibraryCacheManager.shared.generation == generation else { return nil }
      guard !songs.isEmpty else { return reachable ? "Nothing to queue" : "Not available offline" }
      let next = action == .playNext
      let queued =
        next
        ? player.playNext(songs, context: context, isFromPlaylist: isFromPlaylist)
        : player.appendToQueue(songs, context: context, isFromPlaylist: isFromPlaylist)
      return queued ? (next ? "Playing next" : "Added to queue") : nil
    case .like:
      // Offline it waits in StarStore until the server is back.
      let starred = !isLiked(target)
      switch target {
      case .song(let song, _, _): stars.setSong(starred, id: song.playbackID)
      case .album(let album): stars.set(starred, id: album.id)
      case .artist(let artist): stars.set(starred, id: artist.id)
      case .playlist, .radio: return nil
      }
      return starred ? "Liked" : "Removed from Liked"
    }
  }
}
