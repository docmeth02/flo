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

  @Environment(\.showPlayer) private var showPlayer
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

  private var downloadState: DownloadControl.State {
    if isDownloading { return .downloading(percent: Int(downloadProgress)) }
    // An interrupted download leaves some tracks behind; offer the rest.
    if isDownloaded && missingTrackCount > 0 { return .partial(missing: missingTrackCount) }
    return isDownloaded ? .done : .none
  }

  private var meta: String {
    if !playlist.comment.isEmpty { return playlist.comment }
    let count = displayPlaylist.songs.count
    return count > 0 ? "\(count) song\(count == 1 ? "" : "s")" : ""
  }

  private func downloadPlaylist() {
    let playablePlaylist = Album(from: displayPlaylist)
    albumViewModel.downloadPlaylist(displayPlaylist)
    downloadViewModel.addItem(playablePlaylist, isFromPlaylist: true)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 6) {
        VStack(spacing: 3) {
          Image(systemName: "music.note.list")
            .font(.system(size: 34))
            .foregroundStyle(Color.floLavender)
            .frame(width: 80, height: 80)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.floLavender.opacity(0.18))
            )
            .padding(.bottom, 6)
          Text(playlist.name)
            .font(.floHero)
            .lineLimit(2)
            .multilineTextAlignment(.center)
          if !meta.isEmpty {
            Text(meta)
              .font(.floMeta)
              .foregroundStyle(Color.floOnCover)
              .lineLimit(1)
          }
        }
        .padding(.bottom, 4)

        HStack(spacing: 6) {
          Button(action: {
            let playablePlaylist = Album(from: displayPlaylist)
            if playerViewModel.playItem(
              item: playablePlaylist, isFromLocal: isDownloaded) { showPlayer() }
          }) {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FloPrimaryButtonStyle())

          Button(action: {
            let playablePlaylist = Album(from: displayPlaylist)
            if playerViewModel.shuffleItem(
              item: playablePlaylist, isFromLocal: isDownloaded) { showPlayer() }
          }) {
            Label("Shuffle", systemImage: "shuffle")
          }
          .buttonStyle(FloTintedButtonStyle())
        }

        DownloadControl(
          state: downloadState,
          onDownload: { downloadPlaylist() },
          onCancel: { downloadViewModel.cancelCurrentAlbumDownload(collectionId: playlist.id) },
          onRemove: {
            albumViewModel.removeDownloadedPlaylist(playlist: playlist)
            downloaded = false
          })

        Rectangle()
          .fill(Color.white.opacity(0.1))
          .frame(height: 1)
          .padding(4)

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
            if playerViewModel.playBySong(
              idx: index, item: playablePlaylist, isFromLocal: isDownloaded) { showPlayer() }
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 16)
    }
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
