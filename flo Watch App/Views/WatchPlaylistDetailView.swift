//
//  WatchPlaylistDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchPlaylistDetailView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloadViewModel: DownloadViewModel

  let playlist: Playlist

  @State private var showNowPlaying = false
  @State private var downloaded = false

  private var isDownloaded: Bool {
    downloaded
  }

  private var isDownloading: Bool {
    downloadViewModel.isDownloading(playlist.name)
  }

  private var downloadProgress: Double {
    downloadViewModel.getDownloadedTrackProgress(albumName: playlist.name)
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

        Divider()

        // Download button
        if isDownloading {
          VStack(spacing: 4) {
            ProgressView(value: downloadProgress, total: 100)
              .tint(.accentColor)
            HStack {
              Text("\(Int(downloadProgress))%")
                .customFont(.caption2)
                .foregroundColor(.secondary)
              Spacer()
              Button(action: {
                downloadViewModel.cancelCurrentAlbumDownload(albumName: playlist.name)
              }) {
                Label("Cancel", systemImage: "xmark.circle")
                  .customFont(.caption2)
              }
              .buttonStyle(.plain)
              .foregroundColor(.red)
            }
          }
          .padding(.vertical, 4)
        } else if isDownloaded {
          Button(action: {
            albumViewModel.removeDownloadedPlaylist(playlist: playlist)
            downloaded = false
          }) {
            Label("Remove Download", systemImage: "trash")
              .customFont(.caption2)
          }
          .foregroundColor(.red)
          .padding(.vertical, 4)
        } else {
          Button(action: {
            let playablePlaylist = Album(from: displayPlaylist)
            albumViewModel.downloadPlaylist(displayPlaylist)
            downloadViewModel.addItem(playablePlaylist, isFromPlaylist: true)
          }) {
            Label("Download", systemImage: "arrow.down.circle")
              .customFont(.caption2)
          }
          .padding(.vertical, 4)
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
      downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: playlist.id)
    }
    .onReceive(downloadViewModel.$downloadWatcher) { newValue in
      if newValue {
        downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: playlist.id)
        downloadViewModel.downloadWatcher = false
      }
    }
  }
}
