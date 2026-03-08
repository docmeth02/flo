//
//  WatchAlbumDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumDetailView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var downloadViewModel: DownloadViewModel

  let album: Album

  @State private var localAlbum: Album?
  @State private var showNowPlaying = false
  @State private var downloaded = false

  private var displayAlbum: Album {
    localAlbum ?? album
  }

  private var isDownloaded: Bool {
    downloaded
  }

  private var isDownloading: Bool {
    downloadViewModel.isDownloading(album.name)
  }

  private var downloadProgress: Double {
    downloadViewModel.getDownloadedTrackProgress(albumName: album.name)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        // Album cover
        WatchAlbumArtView(
          url: albumViewModel.getAlbumCoverArt(id: album.id),
          size: 100,
          albumId: album.id
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))

        // Album info
        Text(album.name)
          .customFont(.caption1)
          .fontWeight(.bold)
          .lineLimit(2)
          .multilineTextAlignment(.center)

        Text(album.albumArtist)
          .customFont(.caption2)
          .foregroundColor(.secondary)
          .lineLimit(1)

        if album.minYear > 0 {
          Text("\(String(album.minYear))")
            .customFont(.caption2)
            .foregroundColor(.secondary)
        }

        // Play/Shuffle buttons
        HStack(spacing: 12) {
          Button(action: {
            playerViewModel.playItem(item: displayAlbum, isFromLocal: isDownloaded)
            showNowPlaying = true
          }) {
            Label("Play", systemImage: "play.fill")
              .customFont(.caption2)
          }

          Button(action: {
            playerViewModel.shuffleItem(item: displayAlbum, isFromLocal: isDownloaded)
            showNowPlaying = true
          }) {
            Label("Shuffle", systemImage: "shuffle")
              .customFont(.caption2)
          }
        }
        .padding(.vertical, 4)

        Divider()

        // Track list
        ForEach(Array(displayAlbum.songs.enumerated()), id: \.element.id) { index, song in
          let isCurrentlyPlaying =
            playerViewModel.hasNowPlaying()
            && playerViewModel.nowPlaying.id == (song.mediaFileId.isEmpty ? song.id : song.mediaFileId)

          TrackRowView(
            trackNumber: song.trackNumber,
            title: song.title,
            artist: song.artist,
            isPlaying: isCurrentlyPlaying
          ) {
            playerViewModel.playBySong(idx: index, item: displayAlbum, isFromLocal: isDownloaded)
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
                downloadViewModel.cancelCurrentAlbumDownload(albumName: album.name)
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
            albumViewModel.removeDownloadedAlbum(album: album)
            downloaded = false
          }) {
            Label("Remove Download", systemImage: "trash")
              .customFont(.caption2)
          }
          .foregroundColor(.red)
          .padding(.vertical, 4)
        } else {
          Button(action: {
            albumViewModel.downloadAlbum(displayAlbum)
            downloadViewModel.addItem(displayAlbum)
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
    .navigationTitle(album.name)
    .onAppear {
      loadAlbumDetail()
      downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: album.id)
    }
    .onReceive(downloadViewModel.$downloadWatcher) { newValue in
      if newValue {
        downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: album.id)
        downloadViewModel.downloadWatcher = false
      }
    }
  }

  private func loadAlbumDetail() {
    albumViewModel.setActiveAlbum(album: album)

    // Observe changes from the view model
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
      self.localAlbum = albumViewModel.album
    }
  }
}
