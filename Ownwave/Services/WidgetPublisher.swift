//
//  WidgetPublisher.swift
//  Ownwave
//

import Combine
import ImageIO
import UniformTypeIdentifiers
import WidgetKit

/// Keeps the widgets' snapshot in the App Group: the song playing, the albums
/// played last and their covers. A widget is reloaded only when its part
/// changed, since the system budgets reloads.
@MainActor final class WidgetPublisher {
  static let shared = WidgetPublisher()

  /// Room for the medium Now Playing cover at 3x.
  private static let coverPixels = 360

  private var last = WidgetSnapshot.load()
  private var changes: AnyCancellable?

  private init() {}

  func start() {
    let app = AppModel.shared
    let player = app.player
    let song = player.$activeQueueIdx.combineLatest(player.$queue)
      .map { index, queue in queue.indices.contains(index) ? queue[index].id : nil }
      .removeDuplicates()
    // A new song may change the albums played last; that list comes back
    // through recentAlbums.
    changes = song.combineLatest(app.albums.$recentAlbums, app.auth.$isLoggedIn)
      .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
      .sink { [weak self] songId, _, _ in self?.publish(songChanged: songId) }
  }

  private var lastSongId: String?

  private func publish(songChanged songId: String?) {
    let app = AppModel.shared
    if songId != lastSongId {
      lastSongId = songId
      if songId != nil { Task { await app.albums.loadRecentAlbums() } }
    }
    guard app.auth.isLoggedIn else { return clear() }

    var snapshot = WidgetSnapshot(signedIn: true)
    if app.player.hasNowPlaying() {
      let song = app.player.nowPlaying
      snapshot.nowPlaying = .init(
        title: song.songName ?? "", artist: song.artistName ?? "", albumId: song.albumId ?? "")
    }
    snapshot.recent = app.albums.recentAlbums.prefix(4).map { .init(id: $0.id, name: $0.name) }
    guard snapshot != last else { return }

    let albums = [snapshot.nowPlaying?.albumId].compactMap { $0 } + snapshot.recent.map(\.id)
    Task {
      for albumId in albums where !albumId.isEmpty { await Self.writeCover(albumId) }
      snapshot.save()
      reload(from: last, to: snapshot)
      last = snapshot
    }
  }

  /// Signed out: the widgets say so, and the account's covers go.
  private func clear() {
    let empty = WidgetSnapshot()
    guard last != empty else { return }
    if let covers = WidgetSnapshot.coversFolder { try? FileManager.default.removeItem(at: covers) }
    empty.save()
    reload(from: last, to: empty)
    last = empty
  }

  private func reload(from old: WidgetSnapshot, to new: WidgetSnapshot) {
    let center = WidgetCenter.shared
    let signedIn = old.signedIn != new.signedIn
    if signedIn {
      center.reloadTimelines(ofKind: WidgetSnapshot.Kind.playSomething)
      center.reloadTimelines(ofKind: WidgetSnapshot.Kind.launcher)
    }
    if signedIn || old.nowPlaying != new.nowPlaying {
      center.reloadTimelines(ofKind: WidgetSnapshot.Kind.nowPlaying)
    }
    if signedIn || old.recent != new.recent {
      center.reloadTimelines(ofKind: WidgetSnapshot.Kind.recentlyPlayed)
    }
  }

  /// A small JPEG of the album's cover, fetched when the app has none yet.
  private static func writeCover(_ albumId: String) async {
    guard let target = WidgetSnapshot.coverURL(albumId: albumId),
      !FileManager.default.fileExists(atPath: target.path)
    else { return }
    var source = AlbumService.shared.downloadedCoverPath(albumId: albumId)
    if source == nil { source = await CoverArtCacheManager.shared.coverPath(albumId: albumId) }
    guard let source else { return }
    let pixels = coverPixels
    await Task.detached(priority: .utility) {
      let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceThumbnailMaxPixelSize: pixels,
        kCGImageSourceCreateThumbnailWithTransform: true,
      ]
      guard let image = CGImageSourceCreateWithURL(URL(fileURLWithPath: source) as CFURL, nil)
        .flatMap({ CGImageSourceCreateThumbnailAtIndex($0, 0, options as CFDictionary) })
      else { return }
      try? FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
      guard
        let destination = CGImageDestinationCreateWithURL(
          target as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
      else { return }
      CGImageDestinationAddImage(
        destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
      CGImageDestinationFinalize(destination)
    }.value
  }
}
