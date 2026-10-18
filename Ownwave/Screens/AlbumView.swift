//
//  AlbumView.swift
//  Ownwave
//

import SwiftUI

struct AlbumView: View {
  let album: Album

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @EnvironmentObject private var downloadViewModel: DownloadViewModel
  // Redraws the track hearts when a song is liked from its menu.
  @ObservedObject private var stars = StarStore.shared
  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var scheme

  // The loaded album stays with this screen when another one opens on top.
  @State private var localAlbum: Album?
  @State private var hue: Double?
  @State private var downloaded = false
  @State private var downloadedIds: Set<String> = []

  private var displayAlbum: Album { localAlbum ?? album }

  private var tint: Color {
    hue.map { CoverShades(hue: $0, scheme: scheme).tint } ?? palette.fill
  }

  /// The album artist as the Artist screen takes it: the listed one when the
  /// library has it.
  private var artist: Artist? {
    let id = album.albumArtistId.isEmpty ? album.artistId : album.albumArtistId
    guard !id.isEmpty else { return nil }
    return albumViewModel.artists.first { $0.id == id }
      ?? Artist(id: id, name: album.albumArtist, albumCount: 0, mbzArtistID: nil)
  }

  private var meta: String {
    var parts: [String] = []
    if album.minYear > 0 { parts.append(String(album.minYear)) }
    let songs = displayAlbum.songs.countAndLength
    if !songs.isEmpty { parts.append(songs) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        CoverArt(albumId: album.id, radius: 16)
          .frame(width: 236, height: 236)
          .shadow(color: .black.opacity(0.35), radius: 20, y: 18)
        titleBlock
        buttons
        downloadNote
        tracks
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
      .background(alignment: .top) { BlurredBackdrop(albumId: album.id, height: 430) }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          ItemMenuItems(target: .album(displayAlbum))
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
      }
    }
    .task(id: album.id) { hue = await CoverTint.hue(albumId: album.id) }
    .onAppear {
      // Once: a return from a screen pushed on top keeps the loaded tracks,
      // also offline.
      if localAlbum == nil { albumViewModel.setActiveAlbum(album: album) }
      refreshDownloadState()
    }
    .onReceive(albumViewModel.$album) { updated in
      if updated.id == album.id, !updated.songs.isEmpty { localAlbum = updated }
    }
    .onReceive(downloadViewModel.downloadFinished) { id in
      if id == album.id { refreshDownloadState() }
    }
  }

  private var titleBlock: some View {
    VStack(spacing: 5) {
      Text(album.name)
        .font(.heroTitle)
        .multilineTextAlignment(.center)
      HStack(spacing: 0) {
        if let artist {
          NavigationLink(value: Route.artist(artist)) {
            Text(album.albumArtist).fontWeight(.semibold).foregroundStyle(tint)
          }
          .buttonStyle(.plain)
        } else {
          Text(album.albumArtist)
        }
        if !meta.isEmpty { Text(" · " + meta) }
      }
      .font(.rowSubtitle)
      .foregroundStyle(palette.secondary)
      .lineLimit(1)
    }
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      Button {
        if player.playItem(item: displayAlbum) { app.isNowPlayingPresented = true }
      } label: {
        Label("Play", systemImage: "play.fill")
      }
      .buttonStyle(FillButtonStyle(tint: tint))
      Button {
        if player.shuffleItem(item: displayAlbum) { app.isNowPlayingPresented = true }
      } label: {
        Label("Shuffle", systemImage: "shuffle").foregroundStyle(palette.accent)
      }
      .buttonStyle(PlatterButtonStyle())
      downloadButton
    }
  }

  // MARK: - Download

  private enum DownloadState: Equatable {
    case none
    case downloading(percent: Int)
    case failed, done
  }

  /// As the watch's download control: an interrupted download leaves some
  /// tracks behind and offers the rest.
  private var downloadState: DownloadState {
    if downloadViewModel.isDownloading(collectionId: album.id) {
      return .downloading(
        percent: Int(downloadViewModel.getDownloadedTrackProgress(collectionId: album.id)))
    }
    if downloadViewModel.hasFailed(collectionId: album.id) { return .failed }
    // Unknown until the tracks are loaded.
    guard downloaded, !displayAlbum.songs.isEmpty else { return .none }
    let missing = displayAlbum.songs.contains { !downloadedIds.contains($0.playbackID) }
    return missing ? .none : .done
  }

  @ViewBuilder private var downloadButton: some View {
    switch downloadState {
    case .none:
      Button(action: download) { Image(systemName: "arrow.down") }
        .buttonStyle(CircleButtonStyle(size: 52, foreground: palette.accent))
        .accessibilityLabel("Download")
    case .failed:
      Button(action: download) { Image(systemName: "exclamationmark.circle") }
        .buttonStyle(CircleButtonStyle(size: 52, foreground: .floDestructive))
        .accessibilityLabel("Retry Download")
    case .downloading:
      Menu {
        Button("Cancel Download", systemImage: "xmark", role: .destructive) {
          downloadViewModel.cancelCurrentAlbumDownload(collectionId: album.id)
        }
      } label: {
        Image(systemName: "arrow.down")
      }
      .buttonStyle(CircleButtonStyle(size: 52, foreground: palette.accent))
    case .done:
      Menu {
        Button("Remove Download", systemImage: "trash", role: .destructive) {
          albumViewModel.removeDownloadedAlbum(album: album)
          downloaded = false
        }
      } label: {
        Image(systemName: "checkmark.circle.fill")
      }
      .buttonStyle(CircleButtonStyle(size: 52, foreground: .floDownloaded))
      .accessibilityLabel("Downloaded")
    }
  }

  @ViewBuilder private var downloadNote: some View {
    switch downloadState {
    case .downloading(let percent):
      note("Downloading", detail: "\(percent)%", color: palette.accent, progress: Double(percent))
    case .failed:
      note(
        "Download failed", detail: "Tap download to retry", color: .floDestructive, progress: 100)
    case .none, .done:
      EmptyView()
    }
  }

  private func note(_ title: String, detail: String, color: Color, progress: Double) -> some View {
    VStack(spacing: 6) {
      HStack {
        Text(title).fontWeight(.semibold).foregroundStyle(color)
        Spacer()
        Text(detail).foregroundStyle(palette.secondary)
      }
      .font(.rowSubtitle)
      ProgressView(value: progress, total: 100).tint(color)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func download() {
    app.download(displayAlbum)
  }

  private func refreshDownloadState() {
    downloaded = AlbumService.shared.checkIfAlbumDownloaded(albumID: album.id)
    downloadedIds = AlbumService.shared.downloadedMediaFileIds(collectionId: album.id)
  }

  // MARK: - Tracks

  @ViewBuilder private var tracks: some View {
    let songs = displayAlbum.songs
    if !songs.isEmpty {
      let isPlaylist = PlaybackService.isPlaylist(displayAlbum)
      Platter {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          TrackRow(
            number: isPlaylist ? index + 1 : song.trackNumber, song: song, tint: tint,
            menu: .song(song, context: album.name, isFromPlaylist: isPlaylist)
          ) {
            if player.playItem(item: displayAlbum, startingAt: index) {
              app.isNowPlayingPresented = true
            }
          }
        }
      }
    }
  }
}

