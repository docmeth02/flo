//
//  LibraryOrdering.swift
//  flo
//

import Foundation

/// An order a sortable library list offers, stored by its raw value under
/// `storageKey`, so the phone and the watch name their choice the same way.
protocol LibraryOrder: RawRepresentable<String>, CaseIterable, Equatable {
  associatedtype Item: Equatable

  /// The `@AppStorage` key of the list's order.
  static var storageKey: String { get }
  var label: String { get }
  /// The items in this order; a tie falls back to the name.
  func sorted(_ items: [Item]) -> [Item]
}

enum AlbumOrder: String, LibraryOrder {
  case added, name, artist, year

  static let storageKey = "albumSort"

  var label: String {
    switch self {
    case .added: "Recently added"
    case .name: "A–Z"
    case .artist: "Artist"
    case .year: "Year"
    }
  }

  func sorted(_ albums: [Album]) -> [Album] {
    switch self {
    // An album without a date sorts last: the empty string is the smallest.
    case .added:
      albums.sorted {
        $0.createdAt == $1.createdAt ? $0.name.precedes($1.name) : $0.createdAt > $1.createdAt
      }
    case .name: albums.sorted { $0.name.precedes($1.name) }
    case .artist:
      albums.sorted {
        $0.albumArtist == $1.albumArtist
          ? $0.name.precedes($1.name) : $0.albumArtist.precedes($1.albumArtist)
      }
    case .year:
      albums.sorted {
        $0.minYear == $1.minYear ? $0.name.precedes($1.name) : $0.minYear > $1.minYear
      }
    }
  }
}

enum ArtistOrder: String, LibraryOrder {
  case name, albums

  static let storageKey = "artistSort"

  var label: String { self == .name ? "A–Z" : "Most albums" }

  func sorted(_ artists: [Artist]) -> [Artist] {
    switch self {
    case .name: artists.sorted { $0.name.precedes($1.name) }
    case .albums:
      artists.sorted {
        $0.albumCount == $1.albumCount
          ? $0.name.precedes($1.name) : $0.albumCount > $1.albumCount
      }
    }
  }
}

enum PlaylistOrder: String, LibraryOrder {
  case name, updated

  static let storageKey = "playlistSort"

  var label: String { self == .name ? "A–Z" : "Recently updated" }

  func sorted(_ playlists: [Playlist]) -> [Playlist] {
    switch self {
    case .name: playlists.sorted { $0.name.precedes($1.name) }
    case .updated:
      playlists.sorted {
        $0.updatedAt == $1.updatedAt ? $0.name.precedes($1.name) : $0.updatedAt > $1.updatedAt
      }
    }
  }
}

extension String {
  /// Ascending as Finder sorts names: case-insensitive, numbers by value.
  func precedes(_ other: String) -> Bool {
    localizedStandardCompare(other) == .orderedAscending
  }
}

/// The last value made from an input, kept while the input stays equal; an
/// array that is the same compares in constant time.
final class Memo<Input: Equatable, Value> {
  private var last: (input: Input, value: Value)?

  func value(for input: Input, make: (Input) -> Value) -> Value {
    if let last, last.input == input { return last.value }
    let value = make(input)
    last = (input, value)
    return value
  }
}

/// A list's last sort, kept while neither the list nor the order changes.
final class SortMemo<Order: LibraryOrder> {
  private struct Input: Equatable {
    let items: [Order.Item]
    let order: Order
  }

  private let memo = Memo<Input, [Order.Item]>()

  func sorted(_ items: [Order.Item], by order: Order) -> [Order.Item] {
    memo.value(for: Input(items: items, order: order)) { $0.order.sorted($0.items) }
  }
}

/// The artists under one index letter.
struct ArtistSection: Identifiable, Equatable {
  /// "A" to "Z", or "#" for a name that starts with anything else.
  let letter: String
  let artists: [Artist]

  var id: String { letter }
}

/// `artists` under the first letter of their name, "#" first and then A to
/// Z, each in the order given. Case and accents fold ("Ätna" is under A);
/// digits, punctuation and other scripts go under "#".
func artistSections(_ artists: [Artist]) -> [ArtistSection] {
  let other = "#"
  let grouped = Dictionary(grouping: artists) { artist -> String in
    guard let first = artist.name.trimmingCharacters(in: .whitespaces).first else { return other }
    let letter = String(first)
      .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
      .uppercased()
    return letter.count == 1 && ("A"..."Z").contains(letter) ? letter : other
  }
  // "#" sorts before the letters.
  return grouped.keys.sorted()
    .map { ArtistSection(letter: $0, artists: grouped[$0] ?? []) }
}
