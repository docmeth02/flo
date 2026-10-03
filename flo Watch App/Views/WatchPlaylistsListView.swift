//
//  WatchPlaylistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchPlaylistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  private var placeholder: StateView.Kind {
    if albumViewModel.isLoading { return .loading }
    if albumViewModel.error != nil {
      return .error(retry: { Task { await albumViewModel.refreshPlaylists() } })
    }
    return .empty(
      systemImage: "music.note.list", tint: .floLavender, title: "No playlists",
      message: "Playlists on your Navidrome server show up here.")
  }

  var body: some View {
    Group {
      if albumViewModel.playlists.isEmpty {
        LibraryPlaceholder(kind: placeholder)
      } else {
        List {
          ForEach(albumViewModel.playlists) { playlist in
            NavigationLink(destination: WatchPlaylistDetailView(playlist: playlist)) {
              HStack(spacing: 10) {
                Image(systemName: "music.note.list")
                  .font(.system(size: 16))
                  .foregroundStyle(Color.floLavender)
                  .frame(width: 36, height: 36)
                  .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                      .fill(Color.floLavender.opacity(0.18)))
                VStack(alignment: .leading, spacing: 1) {
                  Text(playlist.name)
                    .font(.floRowTitle)
                    .lineLimit(1)
                  if !playlist.comment.isEmpty {
                    Text(playlist.comment)
                      .font(.floMeta)
                      .foregroundStyle(Color.floSecondary)
                      .lineLimit(1)
                  }
                }
              }
              .frame(minHeight: 52)
            }
            .floRow()
          }
        }
      }
    }
    .navigationTitle("Playlists")
    .refreshable {
      await albumViewModel.refreshPlaylists()
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if albumViewModel.isLoading {
          ProgressView()
        } else {
          Button {
            Task { await albumViewModel.refreshPlaylists() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
        }
      }
    }
    .onAppear {
      albumViewModel.getPlaylists()
    }
  }
}
