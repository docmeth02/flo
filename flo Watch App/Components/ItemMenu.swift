//
//  ItemMenu.swift
//  flo Watch App
//

import SwiftUI
import WatchKit

/// What a hold on a row opens the menu for. Songs carry the collection they
/// were listed in, which the queue keeps as their origin.
enum MenuTarget: Identifiable {
  case song(Song, context: String, isFromPlaylist: Bool)
  case album(Album)
  case artist(Artist)

  var id: String {
    switch self {
    case .song(let song, _, _): "song-" + song.playbackID
    case .album(let album): "album-" + album.id
    case .artist(let artist): "artist-" + artist.id
    }
  }

  fileprivate var title: String {
    switch self {
    case .song(let song, _, _): song.title
    case .album(let album): album.name
    case .artist(let artist): artist.name
    }
  }

  fileprivate var subtitle: String {
    switch self {
    case .song(let song, _, _): song.artist
    case .album(let album): album.albumArtist
    case .artist(let artist): artist.albumCount > 0 ? counted(artist.albumCount, "album") : ""
    }
  }

  /// Songs cannot be pinned.
  fileprivate var pin: (id: String, kind: PinStore.Kind)? {
    switch self {
    case .song: nil
    case .album(let album): (album.id, .album)
    case .artist(let artist): (artist.id, .artist)
    }
  }

  /// What Play Next and Add to Queue put in the queue, in play order, and
  /// the collection the queue names as their origin. Albums and artists come
  /// from the cached library (synced first for an artist when it is empty);
  /// an album missing there from the server, or offline from its download.
  fileprivate func queueSongs(
    serverReachable: Bool
  ) async -> (songs: [Song], context: String, isFromPlaylist: Bool) {
    switch self {
    case .song(let song, let context, let isFromPlaylist):
      return ([song], context, isFromPlaylist)
    case .album(let album):
      var songs = await SmartPlaybackService.shared.loadCachedLibrary().songs
        .filter { $0.albumId == album.id }
      if songs.isEmpty, serverReachable {
        songs = await withCheckedContinuation { continuation in
          AlbumService.shared.getSongFromAlbum(id: album.id) {
            continuation.resume(returning: (try? $0.get()) ?? [])
          }
        }
      }
      if songs.isEmpty {
        // Offline: the tracks on the watch, which may be only some of them.
        // The view context, so on main.
        songs = await MainActor.run { AlbumService.shared.getSongsByAlbumId(albumId: album.id) }
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
      let songs = library.filter { song in
        guard let id = song.artistId, !id.isEmpty else { return song.artist == artist.name }
        return id == artist.id
      }
      return (
        songs.sorted {
          ($0.year ?? 0, $0.albumName, $0.discNumber, $0.trackNumber)
            < ($1.year ?? 0, $1.albumName, $1.discNumber, $1.trackNumber)
        },
        artist.name, false
      )
    }
  }
}

/// The one hold menu: a header with the item, then its actions (Pin or
/// Unpin for albums and artists, Play Next, Add to Queue, Like or Unlike).
/// The sheet's own close button cancels. It only reports the choice;
/// `.itemMenu` carries it out.
struct ItemMenu: View {
  enum Action {
    case pin, playNext, addToQueue, like
  }

  let target: MenuTarget
  let tile: CoverRow<EmptyView>.Tile
  /// Nil for an item that cannot be pinned.
  let isPinned: Bool?
  let isLiked: Bool
  let onSelect: (Action) -> Void


  var body: some View {
    ScrollView {
      VStack(spacing: 6) {
        CoverRow(tile: tile, title: target.title, subtitle: target.subtitle)
          .padding(.horizontal, 4)
        if let isPinned {
          row(isPinned ? "Unpin" : "Pin to Top", systemImage: isPinned ? "pin.slash" : "pin", .pin)
        }
        row("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", .playNext)
        row("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward", .addToQueue)
        row(
          isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart",
          tint: isLiked ? .floLiked : .floSecondary, .like)
      }
      .padding(.horizontal, 8)
    }
  }

