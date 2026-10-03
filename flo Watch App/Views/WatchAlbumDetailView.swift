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
  @State private var tint: Color = .floLavender

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

  private var downloadState: DownloadControl.State {
    if isDownloading { return .downloading(percent: Int(downloadProgress)) }
    // An interrupted download leaves some tracks behind; offer the rest.
    if isDownloaded && missingTrackCount > 0 { return .partial(missing: missingTrackCount) }
    return isDownloaded ? .done : .none
  }

  private var meta: String {
    var parts = [album.albumArtist]
    if album.minYear > 0 { parts.append(String(album.minYear)) }
    let count = displayAlbum.songs.count
    if count > 0 { parts.append("\(count) song\(count == 1 ? "" : "s")") }
    return parts.filter { !$0.isEmpty }.joined(separator: " · ")
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 6) {
        VStack(spacing: 3) {
          Spacer().frame(height: 58)
          Text(album.name)
            .font(.floHero)
            .lineLimit(2)
            .multilineTextAlignment(.center)
          Text(meta)
            .font(.floMeta)
            .foregroundStyle(Color.floOnCover)
            .lineLimit(1)
        }
        .padding(.bottom, 4)

        HStack(spacing: 6) {
          Button(action: {
            showNowPlaying = playerViewModel.playItem(item: displayAlbum, isFromLocal: isDownloaded)
          }) {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FloPrimaryButtonStyle())

          Button(action: {
            showNowPlaying = playerViewModel.shuffleItem(
              item: displayAlbum, isFromLocal: isDownloaded)
          }) {
            Label("Shuffle", systemImage: "shuffle")
          }
          .buttonStyle(FloTintedButtonStyle())
        }

        DownloadControl(
          state: downloadState,
          onDownload: { downloadCollection() },
          onCancel: { downloadViewModel.cancelCurrentAlbumDownload(collectionId: album.id) },
          onRemove: {
            albumViewModel.removeDownloadedAlbum(album: album)
            downloaded = false
          })

        Rectangle()
          .fill(Color.white.opacity(0.1))
          .frame(height: 1)
          .padding(4)

        ForEach(Array(displayAlbum.songs.enumerated()), id: \.element.id) { index, song in
          let isCurrentlyPlaying =
            playerViewModel.hasNowPlaying()
            && playerViewModel.nowPlaying.id == (song.mediaFileId.isEmpty ? song.id : song.mediaFileId)

          TrackRowView(
            trackNumber: song.trackNumber,
            title: song.title,
            artist: song.artist,
            isPlaying: isCurrentlyPlaying,
            tint: tint
          ) {
            showNowPlaying = playerViewModel.playBySong(
              idx: index, item: displayAlbum, isFromLocal: isDownloaded)
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 16)
    }
    .background(alignment: .top) {
      CoverBackdrop(albumId: album.id, height: 220)
    }
    .navigationDestination(isPresented: $showNowPlaying) {
      WatchNowPlayingView()
    }
    .task(id: album.id) {
      tint = await CoverTint.color(albumId: album.id) ?? .floLavender
    }
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
