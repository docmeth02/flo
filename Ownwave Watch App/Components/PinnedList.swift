//
//  PinnedList.swift
//  Ownwave Watch App
//

import SwiftUI

/// List sections for a library list with pins: the pinned items under
/// "Pinned", then every item, the pinned ones again in their place, under
/// `allLabel`. Without pins only the full list shows.
struct PinnedList<Item: Identifiable, Rows: View>: View where Item.ID == String {
  @EnvironmentObject private var pinStore: PinStore

  let items: [Item]
  let kind: PinStore.Kind
  /// Nil when the full list brings sections of its own.
  var allLabel: String?
  /// The rows of `items`; `isPinnedPart` for the pinned ones on top, which
  /// sit in a section already.
  @ViewBuilder let rows: (_ items: [Item], _ isPinnedPart: Bool) -> Rows

  var body: some View {
    // A pinned item gone from the library leaves no empty section.
    let ids = pinStore.pinned(kind)
    let pinned = items.filter { ids.contains($0.id) }
    if pinned.isEmpty {
      rows(items, false)
    } else {
      Section {
        rows(pinned, true)
      } header: {
        FloSectionHeader("Pinned")
      }
      if let allLabel {
        Section {
          rows(items, false)
        } header: {
          FloSectionHeader(allLabel)
        }
      } else {
        rows(items, false)
      }
    }
  }
}

extension FloLayout {
  /// A row on a joined platter: its small tile with a cover row's margins.
  static let joinedRowHeight = smallThumbnail + coverRowHeight - thumbnail
}

/// `row` for each item, each its own list row, joined on one platter.
struct JoinedRows<Item: Identifiable, Row: View>: View {
  let items: [Item]
  @ViewBuilder let row: (Item) -> Row

  var body: some View {
    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
      row(item).floJoinedRow(RowPosition(index: index, count: items.count))
    }
  }
}

/// An album, artist, playlist or song on a joined platter: its cover or
/// glyph, the name on up to two lines, a meta line, and the pin of a pinned
/// item. A tap runs `open`, a hold opens its menu.
struct LibraryRow: View {
  @EnvironmentObject private var pinStore: PinStore

  let target: MenuTarget
  /// For a row that opens a list of its own, such as a playlist.
  var showsChevron = false
  @Binding var menu: MenuTarget?
  let open: () -> Void

  private var isPinned: Bool {
    target.pin.map { pinStore.isPinned($0.id, $0.kind) } ?? false
  }

  var body: some View {
    CoverRow(
      tile: Self.tile(target), title: target.title, subtitle: subtitle, titleLineLimit: 2,
      tileSize: FloLayout.smallThumbnail
    ) {
      if isPinned {
        PinGlyph()
      } else if showsChevron {
        Chevron()
      }
    }
    .holdable(onTap: open, onHold: { menu = target })
  }

  private var subtitle: String {
    switch target {
    case .playlist(let playlist): songsAndLength(playlist.songCount, seconds: playlist.duration)
    default: target.subtitle
    }
  }

  static let radioGlyph = "dot.radiowaves.up.forward"

  /// The cover or glyph of `target`, for any cover row.
  static func tile<Trailing>(_ target: MenuTarget) -> CoverRow<Trailing>.Tile {
    switch target {
    case .song(let song, _, _): .cover(albumId: song.albumId)
    case .album(let album): .cover(albumId: album.id)
    case .artist: .artist
    case .playlist(let playlist): .cover(albumId: playlist.id, artId: playlist.artId)
    case .radio: .glyph(radioGlyph, round: true)
    }
  }
}

/// The trailing mark of a pinned row.
struct PinGlyph: View {
  var body: some View {
    Image(systemName: "pin.fill")
      .font(.system(size: 13))
      .foregroundStyle(Color.floLilac)
      .accessibilityLabel("Pinned")
  }
}
