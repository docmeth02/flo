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
  @State private var downloadedIds: Set<String> = []

  private var isDownloaded: Bool {
    downloaded
  }

  // From the downloaded records, so it is right as soon as a download ends.
  private var missingTrackCount: Int {
    displayPlaylist.songs.filter {
      !downloadedIds.contains($0.mediaFileId.isEmpty ? $0.id : $0.mediaFileId)
    }.count
  }

  private var isDownloading: Bool {
    downloadViewModel.isDownloading(collectionId: playlist.id)
  }

  private var downloadProgress: Double {
    downloadViewModel.getDownloadedTrackProgress(collectionId: playlist.id)
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
            showNowPlaying = playerViewModel.playItem(
              item: playablePlaylist, isFromLocal: isDownloaded)
          }) {
            Label("Play", systemImage: "play.fill")
              .customFont(.caption2)
          }

          Button(action: {
            let playablePlaylist = Album(from: displayPlaylist)
            showNowPlaying = playerViewModel.shuffleItem(
              item: playablePlaylist, isFromLocal: isDownloaded)
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
            showNowPlaying = playerViewModel.playBySong(
              idx: index, item: playablePlaylist, isFromLocal: isDownloaded)
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
                downloadViewModel.cancelCurrentAlbumDownload(collectionId: playlist.id)
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
          // An interrupted download leaves some tracks behind; offer the rest.
          if missingTrackCount > 0 {
            Button(action: {
              let playablePlaylist = Album(from: displayPlaylist)
              albumViewModel.downloadPlaylist(displayPlaylist)
              downloadViewModel.addItem(playablePlaylist, isFromPlaylist: true)
            }) {
              Label("Download \(missingTrackCount) missing", systemImage: "arrow.down.circle")
                .customFont(.caption2)
            }
            .padding(.vertical, 4)
          }

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
      refreshDownloadState()
    }
    .onReceive(downloadViewModel.$downloadWatcher) { newValue in
      if newValue {
        refreshDownloadState()
        downloadViewModel.downloadWatcher = false
      }
    }
  }

  private func refreshDownloadState() {
    downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: playlist.id)
    downloadedIds = AlbumService.shared.downloadedMediaFileIds(collectionId: playlist.id)
  }
}
