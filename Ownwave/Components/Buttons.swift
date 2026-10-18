//
//  Buttons.swift
//  Ownwave
//

import SwiftUI

/// A filled capsule with an ink label: Play Something, Play, Sign in. The
/// fill is the palette's unless a cover tint is given.
struct FillButtonStyle: ButtonStyle {
  var tint: Color?
  var height: CGFloat = 52

  @Environment(\.palette) private var palette
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.buttonLabel)
      .tracking(Font.buttonTracking(17))
      // A cover tint is light in dark mode and dark in light mode, like the
      // fill, so the palette's ink suits both.
      .foregroundStyle(palette.ink)
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .background(tint ?? palette.fill, in: Capsule())
      .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

/// A capsule on the platter color with a text-colored label: Shuffle, Top
/// Songs, Artist Radio.
struct PlatterButtonStyle: ButtonStyle {
  var height: CGFloat = 52

  @Environment(\.palette) private var palette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.buttonLabel)
      .tracking(Font.buttonTracking(17))
      .foregroundStyle(palette.text)
      .frame(maxWidth: .infinity)
      .frame(height: height)
      .background(palette.surface, in: Capsule())
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}

/// A round button on a platter: the header's Watch and Settings buttons, the
/// album's download button.
struct CircleButtonStyle: ButtonStyle {
  var size: CGFloat = 44
  var foreground: Color?

  @Environment(\.palette) private var palette

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: size * 0.42, weight: .semibold))
      .foregroundStyle(foreground ?? palette.text)
      .frame(width: size, height: size)
      .background(palette.surface, in: Circle())
      .opacity(configuration.isPressed ? 0.7 : 1)
  }
}
