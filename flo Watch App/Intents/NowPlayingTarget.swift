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
    let artistId: String?
    let isLiveRadio: Bool
  }

  static var current: Target?
}
