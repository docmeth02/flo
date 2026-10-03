//
//  WatchAlbumsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    LibraryList(
      title: "Albums", state: albumViewModel.state(.albums),
      isEmpty: albumViewModel.albums.isEmpty,
      empty: .empty(
        systemImage: "square.stack", tint: .floLavender, title: "No albums",
        message: "Albums on your Navidrome server show up here."),
      refresh: albumViewModel.refreshAlbums
    ) {
      ForEach(albumViewModel.albums) { album in
        NavigationLink(destination: WatchAlbumDetailView(album: album)) {
          CoverRow(
            tile: .cover(url: albumViewModel.getAlbumCoverArt(id: album.id), albumId: album.id),
            title: album.name,
            subtitle: album.albumArtist)
        }
        .floRow()
      }
    }
    .onAppear {
      albumViewModel.fetchAlbums()
    }
  }
}

/// A library list: its rows, or the placeholder while it has none, with
/// pull-to-refresh and a refresh button that shows the request under way.
struct LibraryList<Rows: View>: View {
  let title: String
  let state: AlbumViewModel.ListState
  let isEmpty: Bool
  let empty: StateView.Kind
  let refresh: () async -> Void
  @ViewBuilder var rows: Rows

  private var placeholder: StateView.Kind {
    if state.isLoading { return .loading }
    if state.failed { return .error(retry: { Task { await refresh() } }) }
    return empty
  }

  var body: some View {
    Group {
      if isEmpty {
        LibraryPlaceholder(kind: placeholder)
      } else {
        List { rows }
      }
    }
    .navigationTitle(title)
    .refreshable {
      await refresh()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if state.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await refresh() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
  }
}

/// What a library list shows instead of its rows while it has none: the
/// skeleton rows at the top, a message centered on the screen.
struct LibraryPlaceholder: View {
  let kind: StateView.Kind

  private var isLoading: Bool {
    if case .loading = kind { return true }
    return false
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        StateView(kind: kind)
          .padding(.horizontal, 8)
          .frame(
            maxWidth: .infinity, minHeight: proxy.size.height,
            alignment: isLoading ? .top : .center)
      }
    }
  }
}
