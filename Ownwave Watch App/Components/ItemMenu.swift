//
//  ItemMenu.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

/// The one hold menu: a header with the item, a row of tiles (Play Next,
/// Queue, then Pin, or Like for a song), then the rest as a list (Download
/// for an album or playlist not on the watch, Like, a station's Pin). The
/// sheet's own close button cancels. It only reports the choice;
/// `.itemMenu` carries it out.
struct ItemMenu: View {
  enum Choice: Hashable {
    case action(MenuActions.Action)
    /// Not a shared action: each app downloads through its own session.
    case download
  }

  let target: MenuTarget
  /// Nil for an item that cannot be pinned.
  let isPinned: Bool?
  let isLiked: Bool
  let canDownload: Bool
  let onSelect: (Choice) -> Void

  private var tiles: [Choice] {
    guard target.canQueue else { return [] }
    return [.action(.playNext), .action(.addToQueue), .action(isPinned == nil ? .like : .pin)]
  }

  private var listed: [Choice] {
    var choices: [Choice] = canDownload ? [.download] : []
    if !target.canQueue, isPinned != nil { choices.append(.action(.pin)) }
    if target.canLike, isPinned != nil { choices.append(.action(.like)) }
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
                title: look.title, systemImage: look.systemImage, tint: look.tint
              ) { onSelect(choice) }
            })
        }
      }
      .padding(.horizontal, 8)
    }
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
      isLiked ? ("Unlike", "heart.fill", .floLiked) : ("Like", "heart", .floLiked)
    case .download:
      ("Download", "arrow.down.circle", .floLilac)
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
    IconRowLabel(
      title: row.title, detail: row.detail, systemImage: row.systemImage, tint: row.tint,
      label: row.label
    )
    .lineLimit(1)
    .minimumScaleFactor(0.8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, Self.padding)
    .padding(.vertical, 4)
    .frame(minHeight: FloLayout.rowHeight)
    .contentShape(Rectangle())
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

  @EnvironmentObject private var playerViewModel: PlayerViewModel
  @EnvironmentObject private var pinStore: PinStore
  @EnvironmentObject private var downloads: DownloadSession
  @ObservedObject private var starStore = StarStore.shared
  @State private var toast: FloToast.Message?

  private var actions: MenuActions {
    MenuActions(player: playerViewModel, pins: pinStore, stars: starStore)
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: $target) { target in
        ItemMenu(
          target: target,
          isPinned: actions.isPinned(target),
          isLiked: actions.isLiked(target),
          canDownload: canDownload(target)
        ) { choice in
          self.target = nil
          WKInterfaceDevice.current().play(.click)
          Task {
            let text: String?
            switch choice {
            case .action(let action): text = await actions.perform(action, on: target)
            case .download: text = await download(target)
            }
            if let text { toast = FloToast.Message(text: text) }
          }
        }
      }
      .floToast($toast)
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
    guard let id = collection(target)?.id else { return false }
    return !downloads.isDownloading(collectionId: id)
      && !PhoneLink.shared.isReceiving(collectionId: id)
      && !DownloadStore.checkIfAlbumDownloaded(albumID: id)
  }

  /// As the screen's Download, with the songs asked first: a list row
  /// carries none.
  private func download(_ target: MenuTarget) async -> String? {
    guard let collection = collection(target) else { return nil }
    switch await CollectionDownload.prepare(collection) {
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
