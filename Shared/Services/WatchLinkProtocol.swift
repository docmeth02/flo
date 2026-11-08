//
//  WatchLinkProtocol.swift
//  Ownwave
//

import Foundation
import WatchConnectivity

/// What the iPhone and the watch tell each other over WatchConnectivity. Each
/// payload travels as JSON under one key, so neither side handles loose
/// dictionaries.
enum Link {
  /// Sent with `sendMessage` only: it needs the other app running, and the
  /// system never keeps a password around for later.
  enum Message: Codable, Equatable {
    case signIn(SignIn)
    case signInFailed(String)
    /// Playback moving to the other device; it answers with a `Reply`.
    case play(Handoff)
    /// How the start of a handoff went, once that is known.
    case handoffResult(id: UUID, result: HandoffResult)
  }

  /// The queue the sending device was playing, for the other one to take over.
  struct Handoff: Codable, Equatable {
    let id: UUID
    /// The sender's account; another one's queue is not taken.
    let accountKey: String
    let snapshot: QueueSnapshot
  }

  enum HandoffResult: Codable, Equatable {
    /// Playing on the receiver: the sender pauses.
    case started
    /// Queued on the receiver, paused: it could not start the audio.
    case ready
    case failed(String)
  }

  /// The encoded size a handoff's snapshot keeps under; the system's limit
  /// for a message is not documented.
  static let handoffBudget = 48_000

  /// The other device, as the texts about it name it.
  enum Peer {
    case iPhone, watch

    /// "the watch", "your iPhone", inside a sentence.
    var name: String {
      switch self {
      case .iPhone: "your iPhone"
      case .watch: "the watch"
      }
    }

    /// "The watch", "Your iPhone", at the start of one.
    var title: String {
      switch self {
      case .iPhone: "Your iPhone"
      case .watch: "The watch"
      }
    }
  }

  struct SignIn: Codable, Equatable {
    let server: String
    let user: String
    let password: String
    /// The phone's account, so a watch signed in to it says so.
    let accountKey: String
  }

  /// The immediate answer to a sign-in or a handoff. A sign-in's outcome
  /// follows as the watch's next state or a `signInFailed` message, a
  /// handoff's as a `handoffResult`.
  enum Reply: Codable, Equatable {
    case accepted
    case alreadySignedIn
    case otherAccount(user: String, host: String)
    /// The handed-over song can neither play from the device nor stream.
    case unavailable
    case notSignedIn
  }

  /// Why `peer` is of no use to this account. Without a user or host it
  /// could tell, the account goes unnamed.
  static func otherAccountMessage(user: String, host: String, on peer: Peer = .watch) -> String {
    guard !user.isEmpty, !host.isEmpty else {
      return "\(peer.title) is signed in to another account. Log out there first."
    }
    return "\(peer.title) is signed in as \(user) on \(host). Log out there first."
  }

  /// What the sender of a handoff says when the other device did not take
  /// over; nil for an answer that took it.
  static func handoffMessage(_ reply: Reply?, peer: Peer) -> String? {
    switch reply {
    case .accepted: nil
    case .unavailable: "The song cannot play on \(peer.name) right now."
    case .notSignedIn: "Sign in to Ownwave on \(peer.name) first."
    case .otherAccount(let user, let host): otherAccountMessage(user: user, host: host, on: peer)
    case .alreadySignedIn, nil: "\(peer.title) did not answer."
    }
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
    /// A `MixRanker.Variety`; nil from a phone before build 47.
    var mixVariety: String? = nil
    /// "Why this song"; nil from a phone before build 48.
    var showMixReasons: Bool? = nil
    /// The phone takes and sends handoffs; nil from a phone before build 51.
    var handoff: Bool? = nil
    /// "Sync queue"; nil from a phone before build 51.
    var syncQueue: Bool? = nil
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
    /// The watch takes and sends handoffs; nil from a watch before build 51.
    var handoff: Bool? = nil
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

extension WCSession {
  /// Sends `message` to the other app, which must be reachable, and returns
  /// its reply; nil for one this build cannot read.
  func request(_ message: Link.Message) async throws -> Link.Reply? {
    try await withCheckedThrowingContinuation { continuation in
      sendMessage(Link.encode(message)) { reply in
        continuation.resume(returning: Link.decode(Link.Reply.self, from: reply))
      } errorHandler: {
        continuation.resume(throwing: $0)
      }
    }
  }

  /// Sends `message` without waiting for an answer; a failure is noted.
  func post(_ message: Link.Message) {
    sendMessage(Link.encode(message), replyHandler: nil) { error in
      RequestLog.shared.note("link: message not sent: \(error.localizedDescription)")
    }
  }
}
