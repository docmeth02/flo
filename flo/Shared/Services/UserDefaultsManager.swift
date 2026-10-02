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
      return UserDefaults.standard.string(forKey: UserDefaultsKeys.enableMaxBitRate)
        ?? TranscodingSettings.sourceBitRate
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.enableMaxBitRate)
    }
  }


  static var saveLoginInfo: Bool {
    get {
      migrateIfNeeded(UserDefaultsKeys.saveLoginInfo)
      return sharedDefaults.bool(forKey: UserDefaultsKeys.saveLoginInfo)
    }

    set {
      sharedDefaults.set(newValue, forKey: UserDefaultsKeys.saveLoginInfo)
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

  /// Ratings set on the watch that the server has not confirmed yet, by
  /// playback id; 0 clears.
  static var pendingRatings: [String: Int] {
    get {
      return UserDefaults.standard.dictionary(forKey: UserDefaultsKeys.pendingRatings)
        as? [String: Int] ?? [:]
    }
    set {
      UserDefaults.standard.set(newValue, forKey: UserDefaultsKeys.pendingRatings)
    }
  }




}
