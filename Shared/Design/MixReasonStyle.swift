//
//  MixReasonStyle.swift
//  flo
//

import SwiftUI

extension MixReason.Kind {
  var systemImage: String {
    switch self {
    case .history: "sparkles"
    case .liked: "heart.fill"
    case .rated: "star.fill"
    case .explore: "safari.fill"
    }
  }

  /// The design's category hue, one lightness and chroma per scheme: the
  /// Taste recipe's colours and the icons of the reasons.
  func color(_ scheme: ColorScheme) -> Color {
    let degrees: Double =
      switch self {
      case .history: 300
      case .liked: 15
      case .rated: 75
      case .explore: 190
      }
    let dark = scheme == .dark
    return CoverTint.color(
      hue: degrees * .pi / 180, lightness: dark ? 0.78 : 0.56, chroma: dark ? 0.12 : 0.15)
  }
}
