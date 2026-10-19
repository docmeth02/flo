//
//  Theme.swift
//  Ownwave
//

import SwiftUI

extension EnvironmentValues {
  /// The palette of the color scheme in use; set by RootView.
  @Entry var palette = Palette.dark
}

/// The phone's type scale: the brand face for titles and buttons, SF text
/// styles for everything people read, so Dynamic Type applies.
extension Font {
  /// Screen titles such as Library and Your Taste.
  static let pageTitle = familjen(34, relativeTo: .largeTitle)
  /// Album, artist and playlist names over their header.
  static let heroTitle = familjen(26, relativeTo: .title)
  /// Section headers: Pinned, Recently Played, Top Songs.
  static let sectionTitle = familjen(21, relativeTo: .title2)
  /// The song on Now Playing.
  static let playerTitle = familjen(24, relativeTo: .title2)
  static let buttonLabel = familjen(17, relativeTo: .headline)
  static let wordmark = familjen(26, relativeTo: .title)
  static let rowTitle = Font.system(.body, weight: .medium)
  static let rowSubtitle = Font.system(.subheadline)
  static let meta = Font.system(.footnote)
  /// Small counters and labels such as "Playing from" and the tour's "1 of 6".
  static let counter = Font.custom("JetBrainsMono-Medium", size: 11, relativeTo: .caption2)
}

/// The app's name, "Own" in the text color and "wave" in the accent.
struct Wordmark: View {
  @Environment(\.palette) private var palette

  var body: some View {
    let own = Text("Own").foregroundStyle(palette.text)
    let wave = Text("wave").foregroundStyle(palette.accent)
    Text("\(own)\(wave)")
      .font(.wordmark)
      .tracking(-0.035 * 26)
  }
}

/// A screen's own large title, as in the design (not the navigation bar's).
struct PageTitle: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.pageTitle)
      .tracking(-0.02 * 34)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
  }
}

struct SectionTitle: View {
  let text: String

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.sectionTitle)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
  }
}
