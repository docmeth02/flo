//
//  WidgetPublisher.swift
//  Ownwave
//

import Combine
import UIKit
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
  /// Bumped by every publish, so a slower earlier one never saves over it.
  private var generation = 0

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
    // Without waiting for the debounce: a quit right after a logout must not
    // leave the account in the widgets.
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in
        WidgetPublisher.shared.generation += 1
        WidgetPublisher.shared.clear()
      }
    }
    // The last song counts as played only after it started, and a cover may
    // have failed offline: leaving the app catches up on both.
    NotificationCenter.default.addObserver(
      forName: UIApplication.willResignActiveNotification, object: nil, queue: .main
    ) { _ in
      Task { @MainActor in
        await AppModel.shared.albums.loadRecentAlbums()
        WidgetPublisher.shared.publish(songChanged: WidgetPublisher.shared.lastSongId, retry: true)
      }
    }
  }

  fileprivate var lastSongId: String?

  fileprivate func publish(songChanged songId: String?, retry: Bool = false) {
    let app = AppModel.shared
    generation += 1
    let generation = generation
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
    let albums = ([snapshot.nowPlaying?.albumId].compactMap { $0 } + snapshot.recent.map(\.id))
      .filter { !$0.isEmpty }
    guard snapshot != last || (retry && albums.contains(where: Self.coverMissing)) else { return }

    Task {
      let missing = albums.filter(Self.coverMissing)
      for albumId in missing { await Self.writeCover(albumId) }
      // A logout during the writes leaves none of the account's covers.
      guard AppModel.shared.auth.isLoggedIn else { return Self.removeAllCovers() }
      guard generation == self.generation else { return }
      Self.removeCovers(except: Set(albums))
      snapshot.save()
      // Covers that came only now need their widgets redrawn too.
      reload(from: missing.isEmpty ? last : WidgetSnapshot(), to: snapshot)
      last = snapshot
    }
  }

  /// Signed out: the widgets say so, and the account's covers go.
  private func clear() {
    Self.removeAllCovers()
    let empty = WidgetSnapshot()
    guard last != empty else { return }
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

  private static func removeAllCovers() {
    if let covers = WidgetSnapshot.coversFolder { try? FileManager.default.removeItem(at: covers) }
  }

  /// Covers no widget shows any more only take room in the App Group.
  private static func removeCovers(except kept: Set<String>) {
    guard let folder = WidgetSnapshot.coversFolder,
      let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
    else { return }
    for file in files where !kept.contains(file.deletingPathExtension().lastPathComponent) {
      try? FileManager.default.removeItem(at: file)
    }
  }

  private static func coverMissing(_ albumId: String) -> Bool {
    guard let url = WidgetSnapshot.coverURL(albumId: albumId) else { return false }
    return !FileManager.default.fileExists(atPath: url.path)
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
      _ = Thumbnail.write(
        URL(fileURLWithPath: source), to: target, pixels: pixels, type: .jpeg, quality: 0.8)
    }.value
  }
}
