//
//  ItemMenu.swift
//  flo Watch App
//

import SwiftUI

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
}

/// The one hold menu: a header with the item, then its actions (Pin or
/// Unpin for albums and artists, Play Next, Add to Queue, Like or Unlike)
/// and Cancel.
struct ItemMenu: View {
  let target: MenuTarget

  var body: some View {
    EmptyView()
  }
}

extension View {
  /// Presents the hold menu for `target` while it is set and shows the
  /// action's result as a toast on this view.
  func itemMenu(_ target: Binding<MenuTarget?>) -> some View {
    self
  }
}
