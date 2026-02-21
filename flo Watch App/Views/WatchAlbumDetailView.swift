//
//  WatchAlbumDetailView.swift
//  flo Watch App
//

import SwiftUI

struct WatchAlbumDetailView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel

  let album: Album

  @State private var localAlbum: Album?
  @State private var showNowPlaying = false

  private var displayAlbum: Album {
    localAlbum ?? album
  }

  private var isDownloaded: Bool {
    AlbumService.shared.checkIfAlbumDownloaded(albumID: album.id)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 8) {
        // Album cover
        WatchAlbumArtView(
          url: albumViewModel.getAlbumCoverArt(id: album.id),
          size: 100
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
      }
      .padding(.horizontal)
    }
    .navigationDestination(isPresented: $showNowPlaying) {
      WatchNowPlayingView()
    }
    .navigationTitle(album.name)
    .onAppear {
      loadAlbumDetail()
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
