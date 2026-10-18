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

/// The latest mixes, newest first. The newest few are kept on disk for the
/// account, so a queue built by a mix still says why after a relaunch.
@MainActor final class RecommendationLog: ObservableObject {
  static let shared = RecommendationLog()

  private static let capacity = 20
  private static let keptOnDisk = 5
  nonisolated private static let fileURL = URL.applicationSupportDirectory
    .appendingPathComponent("recent-mixes.json")

  /// What the file holds: the mixes of one account.
  struct Saved: Codable, Sendable {
    let account: String
    let mixes: [MixRecord]
  }

  @Published private(set) var mixes: [MixRecord] = [] {
    didSet { reasons = Self.reasons(of: mixes) }
  }
  private var reasons: [String: MixReason] = [:]

  private init() {
    if let account = AuthService.shared.accountKey, let data = try? Data(contentsOf: Self.fileURL) {
      mixes = Self.restore(data, account: account)
    }
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in
        RecommendationLog.shared.mixes = []
        try? FileManager.default.removeItem(at: RecommendationLog.fileURL)
      }
    }
  }

  func record(_ mix: MixRecord) {
    mixes.insert(mix, at: 0)
    if mixes.count > Self.capacity { mixes.removeLast(mixes.count - Self.capacity) }
    guard let account = AuthService.shared.accountKey else { return }
    let saved = Saved(account: account, mixes: Array(mixes.prefix(Self.keptOnDisk)))
    Task.detached(priority: .utility) {
      do {
        try FileManager.default.createDirectory(
          at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(saved).write(to: Self.fileURL, options: .atomic)
      } catch {
        debugLog("mix log not saved: \(error)")
      }
    }
  }

  /// Why the newest mix holding the song picked it.
  func reason(for songId: String) -> MixReason? {
    reasons[songId]
  }

  /// The saved mixes, if they are the account's.
  nonisolated static func restore(_ data: Data, account: String) -> [MixRecord] {
    guard let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.account == account
    else { return [] }
    return saved.mixes
  }

  private static func reasons(of mixes: [MixRecord]) -> [String: MixReason] {
    var reasons: [String: MixReason] = [:]
    for pick in mixes.reversed().flatMap(\.picks) { reasons[pick.songId] = pick.why }
    return reasons
  }
}
