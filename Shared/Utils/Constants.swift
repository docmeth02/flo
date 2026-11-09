//
//  Constants.swift
//  Ownwave
//

import Foundation

enum API {
  static let ndAuthHeader = "X-ND-Authorization"

  enum NDEndpoint {
    static let login = "/auth/login"
    static let getAlbum = "/api/album"
    static let getArtists = "/api/artist"
    static let getPlaylists = "/api/playlist"
    static let getSong = "/api/song"
    static let getScrobbles = "/api/scrobble"
  }

  enum SubsonicEndpoint {
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
    static let ping = "/rest/ping"
    static let savePlayQueueByIndex = "/rest/savePlayQueueByIndex"
    static let getPlayQueueByIndex = "/rest/getPlayQueueByIndex"
  }
}

enum PlaybackMode {
  static let defaultPlayback = "default"
  static let repeatAlbum = "repeatAlbum"
  static let repeatOnce = "repeatOnce"
}

enum AppMeta {
  static let name = "Ownwave"
  static let identifier = "de.m2-entertainment.ownwave"
  static let subsonicApiVersion = "1.16.1"
}

enum UserDefaultsKeys {
  static let serverURL = "serverURL"
  static let queueActiveIdx = "queueActiveIdx"
  static let nowPlayingProgress = "nowPlayingProgress"
  static let nowPlayingQualified = "nowPlayingQualified"
  static let nowPlayingListened = "nowPlayingListened"
  static let playbackMode = "playbackMode"
  static let enableMaxBitRate = "enableMaxBitRate"
  static let downloadBitRate = "downloadBitRate"
  // The phone's limits on cellular; enableMaxBitRate is its Wi-Fi limit.
  static let cellularBitRate = "cellularBitRate"
  static let streamOnCellular = "streamOnCellular"
  static let downloadOverCellular = "downloadOverCellular"
  // The watch follows the phone's settings; the phone shares them.
  static let settingsFollowPhone = "settingsFollowPhone"
  static let shareWatchSettings = "shareWatchSettings"
  static let streamCacheMaxSize = "streamCacheMaxSize"
  static let keepPlaying = "keepPlaying"
  static let showMixReasons = "showMixReasons"
  static let mixVariety = "mixVariety"
  // The server's play queue is saved and offered (PlayQueueSync).
  static let syncQueue = "syncQueue"
  // Per account, the last saved queue the user took over or turned down, by
  // its `changed` stamp.
  static let handledQueueChanges = "handledQueueChanges"
  // Edits the server has not confirmed yet, by id (PendingEdits): ratings
  // 1 to 5 or 0 to clear, and stars.
  static let pendingRatings = "pendingRatings"
  static let pendingArtistRatings = "pendingArtistRatings"
  static let pendingStars = "pendingStars"
  // The songs among pendingStars (StarStore).
  static let pendingStarSongs = "pendingStarSongs"
  static let confirmedRatings = "confirmedRatings"
  static let confirmedArtistRatings = "confirmedArtistRatings"
  // The account whose queued plays and pending edits outlived its session.
  static let pendingWorkAccount = "pendingWorkAccount"
  static let downloadsRestartOnActivation = "downloadsRestartOnActivation"
}

enum KeychainKeys {
  static let service = AppMeta.identifier
  static let dataKey = "authCreds"
  static let serverPassword = "serverPassword"
  static let serverURL = "serverURL"
}

enum TranscodingSettings {
  static let sourceBitRate = "0"
  /// The limits Settings offers, in kbps; the server transcodes to MP3 only.
  static let bitRates = [sourceBitRate, "160", "192", "256", "320"]
  static let defaultBitRate = "192"

  /// The stored limit, or the default when none is stored or it is one
  /// earlier builds offered (32, 64, 96, 128) and Settings no longer lists.
  static func offeredBitRate(_ stored: String?) -> String {
    stored.flatMap { bitRates.contains($0) ? $0 : nil } ?? defaultBitRate
  }

  /// "Original" or "192 kbps", as Settings lists a limit.
  static func label(_ bitRate: String) -> String {
    bitRate == sourceBitRate ? "Original" : "\(bitRate) kbps"
  }

  /// "in original quality" or "at 192 kbps", for a sentence.
  static func phrase(_ bitRate: String) -> String {
    bitRate == sourceBitRate ? "in original quality" : "at \(label(bitRate))"
  }
  /// The limit streams and the stream cache use on the network at hand; nil
  /// while streaming is off there. Only the phone tells cellular apart.
  static var streamingBitRate: String? { streamingBitRate(onCellular: AppPlatform.isOnCellular) }

  static func streamingBitRate(onCellular: Bool) -> String? {
    guard onCellular else { return UserDefaultsManager.maxBitRate }
    return UserDefaultsManager.streamOnCellular ? UserDefaultsManager.cellularBitRate : nil
  }

  /// Whether streams and the stream cache may use cellular data at all, so
  /// one started on Wi-Fi stalls instead of going on over cellular while
  /// "Stream on cellular" is off. Always true on the watch, which has no
  /// such setting.
  static var streamsOverCellular: Bool { streamingBitRate(onCellular: true) != nil }
  static let sourceFormat = "raw"
  static let targetFormat = "mp3"

  /// The format a download at `kbps` arrives in; nil for 0, the original file.
  static func convertedFormat(kbps: Int) -> String? {
    kbps > 0 ? targetFormat : nil
  }
}

/// "1 song", "3 songs".
func counted(_ count: Int, _ noun: String) -> String {
  "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// Prints verification traces in debug builds only.
func debugLog(_ message: @autoclosure () -> String) {
  #if DEBUG
    print("[flo-debug] \(message())")
  #endif
}
