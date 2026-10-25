//
//  Theme.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

/// The watch's colors: the dark palette plus a few the phone does not use.
extension Color {
  static let floSurface = Palette.dark.surface
  /// Loading rows and the stand-in for a missing cover.
  static let floSkeleton = Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x2E / 255)
  static let floLilac = Palette.dark.fill
  /// Labels on a lilac or cover tinted fill, dark enough for both.
  static let floInk = Palette.dark.ink
  /// Behind white labels the system draws itself (swipe actions), where the
  /// light lilac would be unreadable; the brand's deep lilac.
  static let floLilacDeep = Palette.light.accent
  static let floText = Palette.dark.text
  /// The "wave" of the wordmark, a lighter lilac than the accent.
  static let floWave = Palette.dark.accent
  static let floSecondary = Palette.dark.secondary
  static let floWarningText = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255)
  static let floDownloadedText = Color(red: 0x5E / 255, green: 0xE0 / 255, blue: 0x7A / 255)
  /// Elapsed and remaining time on Now Playing.
  static let floTimeText = Color(red: 0xC4 / 255, green: 0xC3 / 255, blue: 0xCF / 255)
  /// Behind a lilac glyph tile.
  static let floTile = Color(red: 0x2D / 255, green: 0x2A / 255, blue: 0x43 / 255)
  /// Between rows joined on one platter.
  static let floRowHairline = Palette.dark.hairline
  /// Behind round buttons on a platter.
  static let floSurface2 = Palette.dark.surface2
}

/// Sizes shared by rows and their tiles.
enum FloLayout {
  /// How far the offline badge sits above the page dots: as far as the
  /// player's bottom row leaves room, 10 pt on the Ultra, less on 44-46 mm,
  /// none (over the dots) on 41-42 mm.
  static let offlineBadgeLift = min(
    10, max(0, (WKInterfaceDevice.current().screenBounds.height - 236) / 2))
  static let rowRadius: CGFloat = 14
  static let rowHeight: CGFloat = 44
  static let coverRowHeight: CGFloat = 52
  static let thumbnail: CGFloat = 36
  /// A row with a `tile` sized tile, which keeps the margins a default row
  /// keeps around its thumbnail.
  static func coverRowHeight(tile: CGFloat) -> CGFloat { tile + coverRowHeight - thumbnail }
  static let thumbnailRadius: CGFloat = 6
  /// Between a row's tile and its text.
  static let tileSpacing: CGFloat = 10
  /// The space watchOS keeps between two list rows, on every case size.
  static let listRowGap: CGFloat = 5
  /// A group of rows joined on one platter.
  static let platterRadius: CGFloat = 16
  /// The tile of a row on a joined platter.
  static let smallThumbnail: CGFloat = 30
  /// No vertical inset: the row's content keeps its margins.
  static let joinedRowInsets = EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 10)
  /// A joined row's hairline starts under its text.
  static let joinedHairlineInset = joinedRowInsets.leading + smallThumbnail + tileSpacing
  /// A row on a joined platter: its small tile with a cover row's margins.
  static let joinedRowHeight = coverRowHeight(tile: smallThumbnail)
  /// A tile of a grid such as Home's library: icon above label.
  static let tileHeight: CGFloat = 48
  static let roundButton: CGFloat = 30
  /// How far a pressed control fades.
  static let pressedOpacity: Double = 0.7
  /// How long a hold takes to open a row's menu or the rating dialog.
  static let holdDuration: Double = 0.5
}

extension Font {
  static let floWordmark = familjen(18, relativeTo: .title3)
  static let floSong = familjen(15, relativeTo: .headline)
  // Text styles rather than point sizes, so the watch's text size applies.
  static let floRow = Font.system(.subheadline, weight: .medium)
  static let floRowTitle = Font.system(.subheadline, weight: .semibold)
  static let floMeta = Font.system(.caption)
  static let floSection = Font.system(.footnote, weight: .semibold)
  /// Badges and small labels.
  static let floCaption = Font.system(.caption2, weight: .semibold)
  static let floTime = familjen(14, relativeTo: .caption2).monospacedDigit()
  static let floButton = familjen(16, relativeTo: .subheadline)
  static let floNavTitle = familjen(15, relativeTo: .headline)
  static let floButtonTracking = buttonTracking(16)
  /// Mono small caps labels: "NOW PLAYING", "NEXT · 14 SONGS".
  static let floCaps = mono(9, relativeTo: .caption2)
  /// A tile's label.
  static let floTile = Font.system(.footnote, weight: .semibold)
}

/// Filled capsule with an ink label: Play, Play Something, Login. Lilac,
/// or the cover tint on an album.
struct FloPrimaryButtonStyle: ButtonStyle {
  var fill: Color = .floLilac
  var height: CGFloat = 44

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.floButton)
      .tracking(Font.floButtonTracking)
      .foregroundStyle(Color.floInk)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(Capsule().fill(fill))
      .opacity(configuration.isPressed ? FloLayout.pressedOpacity : 1)
  }
}

/// Platter capsule with a tinted label: Try Again, Cancel.
struct FloTintedButtonStyle: ButtonStyle {
  var tint: Color = .floLilac
  var platter: Color = .floSurface
  var height: CGFloat = 44

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.floButton)
      .tracking(Font.floButtonTracking)
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(Capsule().fill(platter))
      .opacity(configuration.isPressed ? FloLayout.pressedOpacity : 1)
  }
}

