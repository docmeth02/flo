//
//  RoutePicker.swift
//  Ownwave
//

import AVKit
import SwiftUI

/// The system's AirPlay button on the header's round glass; a tap opens the
/// system's list of speakers and TVs.
struct RoutePicker: View {
  @Environment(\.palette) private var palette

  var body: some View {
    SystemButton(tint: UIColor(palette.text), activeTint: UIColor(palette.accent))
      .glassCircle()
      .accessibilityLabel("AirPlay")
  }

  private struct SystemButton: UIViewRepresentable {
    let tint: UIColor
    let activeTint: UIColor

    func makeUIView(context: Context) -> AVRoutePickerView {
      let view = AVRoutePickerView()
      view.prioritizesVideoDevices = false
      return view
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {
      view.tintColor = tint
      view.activeTintColor = activeTint
    }
  }
}
