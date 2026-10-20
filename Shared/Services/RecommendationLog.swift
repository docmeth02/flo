//
//  RecommendationLog.swift
//  flo
//

import Foundation

/// One generated mix and why each song made it.
struct MixRecord: Codable, Sendable {
  let at: Date
  let mode: String
  let picks: [Pick]
  let eligible: Int
  let exploreShare: Double
  let notes: [String]

  struct Pick: Codable, Sendable {
    /// "preferred" or "explore".
    let slot: String
    let songId: String
    let title: String
    let artist: String
    /// For the listener.
    let why: MixReason
    /// For diagnostics, like `scores`.
    let reason: String
    let scores: String
  }
}

/// The latest mixes of this launch, newest first, and apart from them the
/// ones that played: those say why their songs were picked and are kept on
/// disk for the account, so a queue built by a mix still says so after a
/// relaunch.
@MainActor final class RecommendationLog: ObservableObject {
  static let shared = RecommendationLog()

  private static let capacity = 20
  private static let keptOnDisk = 5
  nonisolated private static let fileURL = URL.applicationSupportDirectory
    .appendingPathComponent("recent-mixes.json")
  // One writer, so the file ends up as the newest save or removed on logout.
  nonisolated private static let io = DispatchQueue(label: "flo.recentMixes", qos: .utility)

  /// What the file holds: the mixes of one account.
  struct Saved: Codable, Sendable {
    let account: String
    let mixes: [MixRecord]
  }

  /// Every mix built, for diagnostics.
  @Published private(set) var mixes: [MixRecord] = []
  /// The mixes that were queued, newest first.
  @Published private(set) var played: [MixRecord] = []

  private init() {
    if let account = AuthService.shared.accountKey, let data = try? Data(contentsOf: Self.fileURL) {
      played = Self.restore(data, account: account)
    }
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in
        RecommendationLog.shared.mixes = []
        RecommendationLog.shared.played = []
        Self.io.async { try? FileManager.default.removeItem(at: Self.fileURL) }
      }
    }
  }

  func record(_ mix: MixRecord) {
    mixes.insert(mix, at: 0)
    if mixes.count > Self.capacity { mixes.removeLast(mixes.count - Self.capacity) }
  }

  /// The mix was queued: its songs now say why they play.
  func markPlayed(_ mix: MixRecord) {
    guard let account = AuthService.shared.accountKey else { return }
    played = Array(([mix] + played).prefix(Self.keptOnDisk))
    let saved = Saved(account: account, mixes: played)
    Self.io.async {
      do {
        try FileManager.default.createDirectory(
          at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: Self.fileURL, options: .atomic)
      } catch {
        debugLog("played mixes not saved: \(error)")
      }
    }
  }

  /// Why the newest played mix holding the song picked it.
  func reason(for songId: String) -> MixReason? {
    for mix in played {
      if let pick = mix.picks.first(where: { $0.songId == songId }) { return pick.why }
    }
    return nil
  }

  /// Why a mix queued the entry, while the listener wants to see it.
  func shownReason(for entry: QueueEntity) -> MixReason? {
    guard UserDefaultsManager.showMixReasons,
      entry.playbackOrigin.isMix, let id = entry.id
    else { return nil }
    return reason(for: id)
  }

  /// The saved mixes, if they are the account's.
  nonisolated static func restore(_ data: Data, account: String) -> [MixRecord] {
    guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.account == account
    else { return [] }
    return saved.mixes
  }
}
