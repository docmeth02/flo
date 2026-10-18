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

  /// Nothing while logged out.
  func pinned(_ kind: Kind) -> Set<String> {
    guard let key = key(kind) else { return [] }
    return Set(defaults.stringArray(forKey: key) ?? [])
  }

  func isPinned(_ id: String, _ kind: Kind) -> Bool {
    pinned(kind).contains(id)
  }

  func toggle(_ id: String, _ kind: Kind) {
    guard let key = key(kind) else { return }
    var ids = pinned(kind)
    if ids.remove(id) == nil { ids.insert(id) }
    objectWillChange.send()
    defaults.set(ids.sorted(), forKey: key)
  }

  private func key(_ kind: Kind) -> String? {
    account().map { "pins.\(kind.rawValue).\($0)" }
  }
}
