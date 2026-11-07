//
//  ItemMenu.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

/// The one hold menu: a header with the item, a row of tiles (Play Next,
/// Queue, then Pin, or Like for a song), then the rest as a list (Download
/// for an album or playlist not on the watch, Like, a station's Pin, Go to
/// Album and Go to Artist, Boost and Avoid for a song or artist). The
/// sheet's own close button cancels. It only reports the choice;
/// `.itemMenu` carries it out.
struct ItemMenu: View {
  enum Choice: Hashable {
    case action(MenuActions.Action)
    /// Not a shared action: each app downloads through its own session.
    case download
    /// The screen behind the menu opens these.
    case goToAlbum, goToArtist

    var opens: Bool { self == .goToAlbum || self == .goToArtist }
  }

  let target: MenuTarget
  let actions: MenuActions
  let canDownload: Bool
  /// Go to Album and Go to Artist, where the screen behind can open them.
  let goTo: [Choice]
  let onSelect: (Choice) -> Void

  /// Nil for an item that cannot be pinned.
  private var isPinned: Bool? { actions.isPinned(target) }

  private var tiles: [Choice] {
    guard target.canQueue else { return [] }
    return [.action(.playNext), .action(.addToQueue), .action(isPinned == nil ? .like : .pin)]
  }

  private var listed: [Choice] {
    var choices: [Choice] = canDownload ? [.download] : []
    if !target.canQueue, isPinned != nil { choices.append(.action(.pin)) }
    if target.canLike, isPinned != nil { choices.append(.action(.like)) }
    choices += goTo
    if target.canRate { choices += [.action(.boost), .action(.avoid)] }
    return choices
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 6) {
        CoverRow(
          tile: CoverTile(target), title: target.title, subtitle: target.subtitle, titleLineLimit: 2
        )
        .padding(.horizontal, 4)
        if !tiles.isEmpty {
          HStack(spacing: 5) {
            ForEach(tiles, id: \.self) { choice in
              let look = look(choice)
              Button {
                onSelect(choice)
              } label: {
                Label {
                  Text(look.title).minimumScaleFactor(0.7)
                } icon: {
                  Image(systemName: look.systemImage).foregroundStyle(look.tint)
                }
                // The tile's margins are made for two a row; three need
                // the room for "Play Next".
                .padding(.horizontal, -6)
              }
              .buttonStyle(FloTileButtonStyle(alignment: .center))
            }
          }
        }
        if !listed.isEmpty {
          PlatterRows(
            listed.map { choice in
              let look = look(choice)
              return PlatterRows.Row(
                title: look.title, systemImage: look.systemImage, tint: look.tint,
                opens: choice.opens
              ) { onSelect(choice) }
            })
        }
      }
      .padding(.horizontal, 8)
    }
    #if DEBUG
      .debugMenuScroll()
    #endif
    .presentationBackground(Color.black)
  }

  private func look(_ choice: Choice) -> (title: String, systemImage: String, tint: Color) {
    switch choice {
    case .action(.pin):
      isPinned == true ? ("Unpin", "pin.slash", .floLilac) : ("Pin", "pin", .floLilac)
    case .action(.playNext):
      ("Play Next", "text.line.first.and.arrowtriangle.forward", .floLilac)
    case .action(.addToQueue):
      ("Queue", "text.line.last.and.arrowtriangle.forward", .floLilac)
    case .action(.like):
      actions.isLiked(target)
        ? ("Unlike", "heart.fill", .floLiked) : ("Like", "heart", .floLiked)
    case .action(.boost):
      (
        actions.ratingTitle(.boost, on: target),
        actions.ownRating(target) == 5 ? "hand.thumbsup.fill" : "hand.thumbsup", .floLilac
      )
    case .action(.avoid):
      (
        actions.ratingTitle(.avoid, on: target),
        actions.ownRating(target) == 1 ? "hand.thumbsdown.fill" : "hand.thumbsdown", .floLilac
      )
    case .download:
      ("Download", "arrow.down.circle", .floLilac)
    case .goToAlbum:
      ("Go to Album", Glyph.album, .floLilac)
    case .goToArtist:
      ("Go to Artist", Glyph.artist, .floLilac)
    }
  }
}

/// Rows on one platter with hairlines between them: the hold menu's list and
/// the download control.
struct PlatterRows: View {
  struct Row {
    let title: String
    var detail = ""
    let systemImage: String
    var tint: Color = .floLilac
    var label: Color = .floText
    /// A chevron says the row opens another screen.
    var opens = false
    /// Nil for a line that only tells a state.
    var action: (() -> Void)?
  }

  private static let padding: CGFloat = 10

  let rows: [Row]

  init(_ rows: [Row]) {
    self.rows = rows
  }

  var body: some View {
    PlatterStack(rows, hairlineInset: Self.padding + IconRowLabel.titleInset) { _, row in
      if let action = row.action {
        Button(action: action) { content(row) }
          .buttonStyle(.plain)
      } else {
        content(row)
      }
    }
  }

