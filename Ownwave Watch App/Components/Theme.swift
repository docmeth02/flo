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
  /// Meta text on top of a cover.
  static let floOnCover = Color(red: 0xD6 / 255, green: 0xD5 / 255, blue: 0xDE / 255)
  static let floWarningText = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255)
  static let floDownloadedText = Color(red: 0x5E / 255, green: 0xE0 / 255, blue: 0x7A / 255)
  /// Elapsed and remaining time on Now Playing.
  static let floTimeText = Color(red: 0xC4 / 255, green: 0xC3 / 255, blue: 0xCF / 255)
  /// Behind a lilac glyph tile.
  static let floTile = Color(red: 0x2D / 255, green: 0x2A / 255, blue: 0x43 / 255)
  /// The rule between the pinned rows and the full list.
  static let floHairline = Color.white.opacity(0.14)
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
  static let thumbnailRadius: CGFloat = 6
  /// How far a pressed control fades.
  static let pressedOpacity: Double = 0.7
  /// How long a hold takes to open a row's menu or the rating dialog.
  static let holdDuration: Double = 0.5
}

extension Font {
  static let floWordmark = familjen(18, relativeTo: .title3)
  /// The playing song on the home screen.
  static let floTitle = familjen(17, relativeTo: .headline)
  static let floSong = familjen(15, relativeTo: .headline)
  static let floHero = familjen(18, relativeTo: .headline)
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

/// Platter capsule with a tinted label: Shuffle, Try Again.
struct FloTintedButtonStyle: ButtonStyle {
  var tint: Color = .floLilac
  var platter: Color = .floSurface
  var height: CGFloat = 44
  /// Menu rows are SF; buttons use the title face.
  var isMenuRow = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(isMenuRow ? .floRowTitle : .floButton)
      .tracking(isMenuRow ? 0 : Font.floButtonTracking)
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(Capsule().fill(platter))
      .opacity(configuration.isPressed ? FloLayout.pressedOpacity : 1)
  }
}

extension View {
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