  private func row(
    _ title: String, systemImage: String, tint: Color = .floLavender, _ action: Action
  ) -> some View {
    Button {
      onSelect(action)
    } label: {
      HStack(spacing: 8) {
        Image(systemName: systemImage)
          .font(.system(size: 17))
          .foregroundStyle(tint)
          .frame(width: 22)
        Text(title)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 16)
    }
    .buttonStyle(FloTintedButtonStyle(tint: .white))
  }
}

extension View {
  /// Presents the hold menu for `target` while it is set and shows the
  /// action's result as a toast on this view.
  func itemMenu(_ target: Binding<MenuTarget?>) -> some View {
    modifier(ItemMenuPresenter(target: target))
  }
}

/// Runs the menu's actions here rather than in the sheet, so the sheet needs
/// no environment objects and the toast outlives it.
private struct ItemMenuPresenter: ViewModifier {
  @Binding var target: MenuTarget?

  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @EnvironmentObject private var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject private var pinStore: PinStore
  @State private var toast: FloToast.Message?

  func body(content: Content) -> some View {
    content
      .sheet(item: $target) { target in
        ItemMenu(
          target: target, tile: tile(target),
          isPinned: target.pin.map { pinStore.isPinned($0.id, $0.kind) },
          isLiked: isLiked(target)
        ) { action in
          self.target = nil
          WKInterfaceDevice.current().play(.click)
          perform(action, on: target)
        }
      }
      .floToast($toast)
  }

  private func tile(_ target: MenuTarget) -> CoverRow<EmptyView>.Tile {
    switch target {
    case .song(let song, _, _):
      .album(song.albumId)
    case .album(let album):
      .album(album.id)
    case .artist:
      .glyph("music.mic", round: true)
    }
  }

  /// Songs ask the player, which knows the heart and the stars confirmed
  /// since the song was listed; albums and artists carry their own.
  private func isLiked(_ target: MenuTarget) -> Bool {
    switch target {
    case .song(let song, _, _):
      playerViewModel.isStarred(song)
    case .album(let album): albumViewModel.isStarred(album)
    case .artist(let artist): albumViewModel.isStarred(artist)
    }
  }

  private func perform(_ action: ItemMenu.Action, on target: MenuTarget) {
    switch action {
    case .pin:
      guard let pin = target.pin else { return }
      pinStore.toggle(pin.id, pin.kind)
      show(pinStore.isPinned(pin.id, pin.kind) ? "Pinned" : "Unpinned")
    case .playNext, .addToQueue:
      let generation = LibraryCacheManager.shared.generation
      let reachable = ConnectivityMonitor.shared.isServerReachable
      Task {
        let (songs, context, isFromPlaylist) = await target.queueSongs(serverReachable: reachable)
        // A logout meanwhile: these are the previous account's songs.
        guard LibraryCacheManager.shared.generation == generation else { return }
        guard !songs.isEmpty else {
          return show(reachable ? "Nothing to queue" : "Not available offline")
        }
        let next = action == .playNext
        let queued =
          next
          ? playerViewModel.playNext(songs, context: context, isFromPlaylist: isFromPlaylist)
          : playerViewModel.appendToQueue(songs, context: context, isFromPlaylist: isFromPlaylist)
        if queued { show(next ? "Playing next" : "Added to queue") }
      }
    case .like:
      let starred = !isLiked(target)
      let done = { (success: Bool) in
        show(success ? (starred ? "Liked" : "Removed from Liked") : "Not available offline")
      }
      switch target {
      case .song(let song, _, _):
        playerViewModel.setStar(starred, song: song, completion: done)
      case .album(let album): albumViewModel.setStar(starred, id: album.id, completion: done)
      case .artist(let artist): albumViewModel.setStar(starred, id: artist.id, completion: done)
      }
    }
  }

  private func show(_ text: String) {
    toast = FloToast.Message(text: text)
  }
}
