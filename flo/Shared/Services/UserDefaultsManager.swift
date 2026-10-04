//
//  UserDefaultsManager.swift
//  flo
//
//  Created by rizaldy on 09/06/24.
//

import Foundation

class UserDefaultsManager {
  private static let sharedDefaults =
    UserDefaults(suiteName: "group.com.penerbangwalet.flo") ?? UserDefaults.standard

  private static func migrateIfNeeded(_ key: String) {
    let migrationKey = "migrated_\(key)"
    if !sharedDefaults.bool(forKey: migrationKey) {
      if let value = UserDefaults.standard.object(forKey: key) {
        sharedDefaults.set(value, forKey: key)
      }
      sharedDefaults.set(true, forKey: migrationKey)
    }
  }

  static func removeObject(key: String) {
    UserDefaults.standard.removeObject(forKey: key)
    sharedDefaults.removeObject(forKey: key)
  }

  static var serverBaseURL: String {
    get {
      migrateIfNeeded(UserDefaultsKeys.serverURL)
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


  static var streamCacheMaxSize: Int64 {
    get {
      let stored = UserDefaults.standard.object(forKey: UserDefaultsKeys.streamCacheMaxSize)
      return (stored as? Int64) ?? 524_288_000  // default 500 MB
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

  /// Ratings the server took from this watch that no refresh has stored in
  /// the cache yet, by playback id; the next successful refresh replaces them.
  static var confirmedRatings: [String: Int] {
    get {
      return UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.confirmedRatings)
        as? [String: Int] ?? [:]
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.confirmedRatings)
    }
  }




}
