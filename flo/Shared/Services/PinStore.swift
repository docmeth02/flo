//
//  PinStore.swift
//  flo
//

import Foundation

/// Albums and artists the user pinned to the top of their lists, stored per
/// account so another login sees its own pins and a logout loses nothing.
@MainActor
final class PinStore: ObservableObject {
  enum Kind: String {
    case album, artist
  }

  static let shared = PinStore()

  private let defaults: UserDefaults
  private let account: () -> String?

  /// `defaults` and `account` are for tests.
  init(
    defaults: UserDefaults = .standard,
    account: @escaping () -> String? = { AuthService.shared.accountKey }
  ) {
    self.defaults = defaults
    self.account = account
  }

  func pinned(_ kind: Kind) -> Set<String> { [] }

  func isPinned(_ id: String, _ kind: Kind) -> Bool { false }

  func toggle(_ id: String, _ kind: Kind) {}
}
