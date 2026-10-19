//
//  Rows.swift
//  Ownwave
//

import SwiftUI

/// What sits at the left of a row.
enum RowArt {
  case cover(albumId: String, url: String = "")
  case glyph(GlyphTile)
}

/// A list row: art, title and subtitle, and an optional trailing view. The
/// title takes the accent colour when the row is playing.
struct ItemRow<Trailing: View>: View {
  let art: RowArt
  let title: String
  var subtitle = ""
  var isPlaying = false
  var artSize: CGFloat = 48
  /// Two for subtitles that say more than an artist, such as a skip's.
  var subtitleLines = 1
  @ViewBuilder var trailing: Trailing

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 12) {
      switch art {
      case .cover(let albumId, let url):
        CoverArt(albumId: albumId, url: url, radius: 7).frame(width: artSize, height: artSize)
      case .glyph(let tile):
        tile.frame(width: artSize, height: artSize)
      }
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.rowTitle)
          .foregroundStyle(isPlaying ? palette.accent : palette.text)
          .lineLimit(1)
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
            .lineLimit(subtitleLines)
        }
      }
      Spacer(minLength: 0)
      trailing
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }
}

extension ItemRow where Trailing == EmptyView {
  init(art: RowArt, title: String, subtitle: String = "", isPlaying: Bool = false) {
    self.init(art: art, title: title, subtitle: subtitle, isPlaying: isPlaying) { EmptyView() }
  }
}

/// Rows on one platter with hairlines between them, as the design groups
/// lists.
struct Platter<Content: View>: View {
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(rows) { row in
          if row.id != rows.first?.id { palette.hairline.frame(height: 1).padding(.leading, 12) }
          row
        }
      }
    }
    .padding(.horizontal, 12)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

extension View {
  /// Content on its own platter: one row of a library list by default, or a
  /// Settings card with more room.
  func card(horizontal: CGFloat = 12, vertical: CGFloat = 2) -> some View {
    modifier(Card(horizontal: horizontal, vertical: vertical))
  }
}

private struct Card: ViewModifier {
  let horizontal: CGFloat
  let vertical: CGFloat

  @Environment(\.palette) private var palette

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, horizontal)
      .padding(.vertical, vertical)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

/// The song's progress as a thin bar in `tint`. It observes the clock
/// itself, so the screen around it does not redraw every second.
struct ProgressLine: View {
  @ObservedObject var clock: PlayerClock
  let tint: Color
  var track: Color?
  var height: CGFloat = 3

  @Environment(\.palette) private var palette

  var body: some View {
    GeometryReader { proxy in
      Capsule().fill(track ?? palette.hairline)
        .overlay(alignment: .leading) {
          Capsule().fill(tint).frame(width: proxy.size.width * clock.clampedProgress)
        }
    }
    .frame(height: height)
  }
}

/// Loading, empty and failed states of a list, with Try Again.
struct StateView: View {
  enum Kind {
    case loading
    case empty(String)
    case error(String, retry: () -> Void)
  }

  let kind: Kind

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 12) {
      switch kind {
      case .loading:
        ProgressView()
      case .empty(let text):
        Text(text).foregroundStyle(palette.secondary)
      case .error(let text, let retry):
        Text(text).foregroundStyle(palette.secondary).multilineTextAlignment(.center)
        Button("Try Again", action: retry)
          .buttonStyle(PlatterButtonStyle(height: 44))
          .frame(maxWidth: 200)
      }
    }
    .font(.rowSubtitle)
    .frame(maxWidth: .infinity)
    .padding(.vertical, 40)
  }
}
