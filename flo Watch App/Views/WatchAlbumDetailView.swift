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
  @State private var downloadedIds: Set<String> = []

  private var displayAlbum: Album {
    localAlbum ?? album
  }

  private var isDownloaded: Bool {
    downloaded
  }

  // From the downloaded records, so it is right as soon as a download ends.
  private var missingTrackCount: Int {
    displayAlbum.songs.filter {
      !downloadedIds.contains($0.mediaFileId.isEmpty ? $0.id : $0.mediaFileId)
    }.count
  }

  private var isDownloading: Bool {
    downloadViewModel.isDownloading(collectionId: album.id)
  }

  private var downloadProgress: Double {
    downloadViewModel.getDownloadedTrackProgress(collectionId: album.id)
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
            showNowPlaying = playerViewModel.playItem(item: displayAlbum, isFromLocal: isDownloaded)
          }) {
            Label("Play", systemImage: "play.fill")
              .customFont(.caption2)
          }

          Button(action: {
            showNowPlaying = playerViewModel.shuffleItem(
              item: displayAlbum, isFromLocal: isDownloaded)
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
            showNowPlaying = playerViewModel.playBySong(
              idx: index, item: displayAlbum, isFromLocal: isDownloaded)
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
                downloadViewModel.cancelCurrentAlbumDownload(collectionId: album.id)
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
              downloadCollection()
            }) {
              Label("Download \(missingTrackCount) missing", systemImage: "arrow.down.circle")
                .customFont(.caption2)
            }
            .padding(.vertical, 4)
          }

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
            downloadCollection()
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
      refreshDownloadState()
    }
    .onReceive(downloadViewModel.$downloadWatcher) { newValue in
      if newValue {
        refreshDownloadState()
        downloadViewModel.downloadWatcher = false
      }
    }
    .onReceive(albumViewModel.$album) { updated in
      if updated.id == album.id {
        localAlbum = updated
      }
    }
  }

  private func loadAlbumDetail() {
    albumViewModel.setActiveAlbum(album: album)
  }

  private func refreshDownloadState() {
    downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: album.id)
    downloadedIds = AlbumService.shared.downloadedMediaFileIds(collectionId: album.id)
  }

  /// Downloaded playlists open here from Downloads; they keep playlist
  /// semantics (playlist folder, media ids) when missing tracks are fetched.
  private func downloadCollection() {
    if AlbumService.shared.isPlaylistDownload(id: album.id) {
      downloadViewModel.addItem(displayAlbum, isFromPlaylist: true)
    } else {
      albumViewModel.downloadAlbum(displayAlbum)
      downloadViewModel.addItem(displayAlbum)
    }
  }
}
