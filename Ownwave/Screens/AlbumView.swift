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
  @EnvironmentObject private var downloads: DownloadSession
  // Redraws the track hearts when a song is liked from its menu.
  @ObservedObject private var stars = StarStore.shared
  @Environment(\.palette) private var palette

  @State private var songs: [Song] = []
  @State private var isLoaded = false
  @State private var shades: CoverShades?
  @State private var downloadedIds: Set<String> = []

  /// The album with the tracks shown, for playing, downloading and the menu.
  private var loadedAlbum: Album {
    var loaded = album
    loaded.songs = songs
    return loaded
  }

  private var tint: Color { shades?.tint ?? palette.fill }

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
    let length = songs.countAndLength
    if !length.isEmpty { parts.append(length) }
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
          ItemMenuItems(target: .album(loadedAlbum))
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
      }
    }
    .coverShades($shades, albumId: album.id)
    // Once: a return from a screen pushed on top keeps the loaded tracks,
    // also offline. A load cut short by that push runs again, and so does
    // one after a removed download, which keeps the tracks while offline.
    .task(id: isLoaded) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: album) where !songs.isEmpty {
        self.songs = songs
      }
      isLoaded = !Task.isCancelled
    }
    .onAppear { refreshDownloadState() }
    .onReceive(downloads.downloadFinished) { id in
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
        app.play(loadedAlbum)
      } label: {
        Label("Play", systemImage: "play.fill")
      }
      .buttonStyle(FillButtonStyle(tint: tint))
      Button {
        app.shuffle(loadedAlbum)
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
    if downloads.isDownloading(collectionId: album.id) {
      return .downloading(
        percent: Int(downloads.progress(collectionId: album.id) * 100))
    }
    if downloads.hasFailed(collectionId: album.id) { return .failed }
    // Unknown until the tracks are loaded.
    guard !songs.isEmpty else { return .none }
    let missing = songs.contains { !downloadedIds.contains($0.playbackID) }
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
          downloads.cancel(collectionId: album.id)
        }
      } label: {
        Image(systemName: "arrow.down")
      }
      .buttonStyle(CircleButtonStyle(size: 52, foreground: palette.accent))
    case .done:
      Menu {
        Button("Remove Download", systemImage: "trash", role: .destructive) {
          albumViewModel.removeDownload(id: album.id) { isLoaded = false }
          refreshDownloadState()
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
    .card(horizontal: 14, vertical: 12)
  }

  private func download() {
    app.download(loadedAlbum)
  }

  private func refreshDownloadState() {
    downloadedIds = DownloadStore.downloadedMediaFileIds(collectionId: album.id)
  }

  // MARK: - Tracks

  @ViewBuilder private var tracks: some View {
    if !songs.isEmpty {
      Platter {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          TrackRow(
            number: song.trackNumber, song: song, tint: tint,
            menu: .song(song, context: album.name, isFromPlaylist: false)
          ) {
            app.play(loadedAlbum, startingAt: index)
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
    .songActions(menu, play: play)
  }
}
