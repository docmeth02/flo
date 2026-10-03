//
//  Theme.swift
//  flo Watch App
//

import SwiftUI

extension Color {
  static let floSurface = Color(red: 0x1E / 255, green: 0x1E / 255, blue: 0x24 / 255)
  static let floSkeleton = Color(red: 0x2C / 255, green: 0x2C / 255, blue: 0x34 / 255)
  static let floLavender = Color(red: 0xA5 / 255, green: 0xA3 / 255, blue: 0xFF / 255)
  static let floIndigo = Color(red: 0x4A / 255, green: 0x47 / 255, blue: 0xB5 / 255)
  static let floSecondary = Color(red: 0xA1 / 255, green: 0xA0 / 255, blue: 0xAE / 255)
  /// Meta text on top of a cover.
  static let floOnCover = Color(red: 0xD6 / 255, green: 0xD5 / 255, blue: 0xDE / 255)
  static let floLiked = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
  static let floWarning = Color(red: 0xFF / 255, green: 0x9F / 255, blue: 0x0A / 255)
  static let floWarningText = Color(red: 0xFF / 255, green: 0xB3 / 255, blue: 0x40 / 255)
  static let floDownloaded = Color(red: 0x32 / 255, green: 0xD7 / 255, blue: 0x4B / 255)
  static let floDownloadedText = Color(red: 0x5E / 255, green: 0xE0 / 255, blue: 0x7A / 255)
  static let floDestructive = Color(red: 0xFF / 255, green: 0x69 / 255, blue: 0x61 / 255)
}

extension Font {
  private static func jakarta(_ size: CGFloat, _ weight: Font.Weight, _ style: Font.TextStyle)
    -> Font
  {
    .custom("Plus Jakarta Sans", size: size, relativeTo: style).weight(weight)
  }

  static let floWordmark = jakarta(20, .heavy, .title3)
  static let floTitle = jakarta(17, .bold, .headline)
  static let floSong = jakarta(15, .bold, .headline)
  static let floHero = jakarta(18, .bold, .headline)
  // Text styles rather than point sizes, so the watch's text size applies.
  static let floRow = Font.system(.subheadline, weight: .medium)
  static let floRowTitle = Font.system(.subheadline, weight: .semibold)
  static let floMeta = Font.system(.caption)
  static let floSection = Font.system(.footnote, weight: .semibold)
  static let floTime = Font.system(.caption2, weight: .semibold).monospacedDigit()
  static let floButton = Font.system(.subheadline, weight: .semibold)
}

/// Filled indigo capsule: Play, Play Something, Login.
struct FloPrimaryButtonStyle: ButtonStyle {
  var height: CGFloat = 44

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.floButton)
      .foregroundStyle(.white)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(Capsule().fill(Color.floIndigo))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

/// Surface capsule with a lavender label: Shuffle, Try Again.
struct FloTintedButtonStyle: ButtonStyle {
  var tint: Color = .floLavender
  var height: CGFloat = 44

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.floButton)
      .foregroundStyle(tint)
      .frame(maxWidth: .infinity, minHeight: height)
      .background(Capsule().fill(Color.floSurface))
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}

extension View {
  /// A list row on the rounded surface platter.
  func floRow(_ background: Color = .floSurface) -> some View {
    listRowBackground(
      RoundedRectangle(cornerRadius: 14, style: .continuous).fill(background)
    )
  }
}
