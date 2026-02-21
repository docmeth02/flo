//
//  WatchPlaylistDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchPlaylistDetailView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel

  let playlist: Playlist

  @State private var showNowPlaying = false

  private var isDownloaded: Bool {
    AlbumService.shared.checkIfAlbumDownloaded(albumID: playlist.id)
  }

  private var asAlbum: Album {
    Album(from: playlist)
  }

  private var displayPlaylist: Playlist {
    albumViewModel.playlist.id == playlist.id ? albumViewModel.playlist : playlist
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        // Playlist icon
        Image(systemName: "music.note.list")
          .font(.system(size: 40))
          .foregroundColor(.accentColor)
          .frame(width: 80, height: 80)
          .background(Color.secondary.opacity(0.15))
          .clipShape(RoundedRectangle(cornerRadius: 10))

        Text(playlist.name)
          .customFont(.caption1)
          .fontWeight(.bold)
          .lineLimit(2)
          .multilineTextAlignment(.center)

        if !playlist.comment.isEmpty {
          Text(playlist.comment)
            .customFont(.caption2)
            .foregroundColor(.secondary)
            .lineLimit(1)
        }

        // Play/Shuffle buttons
        HStack(spacing: 12) {
          Button(action: {
            let playablePlaylist = Album(from: displayPlaylist)
            playerViewModel.playItem(item: playablePlaylist, isFromLocal: isDownloaded)
            showNowPlaying = true
          }) {
            Label("Play", systemImage: "play.fill")
              .customFont(.caption2)
          }

          Button(action: {
            let playablePlaylist = Album(from: displayPlaylist)
            playerViewModel.shuffleItem(item: playablePlaylist, isFromLocal: isDownloaded)
            showNowPlaying = true
          }) {
            Label("Shuffle", systemImage: "shuffle")
              .customFont(.caption2)
          }
        }
        .padding(.vertical, 4)

        Divider()

        // Track list
        ForEach(Array(displayPlaylist.songs.enumerated()), id: \.element.id) { index, song in
          let songId = song.mediaFileId.isEmpty ? song.id : song.mediaFileId
          let isCurrentlyPlaying =
            playerViewModel.hasNowPlaying() && playerViewModel.nowPlaying.id == songId

          TrackRowView(
            trackNumber: index + 1,
            title: song.title,
            artist: song.artist,
            isPlaying: isCurrentlyPlaying
          ) {
            let playablePlaylist = Album(from: displayPlaylist)
            playerViewModel.playBySong(
              idx: index, item: playablePlaylist, isFromLocal: isDownloaded)
            showNowPlaying = true
          }
          .padding(.vertical, 2)
        }
      }
      .padding(.horizontal)
    }
    .navigationDestination(isPresented: $showNowPlaying) {
      WatchNowPlayingView()
    }
    .navigationTitle(playlist.name)
    .onAppear {
      albumViewModel.setActivePlaylist(playlist: playlist)
    }
  }
}
