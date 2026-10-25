//
//  Palette.swift
//  flo
//

import SwiftUI

/// The Ownwave "Dusk" colors. The watch is always dark; the phone follows its
/// color scheme.
struct Palette {
  /// Behind everything, around the screens' background.
  let page: Color
  let background: Color
  /// Platters, rows and cards.
  let surface: Color
  /// Chips, glyph tiles and the track of a slider.
  let surface2: Color
  let text: Color
  let secondary: Color
  /// Titles, tab and toolbar tints, the wordmark's "wave".
  let accent: Color
  /// Filled buttons such as Play Something.
  let fill: Color
  /// Labels on `fill`.
  let ink: Color
  let hairline: Color

  static let dark = Palette(
    page: Color(hex: 0x030306), background: Color(hex: 0x080811), surface: Color(hex: 0x151423),
    surface2: Color(hex: 0x222234), text: Color(hex: 0xF1F0FC), secondary: Color(hex: 0xA4A2B7),
    accent: Color(hex: 0xCAACFF), fill: Color(hex: 0xC4A4FE), ink: Color(hex: 0x120E22),
    hairline: .white.opacity(0.09))

  static let light = Palette(
    page: Color(hex: 0xDEDDE6), background: Color(hex: 0xF1F1FA), surface: .white,
    surface2: Color(hex: 0xE4E3F0), text: Color(hex: 0x141327), secondary: Color(hex: 0x616174),
    accent: Color(hex: 0x5E4BC3), fill: Color(hex: 0x5E4BC3), ink: Color(hex: 0xFCFCFC),
    hairline: Color(hex: 0x1E143C).opacity(0.09))
}

/// The status colors, the same in both schemes.
extension Color {
  static let floLiked = Color(hex: 0xFF453A)
  static let floWarning = Color(hex: 0xFF9F0A)
  static let floDownloaded = Color(hex: 0x32D74B)
  static let floDestructive = Color(hex: 0xFF6961)

  init(hex: UInt32) {
    self.init(
      red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}

extension Font {
  /// The brand face for titles, the wordmark and button labels, scaling with
  /// the text style `style`.
  static func familjen(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
    .custom("Familjen Grotesk", size: size, relativeTo: style).weight(.semibold)
  }

  /// The mono face for counters, sizes and small caps labels, scaling with
  /// the text style `style`.
  static func mono(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
    .custom("JetBrainsMono-Medium", size: size, relativeTo: style)
  }

  /// Small counters and labels such as "Playing from" and the tour's "1 of 6".
  static let counter = mono(11, relativeTo: .caption2)

  /// Button labels are set 0.02 em tighter, as in the design.
  static func buttonTracking(_ size: CGFloat) -> CGFloat { -0.02 * size }
}
