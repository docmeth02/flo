//
//  CollectionActions.swift
//  Ownwave
//

import SwiftUI

/// The compact button row of an album or playlist: Play, then round
/// buttons for Shuffle, Download and Pin, and under them a note while a
/// download runs or has failed.
struct CollectionActions: View {
  /// The album or playlist, with the songs its screen loaded.
  private let target: MenuTarget
  /// As the player and the download record take it.
  private let collection: Album
  private let tint: Color?
  /// Loads the screen again after its download was removed.
  private let reload: () -> Void

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @EnvironmentObject private var downloads: DownloadSession
  @EnvironmentObject private var pins: PinStore
  @Environment(\.palette) private var palette

  @State private var downloadedIds: Set<String> = []

  private static let size: CGFloat = 50

  /// Play takes the cover's tint.
  init(album: Album, tint: Color, reload: @escaping () -> Void) {
    target = .album(album)
    collection = album
    self.tint = tint
    self.reload = reload
  }

  init(playlist: Playlist, reload: @escaping () -> Void) {
    target = .playlist(playlist)
    collection = Album(from: playlist)
    tint = nil
    self.reload = reload
  }

  var body: some View {
    VStack(spacing: 18) {
      HStack(spacing: 10) {
        Button {
          app.play(collection)
        } label: {
          Label("Play", systemImage: "play.fill")
        }
        .buttonStyle(FillButtonStyle(tint: tint, height: Self.size))
        Button {
          app.shuffle(collection)
        } label: {
          Image(systemName: "shuffle")
        }
        .buttonStyle(CircleButtonStyle(size: Self.size))
        .accessibilityLabel("Shuffle")
        downloadButton
        pinButton
      }
      downloadNote
    }
    .onAppear { refreshDownloadState() }
    .onReceive(downloads.downloadFinished) { id in
      if id == collection.id { refreshDownloadState() }
    }
  }

  // MARK: - Pin

  private var actions: MenuActions {
    MenuActions(player: app.player, pins: pins, stars: StarStore.shared)
  }

  private var pinButton: some View {
    let isPinned = actions.isPinned(target) ?? false
    return Button {
      Task {
        if let text = await actions.perform(.pin, on: target) { app.show(text) }
      }
    } label: {
      Image(systemName: isPinned ? "pin.fill" : "pin")
    }
    .buttonStyle(
      CircleButtonStyle(size: Self.size, foreground: isPinned ? palette.accent : nil)
    )
    .accessibilityLabel(isPinned ? "Unpin" : "Pin to Top")
  }

  // MARK: - Download

  private enum DownloadState: Equatable {
    case none
    case downloading(percent: Int)
    case failed, done
  }

  /// As the watch's download control: an interrupted download leaves some
  /// songs behind and offers the rest.
  private var downloadState: DownloadState {
    if downloads.isDownloading(collectionId: collection.id) {
      return .downloading(
        percent: Int(downloads.progress(collectionId: collection.id) * 100))
    }
    if downloads.hasFailed(collectionId: collection.id) { return .failed }
    // Unknown until the songs are loaded.
    guard !collection.songs.isEmpty else { return .none }
    let missing = collection.songs.contains { !downloadedIds.contains($0.playbackID) }
    return missing ? .none : .done
  }

  @ViewBuilder private var downloadButton: some View {
    let style = CircleButtonStyle(size: Self.size, foreground: palette.accent)
    switch downloadState {
    case .none:
      Button(action: download) { Image(systemName: "arrow.down.circle") }
        .buttonStyle(style)
        .accessibilityLabel("Download")
    case .failed:
      Button(action: download) { Image(systemName: "exclamationmark.circle") }
        .buttonStyle(CircleButtonStyle(size: Self.size, foreground: .floDestructive))
        .accessibilityLabel("Retry Download")
    case .downloading(let percent):
      Menu {
        Button("Cancel Download", systemImage: "xmark", role: .destructive) {
          downloads.cancel(collectionId: collection.id)
        }
      } label: {
        DownloadRing(percent: percent)
      }
      .buttonStyle(style)
      .accessibilityLabel("Downloading, \(percent) percent")
    case .done:
      Menu {
        Button("Remove Download", systemImage: "trash", role: .destructive) {
          albumViewModel.removeDownload(id: collection.id, removed: reload)
          refreshDownloadState()
        }
      } label: {
        Image(systemName: "checkmark.circle.fill")
      }
      .buttonStyle(CircleButtonStyle(size: Self.size, foreground: .floDownloaded))
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
    if case .playlist(let playlist) = target {
      app.download(playlist)
    } else {
      app.download(collection)
    }
  }

  private func refreshDownloadState() {
    downloadedIds = DownloadStore.downloadedMediaFileIds(collectionId: collection.id)
  }
}

/// A running download in its round button: the share done as a ring
/// around a stop square, which opens Cancel.
private struct DownloadRing: View {
  let percent: Int

  @Environment(\.palette) private var palette

  var body: some View {
    ZStack {
      Circle().stroke(palette.hairline, lineWidth: 2.5)
      Circle()
        .trim(from: 0, to: CGFloat(percent) / 100)
        .stroke(palette.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .animation(.linear, value: percent)
      Image(systemName: "stop.fill").font(.system(size: 9))
    }
    .frame(width: 22, height: 22)
  }
}
