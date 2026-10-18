//
//  RecommendationLog.swift
//  flo
//

import Foundation

/// One generated mix and why each song made it, for diagnostics.
struct MixRecord: Sendable {
  let at: Date
  let mode: String
  let picks: [Pick]
  let eligible: Int
  let exploreShare: Double
  let notes: [String]

  struct Pick: Sendable {
    /// "preferred" or "explore".
    let slot: String
    let title: String
    let artist: String
    let reason: String
    let scores: String
  }
}

/// The latest mixes of this launch, newest first.
@MainActor final class RecommendationLog: ObservableObject {
  static let shared = RecommendationLog()

  private static let capacity = 20

  @Published private(set) var mixes: [MixRecord] = []

  private init() {
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in RecommendationLog.shared.mixes = [] }
    }
  }

  func record(_ mix: MixRecord) {
    mixes.insert(mix, at: 0)
    if mixes.count > Self.capacity { mixes.removeLast(mixes.count - Self.capacity) }
  }
}
