//
//  CollectionDetailView.swift
//  flo Watch App
//

import SwiftUI

/// The body of an album or playlist: title, Play/Shuffle, download state and
/// the tracks. The caller supplies the artwork above the title and the
/// download and removal calls, which differ between albums and playlists.
struct CollectionDetailView<Artwork: View>: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @EnvironmentObject var downloadViewModel: DownloadViewModel

  let collectionId: String
  let title: String
  let meta: String
  let songs: [Song]
  /// Queued songs from a playlist keep the playlist as their origin.
  var isPlaylist = false
  var tint: Color = .floLavender
  let trackNumber: (_ index: Int, _ song: Song) -> Int
  /// Built on demand, so a playlist is only converted when it is played.
  let playable: () -> Album
  let onDownload: () -> Void
  let onRemove: () -> Void
  @ViewBuilder let artwork: () -> Artwork

  @Environment(\.showPlayer) private var showPlayer
  @State private var downloaded = false
  @State private var downloadedIds: Set<String> = []
  @State private var menu: MenuTarget?

  // From the downloaded records, so it is right as soon as a download ends.
  private var missingTrackCount: Int {
    songs.filter { !downloadedIds.contains($0.playbackID) }.count
  }

  private var downloadState: DownloadControl.State {
    if downloadViewModel.isDownloading(collectionId: collectionId) {
      return .downloading(
        percent: Int(downloadViewModel.getDownloadedTrackProgress(collectionId: collectionId)))
    }
    // An interrupted download leaves some tracks behind; offer the rest.
    if downloaded && missingTrackCount > 0 { return .partial(missing: missingTrackCount) }
    return downloaded ? .done : .none
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 6) {
        VStack(spacing: 3) {
          artwork()
          Text(title)
            .font(.floHero)
            .lineLimit(2)
            .multilineTextAlignment(.center)
          if !meta.isEmpty {
            Text(meta)
              .font(.floMeta)
              .foregroundStyle(Color.floOnCover)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
        }
        .padding(.bottom, 4)

        HStack(spacing: 6) {
          Button(action: {
            if playerViewModel.playItem(item: playable(), isFromLocal: downloaded) { showPlayer() }
          }) {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FloPrimaryButtonStyle())

          Button(action: {
            if playerViewModel.shuffleItem(item: playable(), isFromLocal: downloaded) {
              showPlayer()
            }
          }) {
            Label("Shuffle", systemImage: "shuffle")
          }
          .buttonStyle(FloTintedButtonStyle())
        }

        DownloadControl(
          state: downloadState,
          onDownload: onDownload,
          onCancel: { downloadViewModel.cancelCurrentAlbumDownload(collectionId: collectionId) },
          onRemove: {
            onRemove()
            downloaded = false
          })

        Rectangle()
          .fill(Color.white.opacity(0.1))
          .frame(height: 1)
          .padding(4)

        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          TrackRowView(
            trackNumber: trackNumber(index, song),
            title: song.title,
            artist: song.artist,
            isPlaying: playerViewModel.isCurrent(song),
            tint: tint,
            onHold: { menu = .song(song, context: title, isFromPlaylist: isPlaylist) }
          ) {
            if playerViewModel.playBySong(idx: index, item: playable(), isFromLocal: downloaded) {
              showPlayer()
            }
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 16)
    }
    .itemMenu($menu)
    .onAppear { refreshDownloadState() }
    .onReceive(downloadViewModel.$downloadWatcher) { newValue in
      if newValue {
        refreshDownloadState()
        downloadViewModel.downloadWatcher = false
      }
    }
  }

  private func refreshDownloadState() {
    downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: collectionId)
    downloadedIds = AlbumService.shared.downloadedMediaFileIds(collectionId: collectionId)
  }
}
