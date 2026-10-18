//
//  Theme.swift
//  flo Watch App
//

import SwiftUI

extension Color {
  static let floSurface = Color(red: 0x15 / 255, green: 0x14 / 255, blue: 0x23 / 255)
  /// Loading rows and the stand-in for a missing cover.
  static let floSkeleton = Color(red: 0x23 / 255, green: 0x23 / 255, blue: 0x2E / 255)
  static let floLilac = Color(red: 0xC4 / 255, green: 0xA4 / 255, blue: 0xFE / 255)
  /// Labels on a lilac or cover tinted fill, dark enough for both.
  static let floInk = Color(red: 0x12 / 255, green: 0x0E / 255, blue: 0x22 / 255)
  static let floText = Color(red: 0xF1 / 255, green: 0xF0 / 255, blue: 0xFC / 255)
  /// The "wave" of the wordmark, a lighter lilac than the accent.
  static let floWave = Color(red: 0xCA / 255, green: 0xAC / 255, blue: 0xFF / 255)
  static let floSecondary = Color(red: 0xA4 / 255, green: 0xA2 / 255, blue: 0xB7 / 255)
  /// Meta text on top of a cover.
  static let floOnCover = Color(red: 0xD6 / 255, green: 0xD5 / 255, blue: 0xDE / 255)
  static let floLiked = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
  static let floWarning = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
  static let floWarningText = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255)
  static let floDownloaded = Color(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255)
  static let floDownloadedText = Color(red: 0x5E / 255, green: 0xE0 / 255, blue: 0x7A / 255)
  static let floDestructive = Color(red: 0xFF / 255, green: 0x69 / 255, blue: 0x61 / 255)
  /// Elapsed and remaining time on Now Playing.
  static let floTimeText = Color(red: 0xC4 / 255, green: 0xC3 / 255, blue: 0xCF / 255)
  /// Behind a lilac glyph tile.
  static let floTile = Color(red: 0x2D / 255, green: 0x2A / 255, blue: 0x43 / 255)
  /// The rule between the pinned rows and the full list.
  static let floHairline = Color.white.opacity(0.14)
}

/// Sizes shared by rows and their tiles.
enum FloLayout {
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
  private static func familjen(_ size: CGFloat, _ style: Font.TextStyle) -> Font {
    .custom("Familjen Grotesk", size: size, relativeTo: style).weight(.semibold)
  }

  static let floWordmark = familjen(18, .title3)
  /// The playing song on the home screen.
  static let floTitle = familjen(17, .headline)
  static let floSong = familjen(15, .headline)
  static let floHero = familjen(18, .headline)
  // Text styles rather than point sizes, so the watch's text size applies.
  static let floRow = Font.system(.subheadline, weight: .medium)
  static let floRowTitle = Font.system(.subheadline, weight: .semibold)
  static let floMeta = Font.system(.caption)
  static let floSection = Font.system(.footnote, weight: .semibold)
  /// Badges and small labels.
  static let floCaption = Font.system(.caption2, weight: .semibold)
  static let floTime = familjen(14, .caption2).monospacedDigit()
  static let floButton = familjen(16, .subheadline)
  /// Button labels are set 0.02 em tighter, as in the design.
  static let floButtonTracking: CGFloat = -0.02 * 16
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

extension View {
  /// A list row on the rounded surface platter.
  func floRow(_ background: Color = .floSurface) -> some View {
    listRowBackground(
      RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous).fill(background)
    )
  }
}