  private func content(_ row: Row) -> some View {
    HStack(spacing: 4) {
      IconRowLabel(
        title: row.title, detail: row.detail, systemImage: row.systemImage, tint: row.tint,
        label: row.label
      )
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      if row.opens {
        Spacer(minLength: 4)
        Chevron()
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Self.padding)
    .padding(.vertical, 4)
    .frame(minHeight: FloLayout.rowHeight)
    .contentShape(Rectangle())
  }
}

extension View {
  /// Presents the hold menu for `target` while it is set and shows the
  /// action's result as a toast on this view. Go to Album and Go to Artist
  /// are offered where the screen passes the state of its own
  /// `navigationDestination`, so they push onto the stack rather than
  /// replace a screen; `showing` is the album or artist this screen shows,
  /// which those rows leave out.
  func itemMenu(
    _ target: Binding<MenuTarget?>, showing: String? = nil,
    openedAlbum: Binding<Album?>? = nil, openedArtist: Binding<Artist?>? = nil
  ) -> some View {
    modifier(
      ItemMenuPresenter(
        target: target, showing: showing, openedAlbum: openedAlbum, openedArtist: openedArtist))
  }
}

/// Runs the menu's actions here rather than in the sheet, so the sheet needs
/// no environment objects and the toast outlives it.
private struct ItemMenuPresenter: ViewModifier {
  @Binding var target: MenuTarget?
  let showing: String?
  let openedAlbum: Binding<Album?>?
  let openedArtist: Binding<Artist?>?

  @EnvironmentObject private var playerViewModel: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @EnvironmentObject private var pinStore: PinStore
  @EnvironmentObject private var downloads: DownloadSession
  @ObservedObject private var starStore = StarStore.shared
  @State private var toast: FloToast.Message?
  /// The presented album or playlist when none of it is on the watch,
  /// looked up once per menu rather than on every render.
  @State private var absentCollection: String?

  private var actions: MenuActions {
    MenuActions(player: playerViewModel, pins: pinStore, stars: starStore)
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: $target) { target in
        ItemMenu(
          target: target, actions: actions, canDownload: canDownload(target),
          goTo: goTo(target)
        ) { select($0, on: target) }
        .task(id: target.id) {
          let id = collection(target)?.id
          absentCollection = id.flatMap {
            DownloadStore.checkIfAlbumDownloaded(albumID: $0) ? nil : $0
          }
        }
      }
      .floToast($toast)
      #if DEBUG
        .modifier(DebugMenuRunner(target: $target, goTo: goTo, select: select))
      #endif
  }

  private func select(_ choice: ItemMenu.Choice, on target: MenuTarget) {
    self.target = nil
    WKInterfaceDevice.current().play(.click)
    Task {
      let text: String?
      switch choice {
      case .action(let action): text = await actions.perform(action, on: target)
      case .download: text = await download(target)
      case .goToAlbum, .goToArtist: text = await go(choice, from: target)
      }
      if let text {
        debugLog("menu toast: \(text)")
        toast = FloToast.Message(text: text)
      }
    }
  }

  /// Go to Album for a song, Go to Artist for a song or album, unless it
  /// leads to what this screen shows.
  private func goTo(_ target: MenuTarget) -> [ItemMenu.Choice] {
    let artistIds: [String?]
    var choices: [ItemMenu.Choice] = []
    switch target {
    case .song(let song, _, _):
      if openedAlbum != nil, !song.albumId.isEmpty, song.albumId != showing {
        choices.append(.goToAlbum)
      }
      artistIds = [song.artistId, song.albumArtistId]
    case .album(let album):
      artistIds = [album.artistId, album.albumArtistId]
    case .artist, .playlist, .radio:
      return []
    }
    // The id `artistToOpen` takes first.
    let artistId = artistIds.compactMap { $0 }.first { !$0.isEmpty }
    if openedArtist != nil, artistId == nil || artistId != showing {
      choices.append(.goToArtist)
    }
    return choices
  }

  private func go(_ choice: ItemMenu.Choice, from target: MenuTarget) async -> String? {
    switch (choice, target) {
    case (.goToArtist, _):
      guard let artist = await target.artistToOpen() else { return "Artist not in your library" }
      debugLog("menu opens artist \(artist.id) \(artist.name)")
      openedArtist?.wrappedValue = artist
    case (.goToAlbum, .song(let song, _, _)):
      let album = await albumViewModel.album(
        id: song.albumId, name: song.albumName, artist: song.artist)
      debugLog("menu opens album \(album.id) \(album.name)")
      openedAlbum?.wrappedValue = album
    default: break
    }
    return nil
  }

  /// The album or playlist that Download would take.
  private func collection(_ target: MenuTarget) -> Album? {
    switch target {
    case .album(let album): album
    case .playlist(let playlist): Album(from: playlist)
    case .song, .artist, .radio: nil
    }
  }

  /// Offered while nothing of it is on the watch or on its way from the
  /// iPhone: a partly downloaded one gets its missing songs on its own
  /// screen.
  private func canDownload(_ target: MenuTarget) -> Bool {
    guard let id = collection(target)?.id, id == absentCollection else { return false }
    return !downloads.isDownloading(collectionId: id)
      && !PhoneLink.shared.isReceiving(collectionId: id)
  }

  /// As the screen's Download, with the songs asked first: a list row
  /// carries none.
  private func download(_ target: MenuTarget) async -> String? {
    guard let collection = collection(target) else { return nil }
    switch await CollectionDownload.prepare(collection) {
    case .ready where PhoneLink.shared.isReceiving(collectionId: collection.id):
      // The iPhone started sending it while the songs were asked.
      return nil
    case .ready(let album):
      if case .playlist(var playlist) = target {
        playlist.songs = album.songs
        downloads.enqueue(playlist)
      } else {
        downloads.enqueue(album)
      }
      return "Downloading"
    case .unavailable: return "Not available offline"
    case .downloaded: return "Already on this watch"
    case .accountChanged: return nil
    }
  }
}
