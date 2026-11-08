//
//  MenuTarget.swift
//  Ownwave
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

  /// Boost and Avoid rate songs and artists; album ratings are not edited.
  var canRate: Bool {
    switch self {
    case .song, .artist: true
    case .album, .playlist, .radio: false
    }
  }

  /// The artist id a song or album carries, the one Go to Artist opens.
  var carriedArtistId: String? {
    switch self {
    case .song(let song, _, _):
      [song.artistId, song.albumArtistId].compactMap { $0 }.first { !$0.isEmpty }
    // An album's own artist: a compilation's track artist field may name
    // someone else, or "Various Artists".
    case .album(let album): [album.albumArtistId, album.artistId].first { !$0.isEmpty }
    case .artist, .playlist, .radio: nil
    }
  }

  /// The name of the artist `carriedArtistId` names.
  var carriedArtistName: String {
    switch self {
    case .song(let song, _, _): song.artist
    case .album(let album): album.albumArtistId.isEmpty ? album.artist : album.albumArtist
    case .artist, .playlist, .radio: ""
    }
  }

  /// Whether Go to Album leads anywhere but `shown`, the item whose screen
  /// the menu is on: a song's album.
  func offersAlbum(except shown: String?) -> Bool {
    guard case .song(let song, _, _) = self else { return false }
    return !song.albumId.isEmpty && song.albumId != shown
  }

  /// Whether Go to Artist leads anywhere but `shown`: a song without an id
  /// is still found by its artist's name, an album (a downloaded playlist
  /// keeps none) only by an id.
  func offersArtist(except shown: String?) -> Bool {
    switch self {
    case .song: carriedArtistId == nil || carriedArtistId != shown
    case .album: carriedArtistId.map { $0 != shown } ?? false
    case .artist, .playlist, .radio: false
    }
  }

  /// The artist Go to Artist opens, for a song or an album: by the id the
  /// item carries, else (a downloaded song keeps none) the one cached artist
  /// of its name. Nil when neither knows it.
  func artistToOpen() async -> Artist? {
    let id: String?
    switch self {
    case .song(let song, _, _):
      if let carried = carriedArtistId {
        id = carried
      } else {
        id = await NowPlayingTarget.artistId(of: song.playbackID, named: song.artist)
      }
    case .album:
      id = carriedArtistId
    case .artist, .playlist, .radio:
      return nil
    }
    guard let id else { return nil }
    let artists: [Artist] = await AlbumViewModel.cached(.artists)
    return artists.first { $0.id == id }
      ?? Artist(id: id, name: carriedArtistName, albumCount: 0, mbzArtistID: nil)
  }

  /// The songs an album or artist is queued from: offline only those that
  /// play without the server, as the album screen and `playArtist` take.
  private static func library(serverReachable: Bool) async -> [Song] {
    let service = SmartPlaybackService.shared
    if serverReachable { return await service.loadCachedLibrary().songs }
    return await service.offlinePlayableSongs()
  }

  /// What Play Next and Add to Queue put in the queue, in play order, and
  /// the collection the queue names as their origin. Albums and artists come
  /// from the cached library (synced first for an artist when it is empty;
  /// offline only what plays here);
  /// an album or playlist missing there from the server, or offline from its
  /// download.
  func queueSongs(
    serverReachable: Bool
  ) async -> (songs: [Song], context: String, isFromPlaylist: Bool) {
    switch self {
    case .song(let song, let context, let isFromPlaylist):
      return ([song], context, isFromPlaylist)
    case .album(let album):
      var songs = await Self.library(serverReachable: serverReachable)
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
        songs.sorted(by: Song.albumOrder),
        album.name, false
      )
    case .artist(let artist):
      var library = await Self.library(serverReachable: serverReachable)
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
    case pin, playNext, addToQueue, like, boost, avoid
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

  /// The item's own rating, which Boost and Avoid set and clear; nil for
  /// what cannot be rated. A song without its own rating can still be
  /// avoided through its album or artist, so a cleared Avoid says "cleared",
  /// never "allowed".
  func ownRating(_ target: MenuTarget) -> Int? {
    switch target {
    case .song(let song, _, _): RatingStore.shared.rating(for: song.playbackID)
    case .artist(let artist): RatingStore.shared.artistRating(artist.id)
    case .album, .playlist, .radio: nil
    }
  }

  /// What Go to Artist says when the artist is not known.
  static let artistNotFound = "Artist not in your library"

  /// The rating Boost or Avoid sets.
  private static func rating(of action: Action) -> Int {
    action == .boost ? RatingStore.boost : RatingStore.avoid
  }

  /// Whether the item's own rating is the one Boost or Avoid sets, so a tap
  /// clears it.
  private func isSet(_ action: Action, on target: MenuTarget) -> Bool {
    ownRating(target) == Self.rating(of: action)
  }

  /// "Boost" or "Clear Boost", "Avoid" or "Clear Avoid".
  func ratingTitle(_ action: Action, on target: MenuTarget) -> String {
    let name = action == .boost ? "Boost" : "Avoid"
    return isSet(action, on: target) ? "Clear \(name)" : name
  }

  /// The thumb of Boost or Avoid, filled while it is set.
  func ratingSymbol(_ action: Action, on target: MenuTarget) -> String {
    let symbol = action == .boost ? "hand.thumbsup" : "hand.thumbsdown"
    return isSet(action, on: target) ? symbol + ".fill" : symbol
  }

  /// Whether the target is what plays: the song, or the artist of the song,
  /// as the player's Avoid skip matches it.
  private func isPlaying(_ target: MenuTarget) -> Bool {
    guard !player.isLiveRadio else { return false }
    switch target {
    case .song(let song, _, _): return player.nowPlayingId == song.playbackID
    case .artist(let artist): return NowPlayingTarget.current?.artistId == artist.id
    case .album, .playlist, .radio: return false
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
    case .boost, .avoid:
      guard let current = ownRating(target) else { return nil }
      let value = Self.rating(of: action)
      let rating = current == value ? 0 : value
      // Read before the rating: an Avoid of what plays skips it at once.
      let skips = rating == 1 && isPlaying(target) && player.leavesForAnotherSong
      switch target {
      case .song(let song, _, _): RatingStore.shared.set(rating, playbackID: song.playbackID)
      case .artist(let artist): RatingStore.shared.setArtist(rating, artistId: artist.id)
      case .album, .playlist, .radio: return nil
      }
      switch rating {
      case RatingStore.boost: return "Boosted"
      case RatingStore.avoid: return skips ? "Avoided · skipped" : "Avoided"
      default: return action == .boost ? "Boost cleared" : "Avoid cleared"
      }
    }
  }
}
