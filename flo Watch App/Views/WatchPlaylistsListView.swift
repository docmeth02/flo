//
//  WatchPlaylistsListView.swift
//  flo Watch App
//

import SwiftUI

struct WatchPlaylistsListView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel

  var body: some View {
    LibraryList(
      title: "Playlists", state: albumViewModel.state(.playlists),
      isEmpty: albumViewModel.playlists.isEmpty,
      empty: .empty(
        systemImage: "music.note.list", tint: .floLavender, title: "No playlists",
        message: "Playlists on your Navidrome server show up here."),
      refresh: albumViewModel.refreshPlaylists
    ) {
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
    .onAppear {
      albumViewModel.getPlaylists()
    }
  }
}
