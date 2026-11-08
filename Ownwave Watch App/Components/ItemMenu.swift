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
    /// Not a shared action: the phone's menu has its own Download, both
    /// through `CollectionDownload`.
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
              .buttonStyle(TileButtonStyle(alignment: .center))
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
      isPinned == true ? ("Unpin", "pin.slash", Dusk.fill) : ("Pin", "pin", Dusk.fill)
    case .action(.playNext):
      ("Play Next", "text.line.first.and.arrowtriangle.forward", Dusk.fill)
    case .action(.addToQueue):
      ("Queue", "text.line.last.and.arrowtriangle.forward", Dusk.fill)
    case .action(.like):
      actions.isLiked(target)
        ? ("Unlike", "heart.fill", .liked) : ("Like", "heart", .liked)
    case .action(.boost):
      (actions.ratingTitle(.boost, on: target), actions.ratingSymbol(.boost, on: target), Dusk.fill)
    case .action(.avoid):
      (actions.ratingTitle(.avoid, on: target), actions.ratingSymbol(.avoid, on: target), Dusk.fill)
    case .download:
      ("Download", "arrow.down.circle", Dusk.fill)
    case .goToAlbum:
      ("Go to Album", Glyph.album, Dusk.fill)
    case .goToArtist:
      ("Go to Artist", Glyph.artist, Dusk.fill)
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
    var tint: Color = Dusk.fill
    var label: Color = Dusk.text
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
    .frame(minHeight: WatchLayout.rowHeight)
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
  // Boost and Avoid name what a tap does, so their titles follow the store.
  @ObservedObject private var ratingStore = RatingStore.shared
  @State private var toast: Toast.Message?
  /// The presented album or playlist when none of it is on the watch,
  /// looked up once per menu rather than on every render.
  @State private var absentCollection: String?
  @State private var pendingGo: (choice: ItemMenu.Choice, target: MenuTarget)?

  private var actions: MenuActions {
    MenuActions(player: playerViewModel, pins: pinStore, stars: starStore)
  }

  func body(content: Content) -> some View {
    content
      // A push under a closing sheet can be dropped, so Go to runs once it
      // is gone.
      .sheet(item: $target, onDismiss: goPending) { target in
        ItemMenu(
          target: target, actions: actions, canDownload: canDownload(target),
          goTo: goTo(target)
        ) { select($0, on: target) }
        // A download that saves its first song meanwhile makes it present.
        .onReceive(downloads.downloadFinished) { id in
          if id == collection(target)?.id { lookUpDownload(target) }
        }
      }
      .onChange(of: target?.id, initial: true) { lookUpDownload(target) }
      .toast($toast)
      #if DEBUG
        .modifier(DebugMenuRunner(target: $target, goTo: goTo, select: select))
      #endif
  }

  private func select(_ choice: ItemMenu.Choice, on target: MenuTarget) {
    // Only from an open menu: the debug runner's delayed choice may come
    // after it closed.
    guard self.target?.id == target.id else { return }
    self.target = nil
    WKInterfaceDevice.current().play(.click)
    let perform: () async -> String?
    switch choice {
    case .action(let action): perform = { await actions.perform(action, on: target) }
    case .download: perform = { await CollectionDownload.startFromWatch(target) }
    case .goToAlbum, .goToArtist:
      // The sheet's dismissal pushes it.
      pendingGo = (choice, target)
      return
    }
    Task {
      if let text = await perform() {
        debugLog("menu toast: \(text)")
        toast = Toast.Message(text: text)
      }
    }
  }

  /// Go to Album for a song, Go to Artist for a song or album, unless it
  /// leads to what this screen shows.
  private func goTo(_ target: MenuTarget) -> [ItemMenu.Choice] {
    var choices: [ItemMenu.Choice] = []
    if openedAlbum != nil, target.offersAlbum(except: showing) { choices.append(.goToAlbum) }
    if openedArtist != nil, target.offersArtist(except: showing) { choices.append(.goToArtist) }
    return choices
  }

  private func go(_ choice: ItemMenu.Choice, from target: MenuTarget) async -> String? {
    switch (choice, target) {
    case (.goToArtist, _):
      guard let artist = await target.artistToOpen() else { return MenuActions.artistNotFound }
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

  private func goPending() {
    guard let (choice, target) = pendingGo else { return }
    pendingGo = nil
    Task {
      if let text = await go(choice, from: target) { toast = Toast.Message(text: text) }
    }
  }

  private func lookUpDownload(_ target: MenuTarget?) {
    absentCollection = target.flatMap(collection).flatMap {
      DownloadStore.checkIfAlbumDownloaded(albumID: $0.id) ? nil : $0.id
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
}

extension CollectionDownload {
  /// The watch's Download of an album or playlist, from its hold menu and
  /// its screen, and what to say about it; nil for nothing. One the iPhone
  /// started sending while the songs were asked is left to it.
  @MainActor static func startFromWatch(_ target: MenuTarget) async -> String? {
    let isReceiving = PhoneLink.shared.isReceiving(collectionId:)
    let outcome: Outcome
    switch target {
    case .album(let album): outcome = await start(album, underway: isReceiving)
    case .playlist(let playlist): outcome = await start(playlist, underway: isReceiving)
    case .song, .artist, .radio: return nil
    }
    switch outcome {
    case .ready: return "Downloading"
    case .unavailable: return "Not available offline"
    case .downloaded: return "Already on this watch"
    case .accountChanged, .underway: return nil
    }
  }
}
