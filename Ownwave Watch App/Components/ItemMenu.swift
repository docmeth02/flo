//
//  ItemMenu.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

/// The one hold menu: a header with the item, then its actions (Pin or
/// Unpin for albums and artists, Play Next, Add to Queue, Like or Unlike).
/// The sheet's own close button cancels. It only reports the choice;
/// `.itemMenu` carries it out.
struct ItemMenu: View {
  typealias Action = MenuActions.Action

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
        if target.canQueue {
          row("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward", .playNext)
          row("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward", .addToQueue)
        }
        if target.canLike {
          row(
            isLiked ? "Unlike" : "Like", systemImage: isLiked ? "heart.fill" : "heart",
            tint: isLiked ? .floLiked : .floSecondary, .like)
        }
      }
      .padding(.horizontal, 8)
    }
  }

  private func row(
    _ title: String, systemImage: String, tint: Color = .floLilac, _ action: Action
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
    .buttonStyle(FloTintedButtonStyle(tint: .white, isMenuRow: true))
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
  @ObservedObject private var starStore = StarStore.shared
  @State private var toast: FloToast.Message?

  private var actions: MenuActions {
    MenuActions(player: playerViewModel, pins: pinStore, stars: starStore)
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: $target) { target in
        ItemMenu(
          target: target, tile: tile(target),
          isPinned: actions.isPinned(target),
          isLiked: actions.isLiked(target)
        ) { action in
          self.target = nil
          WKInterfaceDevice.current().play(.click)
          Task {
            if let text = await actions.perform(action, on: target) {
              toast = FloToast.Message(text: text)
            }
          }
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
      .artist
    case .playlist:
      .glyph("music.note.list")
    case .radio:
      .glyph("dot.radiowaves.up.forward", round: true)
    }
  }
}
