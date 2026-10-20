//
//  PinStore.swift
//  flo
//

import Foundation

/// Albums, artists, playlists and radios the user pinned to the top, stored
/// per account so another login sees its own pins and a logout loses nothing.
/// The watch lists pinned albums and artists; the phone all four.
@MainActor
final class PinStore: ObservableObject {
  enum Kind: String {
    case album, artist, playlist, radio
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

  /// The pinned ones of the lists: albums, artists, playlists, then
  /// stations, each in its list's order.
  func targets(
    albums: [Album], artists: [Artist] = [], playlists: [Playlist] = [], radios: [Radio] = []
  ) -> [MenuTarget] {
    func kept<T: Identifiable>(_ items: [T], _ kind: Kind) -> [T] where T.ID == String {
      let ids = pinned(kind)
      return ids.isEmpty ? [] : items.filter { ids.contains($0.id) }
    }
    return kept(albums, .album).map(MenuTarget.album)
      + kept(artists, .artist).map(MenuTarget.artist)
      + kept(playlists, .playlist).map(MenuTarget.playlist)
      + kept(radios, .radio).map(MenuTarget.radio)
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