/// A platter tile with its icon above its label (a `Label`): Home's library
/// grid leading, the hold menu's actions centered.
struct FloTileButtonStyle: ButtonStyle {
  var alignment: HorizontalAlignment = .leading
  var tint: Color = .floLilac
  var height = FloLayout.tileHeight

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .labelStyle(TileLabelStyle(alignment: alignment, tint: tint))
      .frame(
        maxWidth: .infinity, minHeight: height,
        alignment: Alignment(horizontal: alignment, vertical: .center)
      )
      .padding(.horizontal, 9)
      .background(
        RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous)
          .fill(Color.floSurface)
      )
      .contentShape(RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous))
      .opacity(configuration.isPressed ? FloLayout.pressedOpacity : 1)
  }
}

private struct TileLabelStyle: LabelStyle {
  let alignment: HorizontalAlignment
  let tint: Color

  func makeBody(configuration: Configuration) -> some View {
    VStack(alignment: alignment, spacing: 4) {
      configuration.icon
        .font(.system(size: 18))
        .foregroundStyle(tint)
      configuration.title
        .font(.floTile)
        .foregroundStyle(Color.floText)
        .lineLimit(1)
    }
  }
}

/// A round icon button: an album's Shuffle, the search card's Artist Radio.
struct FloRoundButtonStyle: ButtonStyle {
  var tint: Color = .floLilac
  var fill: Color = .floSurface2
  var size = FloLayout.roundButton

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .floRoundGlyph(tint: tint, fill: fill, size: size)
      .opacity(configuration.isPressed ? FloLayout.pressedOpacity : 1)
  }
}

/// Where a list row sits among the rows joined on one platter.
enum RowPosition {
  case alone, first, middle, last

  init(index: Int, count: Int) {
    self =
      count <= 1 ? .alone : index == 0 ? .first : index == count - 1 ? .last : .middle
  }

  fileprivate var roundsTop: Bool { self == .alone || self == .first }
  fileprivate var roundsBottom: Bool { self == .alone || self == .last }
}

/// Rows joined on one platter in a scroll view, with a hairline between
/// them from `hairlineInset`: an album's tracks, the hold menu's list. In a
/// List the rows join with `floJoinedRow` instead. Rows are told apart by
/// position, so an item may appear twice.
struct PlatterStack<Item, Row: View>: View {
  let items: [Item]
  let hairlineInset: CGFloat
  let row: (_ index: Int, _ item: Item) -> Row

  init(
    _ items: [Item], hairlineInset: CGFloat,
    @ViewBuilder row: @escaping (_ index: Int, _ item: Item) -> Row
  ) {
    self.items = items
    self.hairlineInset = hairlineInset
    self.row = row
  }

  var body: some View {
    VStack(spacing: 0) {
      ForEach(Array(items.enumerated()), id: \.offset) { index, item in
        if index > 0 {
          RowHairline(inset: hairlineInset)
        }
        row(index, item)
      }
    }
    .background(
      RoundedRectangle(cornerRadius: FloLayout.platterRadius, style: .continuous)
        .fill(Color.floSurface))
  }
}

/// The rule between two rows on one platter, starting under their text.
private struct RowHairline: View {
  let inset: CGFloat

  var body: some View {
    Color.floRowHairline
      .frame(height: 0.5)
      .padding(.leading, inset)
  }
}

extension View {
  /// A glyph on a disc, as a round button draws it.
  func floRoundGlyph(
    tint: Color = .floLilac, fill: Color = .floSurface2, size: CGFloat = FloLayout.roundButton
  ) -> some View {
    font(.system(size: size / 2, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: size, height: size)
      .background(Circle().fill(fill))
      .contentShape(Circle())
  }

  /// A list row joined with its neighbours on one platter: the group's outer
  /// corners rounded, a hairline over every row but the first. The platter
  /// reaches up over the gap watchOS leaves between rows, and the hairline
  /// sits in its middle. The list wants `.listStyle(.plain)`, or the system
  /// shrinks the rows at the screen's edges and the platter falls apart, and
  /// `.environment(\.defaultMinListRowHeight, 1)`, so a row is as low as its
  /// content (a `CoverRow` keeps its own margins); at 0 watchOS skips rows.
  func floJoinedRow(
    _ position: RowPosition, hairlineInset: CGFloat = FloLayout.joinedHairlineInset
  ) -> some View {
    let radius = FloLayout.platterRadius
    let shape = UnevenRoundedRectangle(
      topLeadingRadius: position.roundsTop ? radius : 0,
      bottomLeadingRadius: position.roundsBottom ? radius : 0,
      bottomTrailingRadius: position.roundsBottom ? radius : 0,
      topTrailingRadius: position.roundsTop ? radius : 0, style: .continuous)
    return
      self
      .listRowInsets(FloLayout.joinedRowInsets)
      .listRowBackground(
        ZStack(alignment: .top) {
          shape.fill(Color.floSurface)
          if !position.roundsTop {
            RowHairline(inset: hairlineInset)
              .offset(y: FloLayout.listRowGap / 2)
          }
        }
        .padding(.top, position.roundsTop ? 0 : -FloLayout.listRowGap)
      )
  }

  /// The navigation title in the title face and lilac; the string form of
  /// `navigationTitle` always uses the system font.
  func floNavigationTitle(_ title: String) -> some View {
    navigationTitle {
      Text(title).font(.floNavTitle).tracking(-0.01 * 15).foregroundStyle(Color.floLilac)
    }
  }

  /// A list row on the rounded surface platter.
  func floRow(_ background: Color = .floSurface) -> some View {
    listRowBackground(
      RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous).fill(background)
    )
  }
}
