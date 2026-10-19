//
//  WatchLinkProtocol.swift
//  Ownwave
//

import Foundation

/// What the iPhone and the watch tell each other over WatchConnectivity. Each
/// payload travels as JSON under one key, so neither side handles loose
/// dictionaries.
enum Link {
  /// Sent with `sendMessage` only: it needs the other app running, and the
  /// system never keeps a password around for later.
  enum Message: Codable, Equatable {
    case signIn(SignIn)
    case signInFailed(String)
  }

  struct SignIn: Codable, Equatable {
    let server: String
    let user: String
    let password: String
    /// The phone's account, so a watch signed in to it says so.
    let accountKey: String
  }

  /// The watch's immediate answer to a sign-in; the outcome follows as its
  /// next state or a `signInFailed` message.
  enum Reply: Codable, Equatable {
    case accepted
    case alreadySignedIn
    case otherAccount(user: String, host: String)
  }

  /// The phone's application context: the settings the watch follows while
  /// `share` is on, and the albums on their way.
  struct PhoneState: Codable, Equatable {
    let share: Bool
    /// The phone's cellular limit; the watch streams on its own link.
    let streamingBitRate: String
    let downloadBitRate: String
    let keepPlaying: Bool
    /// Nil from a phone before build 43.
    var downloadOverCellular: Bool? = nil
    /// The songs of each album the phone is sending; an album it gave up on
    /// drops out.
    var sending: [String: Int] = [:]
  }

  /// The watch's application context.
  struct WatchState: Codable, Equatable {
    struct Account: Codable, Equatable {
      let user: String
      let host: String
      let key: String
    }

    struct Collection: Codable, Equatable, Identifiable {
      let id: String
      let name: String
      let songs: Int
      /// Nil when its songs came at different bitrates.
      let kbps: Int?
      /// Songs the watch is still downloading itself; nil when none.
      var downloading: Int? = nil
    }

    var account: Account?
    var downloadBitRate = TranscodingSettings.defaultBitRate
    var collections: [Collection] = []
    /// Songs still expected from the phone, per collection.
    var incoming: [String: Int] = [:]
    var musicBytes: Int64 = 0
    var freeBytes: Int64 = 0
  }

  /// The metadata of a file sent to the watch.
  struct FileInfo: Codable, Equatable {
    enum Kind: String, Codable { case song, cover }

    let kind: Kind
    let accountKey: String
    let collectionId: String
    /// The songs the whole send brings, for the phone's progress after a
    /// relaunch.
    let songCount: Int
    /// Without its songs.
    let album: Album
    let song: Song?
    let suffix: String
    let kbps: Int
  }

  private static let key = "payload"

  static func encode(_ value: some Encodable) -> [String: Any] {
    guard let data = try? JSONEncoder().encode(value) else { return [:] }
    return [key: data]
  }

  static func decode<T: Decodable>(_ type: T.Type, from dictionary: [String: Any]) -> T? {
    guard let data = dictionary[key] as? Data else { return nil }
    return try? JSONDecoder().decode(type, from: data)
  }
}