/// A numbered track: a waveform in the cover tint while it plays, a small
/// heart when liked, its length and the ••• menu.
private struct TrackRow: View {
  let number: Int
  let song: Song
  let tint: Color
  let menu: MenuTarget
  let play: () -> Void

  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  var body: some View {
    let playing = player.isCurrent(song)
    HStack(spacing: 12) {
      Group {
        if playing {
          Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
        } else {
          Text("\(number)")
        }
      }
      .font(.rowSubtitle.monospacedDigit())
      .foregroundStyle(playing ? tint : palette.secondary)
      .frame(width: 22)
      Text(song.title)
        .font(.rowTitle.weight(.regular))
        .foregroundStyle(playing ? tint : palette.text)
        .lineLimit(1)
      Spacer(minLength: 0)
      if player.isStarred(song) {
        Image(systemName: "heart.fill")
          .font(.system(size: 12))
          .foregroundStyle(Color.floLiked)
      }
      Text(song.duration.minuteSecond)
        .font(.rowSubtitle.monospacedDigit())
        .foregroundStyle(palette.secondary)
      ItemMenuButton(target: menu)
    }
    .frame(minHeight: 52)
    .contentShape(Rectangle())
    .onTapGesture(perform: play)
    .accessibilityAddTraits(.isButton)
    .itemMenu(menu)
  }
}
