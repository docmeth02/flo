//
//  CollectionDetailView.swift
//  Ownwave Watch App
//

import SwiftUI

/// The body of an album or playlist: cover, title, Play/Shuffle, download
/// state and the tracks on one platter, over a backdrop in the cover's
/// shade. The caller supplies the download and removal calls, which differ
/// between albums and playlists.
struct CollectionDetailView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel
  @EnvironmentObject var downloads: DownloadSession
  @ObservedObject private var phone = PhoneLink.shared

  private static let coverSize: CGFloat = 80
  private static let coverRadius: CGFloat = 12
  private static let buttonHeight: CGFloat = 40

  let collectionId: String
  /// A cover of its own, such as a playlist's mosaic; the album's when nil.
  var artId: String?
  let title: String
  let meta: String
  let songs: [Song]
  var tint: Color = .floLilac
  /// The top of the backdrop, fading to black; a lilac wash when nil.
  var shade: Color?
  /// An album's cover also lies blurred behind the header.
  var blursCover = false
  /// The tracks' artist line is left out where it repeats this one.
  var artist = ""
  let trackNumber: (_ index: Int, _ song: Song) -> Int
  /// Built on demand, so a playlist is only converted when it is played.
  let playable: () -> Album
  let onDownload: () -> Void
  let onRemove: () -> Void

  @Environment(\.showPlayer) private var showPlayer
  @State private var downloaded = false
  @State private var downloadedIds: Set<String> = []
  @State private var menu: MenuTarget?

  // From the downloaded records, so it is right as soon as a download ends.
  private var missingTrackCount: Int {
    songs.filter { !downloadedIds.contains($0.playbackID) }.count
  }

  private var downloadState: DownloadControl.State {
    if downloads.isDownloading(collectionId: collectionId) {
      return .downloading(
        percent: Int(downloads.progress(collectionId: collectionId) * 100))
    }
    // Songs the iPhone is still sending are on their way, not missing.
    if phone.isReceiving(collectionId: collectionId) {
      return .receiving(
        percent: phone.progress(collectionId: collectionId, songs: downloadedIds.count))
    }
    if downloads.hasFailed(collectionId: collectionId) { return .failed }
    // An interrupted download leaves some tracks behind; offer the rest.
    if downloaded && missingTrackCount > 0 { return .partial(missing: missingTrackCount) }
    return downloaded ? .done : .none
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 6) {
        VStack(spacing: 2) {
          WatchAlbumArtView(albumId: collectionId, artId: artId, size: Self.coverSize)
            .clipShape(RoundedRectangle(cornerRadius: Self.coverRadius, style: .continuous))
            .shadow(color: .black.opacity(0.7), radius: 10, y: 6)
            .padding(.bottom, 6)
          Text(title)
            .font(.floSong)
            .lineLimit(2)
            .multilineTextAlignment(.center)
          if !meta.isEmpty {
            Text(meta)
              .font(.floMeta)
              .foregroundStyle(Color.floSecondary)
              .lineLimit(1)
              .minimumScaleFactor(0.8)
          }
        }
        .padding(.bottom, 4)

        HStack(spacing: 6) {
          Button {
            if playerViewModel.playItem(item: playable()) { showPlayer() }
          } label: {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FloPrimaryButtonStyle(fill: tint, height: Self.buttonHeight))

          Button {
            if playerViewModel.shuffleItem(item: playable()) { showPlayer() }
          } label: {
            Image(systemName: "shuffle")
          }
          .buttonStyle(
            FloRoundButtonStyle(tint: tint, fill: tint.opacity(0.18), size: Self.buttonHeight)
          )
          .accessibilityLabel("Shuffle")
        }

        DownloadControl(
          state: downloadState,
          onDownload: onDownload,
          onCancel: { downloads.cancel(collectionId: collectionId) },
          onRemove: {
            onRemove()
            downloaded = false
            downloadedIds = []
          })

        tracks.padding(.top, 4)
      }
      .padding(.horizontal, 8)
      .padding(.bottom, 16)
    }
    .background { backdrop }
    .itemMenu($menu)
    .onAppear { refreshDownloadState() }
    .onReceive(downloads.downloadFinished) { id in
      if id == collectionId { refreshDownloadState() }
    }
  }

  private var tracks: some View {
    // By position: a playlist can hold a song twice.
    PlatterStack(songs, hairlineInset: TrackRowView.textInset) { index, song in
      TrackRowView(
        trackNumber: trackNumber(index, song),
        title: song.title,
        artist: song.artist == artist ? "" : song.artist,
        isPlaying: playerViewModel.isCurrent(song),
        tint: tint,
        idleBackground: .clear,
        onHold: {
          menu = .song(song, context: title, isFromPlaylist: playable().isPlaylist)
        }
      ) {
        if playerViewModel.playItem(item: playable(), startingAt: index) { showPlayer() }
      }
    }
  }

  private var backdrop: some View {
    ZStack(alignment: .top) {
      if blursCover {
        CoverBackdrop(albumId: collectionId, height: 200)
          .blur(radius: 8)
          .opacity(0.3)
      }
      LinearGradient(
        stops: [
          .init(color: shade ?? .floWave.opacity(0.18), location: 0),
          .init(color: .black, location: 0.7),
        ],
        startPoint: .top, endPoint: .bottom)
    }
    .ignoresSafeArea()
  }

  private func refreshDownloadState() {
    downloaded = DownloadStore.checkIfAlbumDownloaded(albumID: collectionId)
    downloadedIds = DownloadStore.downloadedMediaFileIds(collectionId: collectionId)
  }
}
