//
//  Constants.swift
//  flo
//
//  Created by rizaldy on 06/06/24.
//

import Combine
import Foundation
import SwiftUI
import UIKit

enum API {
  static let NDAuthHeader = "X-ND-Authorization"

  // Watch cover tiles are 36 to 100 points at 2x, so 200 px is the largest
  // the watch shows.
  #if os(watchOS)
    static let coverArtSize = 200
  #else
    static let coverArtSize = 300
  #endif

  enum NDEndpoint {
    static let login = "/auth/login"
    static let getAlbum = "/api/album"
    static let getArtists = "/api/artist"
    static let getPlaylists = "/api/playlist"
    static let getSong = "/api/song"
    static let getScrobbles = "/api/scrobble"
  }

  enum SubsonicEndpoint {
    static let stream = "/rest/stream"
    static let coverArt = "/rest/getCoverArt"
    static let download = "/rest/download"
    static let scrobble = "/rest/scrobble"
    static let reportPlayback = "/rest/reportPlayback"
    static let radios = "/rest/getInternetRadioStations"
    static let similarSongs = "/rest/getSimilarSongs2"
    static let topSongs = "/rest/getTopSongs"
    static let star = "/rest/star"
    static let unstar = "/rest/unstar"
    static let setRating = "/rest/setRating"
    static let getStarred2 = "/rest/getStarred2"
    static let getTranscodeDecision = "/rest/getTranscodeDecision"
    static let getTranscodeStream = "/rest/getTranscodeStream"
  }
}

enum PlaybackMode {
  static let defaultPlayback = "default"
  static let repeatAlbum = "repeatAlbum"
  static let repeatOnce = "repeatOnce"
}

enum AppMeta {
  static let name = "flo"
  static let identifier = "net.faultables.flo"
  static let subsonicApiVersion = "1.16.1"  // FIXME: should we respect the subsonic-response?
}

enum UserDefaultsKeys {
  static let serverURL = "serverURL"
  static let queueActiveIdx = "queueActiveIdx"
  static let nowPlayingProgress = "nowPlayingProgress"
  static let nowPlayingQualified = "nowPlayingQualified"
  static let nowPlayingListened = "nowPlayingListened"
  static let playbackMode = "playbackMode"
  static let enableMaxBitRate = "enableMaxBitRate"
  static let saveLoginInfo = "saveLoginInfo"
  static let streamCacheMaxSize = "streamCacheMaxSize"
  static let keepPlaying = "keepPlaying"
  static let pendingRatings = "pendingRatings"
  static let confirmedRatings = "confirmedRatings"
}

enum KeychainKeys {
  static let service = AppMeta.identifier
  static let dataKey = "authCreds"
  static let serverPassword = "serverPassword"
}

enum TranscodingSettings {
  static let sourceBitRate = "0"
  static let sourceFormat = "raw"
  static let targetFormat = "mp3"
}

/// Prints verification traces in debug builds only.
func debugLog(_ message: @autoclosure () -> String) {
  #if DEBUG
    print("[flo-debug] \(message())")
  #endif
}
