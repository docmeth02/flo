//
//  UserDefaultsManager.swift
//  flo
//

import Foundation

class UserDefaultsManager {
  private static let sharedDefaults =
    UserDefaults(suiteName: "de.m2-entertainment.ownwave.settings") ?? UserDefaults.standard

  static func removeObject(key: String) {
    UserDefaults.standard.removeObject(forKey: key)
    sharedDefaults.removeObject(forKey: key)
  }

  static var serverBaseURL: String {
    get {
      // Endpoints start with "/"; a stored trailing slash would double it.
      var url = (sharedDefaults.string(forKey: UserDefaultsKeys.serverURL) ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      while url.hasSuffix("/") { url.removeLast() }
      return url
    }
    set {
      sharedDefaults.set(newValue, forKey: UserDefaultsKeys.serverURL)
    }
  }

  static var queueActiveIdx: Int {
    get {
      return UserDefaults.standard.integer(forKey: UserDefaultsKeys.queueActiveIdx)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.queueActiveIdx)
    }
  }

  static var nowPlayingProgress: Double {
    get {
      return UserDefaults.standard.double(forKey: UserDefaultsKeys.nowPlayingProgress)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.nowPlayingProgress)
    }
  }

  /// Listening time of the current song so far, kept across a relaunch.
  static var nowPlayingListened: Double {
    get {
      return UserDefaults.standard.double(forKey: UserDefaultsKeys.nowPlayingListened)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.nowPlayingListened)
    }
  }

  /// Whether the current song already counted as a play.
  static var nowPlayingQualified: Bool {
    get {
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.nowPlayingQualified)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.nowPlayingQualified)
    }
  }

  static var playbackMode: String {
    get {
      return UserDefaults.standard.string(forKey: UserDefaultsKeys.playbackMode)
        ?? PlaybackMode.defaultPlayback
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.playbackMode)
    }
  }

  static var maxBitRate: String {
    get {
      TranscodingSettings.offeredBitRate(
        UserDefaults.standard.string(forKey: UserDefaultsKeys.enableMaxBitRate))
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.enableMaxBitRate)
    }
  }

  /// The limit for downloads, from the same choices as streaming.
  static var downloadBitRate: String {
    get {
      TranscodingSettings.offeredBitRate(
        UserDefaults.standard.string(forKey: UserDefaultsKeys.downloadBitRate))
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.downloadBitRate)
    }
  }

  /// The phone's streaming limit on cellular, from the same choices.
  static var cellularBitRate: String {
    get {
      TranscodingSettings.offeredBitRate(
        UserDefaults.standard.string(forKey: UserDefaultsKeys.cellularBitRate))
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.cellularBitRate)
    }
  }

  /// Whether the phone streams on cellular at all. On by default.
  static var streamOnCellular: Bool {
    get { UserDefaults.standard.object(forKey: UserDefaultsKeys.streamOnCellular) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.streamOnCellular) }
  }

  /// Whether a smart mix's songs say why they were picked. On by default.
  static var showMixReasons: Bool {
    get { UserDefaults.standard.object(forKey: UserDefaultsKeys.showMixReasons) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.showMixReasons) }
  }

  /// The watch's bitrates and Keep Playing follow the iPhone's.
  static var settingsFollowPhone: Bool {
    get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.settingsFollowPhone) }
    set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.settingsFollowPhone) }
  }

  /// The iPhone shares its bitrates and Keep Playing with the watch. On by
  /// default.
  static var shareWatchSettings: Bool {
    get { UserDefaults.standard.object(forKey: UserDefaultsKeys.shareWatchSettings) as? Bool ?? true }
    set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.shareWatchSettings) }
  }

  /// Downloads may use cellular data: the watch's own link (Wi-Fi and the
  /// paired iPhone always can), or the iPhone's. Off by default.
  static var downloadOverCellular: Bool {
    get { UserDefaults.standard.bool(forKey: UserDefaultsKeys.downloadOverCellular) }
    set { UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.downloadOverCellular) }
  }

  static var streamCacheMaxSize: Int64 {
    get {
      let stored = UserDefaults.standard.object(forKey: UserDefaultsKeys.streamCacheMaxSize)
      return (stored as? Int64) ?? 500 * 1024 * 1024
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.streamCacheMaxSize)
    }
  }

  static var keepPlaying: Bool {
    get {
      return UserDefaults.standard.bool(forKey: UserDefaultsKeys.keepPlaying)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.keepPlaying)
    }
  }
}
