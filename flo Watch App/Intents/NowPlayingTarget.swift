//
//  NowPlayingTarget.swift
//  flo Watch App
//

import Foundation

/// What a Siri command about "this song", "this album" or "this artist" acts
/// on. The player sets it when a song becomes current and clears it when
/// nothing is; after a cold launch it stays nil until something plays, so a
/// restored queue is never taken for what is playing.
@MainActor enum NowPlayingTarget {
  struct Target: Equatable {
    let playbackID: String
    let title: String
    let artistName: String
    let albumId: String
    let albumName: String
    // Absent when neither the cached library nor the cached artists know it.
    var artistId: String?
    let isLiveRadio: Bool
  }

  static var current: Target?

  /// Makes the song the target, nil for none. Its artist id is looked up off
  /// the main thread and filled in while the song is still the target.
  static func publish(_ song: QueueEntity?, isLiveRadio: Bool) {
    guard let song, let id = song.id, !id.isEmpty else {
      current = nil
      return
    }
    guard current?.playbackID != id else { return }
    let target = Target(
      playbackID: id, title: song.songName ?? "", artistName: song.artistName ?? "",
      albumId: song.albumId ?? "", albumName: song.albumName ?? "", artistId: nil,
      isLiveRadio: isLiveRadio)
    current = target
    guard !isLiveRadio else { return }
    Task {
      let artistId = await artistId(of: id, named: target.artistName)
      guard current == target else { return }
      current?.artistId = artistId
    }
  }

  /// The song's artist id from the cached library, else the one cached artist
  /// of the song's artist name.
  private nonisolated static func artistId(of playbackID: String, named name: String) async
    -> String?
  {
    let index = await SmartPlaybackService.shared.libraryIndex(allowSync: false)
    let artists: [Artist] = await AlbumViewModel.cached(.artists)
    // The index keeps a song's artist id as its history key, and the folded
    // artist name for a song without one.
    if let key = index.songs[playbackID]?.historyArtistKey, artists.contains(where: { $0.id == key }) {
      return key
    }
    guard let spoken = ArtistIdentity.key(name: name, mbid: nil) else { return nil }
    let named = artists.filter { ArtistIdentity.key(name: $0.name, mbid: nil) == spoken }
    return named.count == 1 ? named[0].id : nil
  }
}
