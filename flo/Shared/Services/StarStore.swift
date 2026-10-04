//
//  StarStore.swift
//  flo
//

import Foundation

/// Liked songs, albums and artists as the watch knows them: a like made here
/// shows at once and waits, across launches and offline spells, until the
/// server takes it.
@MainActor final class StarStore: ObservableObject {
  static let shared = StarStore()
}
