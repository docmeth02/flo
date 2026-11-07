//
//  CollectionSongs.swift
//  Ownwave
//

import Foundation

/// The songs of an album or playlist screen, loaded once per screen: a
/// return from a screen pushed on top keeps them, also offline. A load cut
/// short by that push or left empty runs again on the next appear, and so
/// does one after `reload()`.
@MainActor
final class CollectionSongs: ObservableObject {
  @Published private(set) var songs: [Song] = []
  /// Bumped by `reload()`, so the screen's task runs again.
  @Published private(set) var reloads = 0
  private var isLoaded = false

  /// Shows each list `makeStream`'s stream yields. Once loaded the stream is
  /// not made at all, since a song loader asks the server as soon as it is.
  func load(_ makeStream: () -> AsyncStream<[Song]>) async {
    guard !isLoaded else { return }
    for await songs in makeStream() { self.songs = songs }
    isLoaded = !Task.isCancelled && !songs.isEmpty
  }

  /// Loads the songs again, as after a removed download.
  func reload() {
    isLoaded = false
    reloads += 1
  }
}
