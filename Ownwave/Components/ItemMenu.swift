//
//  ItemMenu.swift
//  Ownwave
//

import SwiftUI

/// The shared item menu as a long-press context menu, and as the ••• button
/// rows and headers show.
struct ItemMenuItems: View {
  let target: MenuTarget

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var pins: PinStore
  @ObservedObject private var stars = StarStore.shared

  private var actions: MenuActions { MenuActions(player: app.player, pins: pins, stars: stars) }

  var body: some View {
    if let isPinned = actions.isPinned(target) {
      button(isPinned ? "Unpin" : "Pin to Top", isPinned ? "pin.slash" : "pin", .pin)
    }
    if target.canQueue {
      button("Play Next", "text.line.first.and.arrowtriangle.forward", .playNext)
      button("Add to Queue", "text.line.last.and.arrowtriangle.forward", .addToQueue)
    }
    if target.canLike {
      let liked = actions.isLiked(target)
      button(liked ? "Unlike" : "Like", liked ? "heart.slash" : "heart", .like)
    }
    if case .album(let album) = target {
      Button("Download", systemImage: "arrow.down.circle") { app.download(album) }
    }
  }

  private func button(_ title: String, _ systemImage: String, _ action: MenuActions.Action)
    -> some View
  {
    Button(title, systemImage: systemImage) {
      Task {
        if let text = await actions.perform(action, on: target) { app.show(text) }
      }
    }
  }
}

/// The ••• button that opens the item menu.
struct ItemMenuButton: View {
  let target: MenuTarget

  @Environment(\.palette) private var palette

  var body: some View {
    Menu {
      ItemMenuItems(target: target)
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(palette.secondary)
        .frame(width: 36, height: 36)
        .contentShape(Rectangle())
    }
  }
}

extension View {
  /// The item menu on a long press.
  func itemMenu(_ target: MenuTarget) -> some View {
    contextMenu { ItemMenuItems(target: target) }
  }

  /// The toast, `bottom` points above the bottom edge.
  func toastOverlay(_ toast: AppModel.Toast?, bottom: CGFloat) -> some View {
    overlay(alignment: .bottom) {
      if let toast {
        ToastView(toast: toast)
          .padding(.bottom, bottom)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .animation(.snappy, value: toast)
  }
}

/// The toast at the bottom, with Undo when the action can be taken back.
struct ToastView: View {
  let toast: AppModel.Toast

  @EnvironmentObject private var app: AppModel
  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 12) {
      Text(toast.text).font(.rowSubtitle.weight(.medium)).foregroundStyle(palette.text)
      Spacer(minLength: 0)
      if let undo = toast.undo {
        Button("Undo") {
          app.dismissToast()
          undo()
        }
        .font(.rowSubtitle.weight(.semibold))
        .foregroundStyle(palette.accent)
      }
    }
    .padding(.horizontal, 18)
    .frame(height: 50)
    .glassEffect(.regular, in: Capsule())
    .padding(.horizontal, 16)
  }
}
