//
//  WatchAlbumsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  private var placeholder: StateView.Kind {
    if albumViewModel.isLoading { return .loading }
    if albumViewModel.error != nil {
      return .error(retry: { Task { await albumViewModel.refreshAlbums() } })
    }
    return .empty(
      systemImage: "square.stack", tint: .floLavender, title: "No albums",
      message: "Albums on your Navidrome server show up here.")
  }

  var body: some View {
    Group {
      if albumViewModel.albums.isEmpty {
        LibraryPlaceholder(kind: placeholder)
      } else {
        List {
          ForEach(albumViewModel.albums) { album in
            NavigationLink(destination: WatchAlbumDetailView(album: album)) {
              CoverRow(
                coverURL: albumViewModel.getAlbumCoverArt(id: album.id),
                albumId: album.id,
                title: album.name,
                subtitle: album.albumArtist)
            }
            .floRow()
          }
        }
      }
    }
    .navigationTitle("Albums")
    .refreshable {
      await albumViewModel.refreshAlbums()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if albumViewModel.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await albumViewModel.refreshAlbums() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
    .onAppear {
      albumViewModel.fetchAlbums()
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
