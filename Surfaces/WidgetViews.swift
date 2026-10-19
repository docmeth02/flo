//
//  WidgetViews.swift
//  Ownwave
//

import SwiftUI
import WidgetKit

// The widgets' faces. They are compiled into the app as well, so its debug
// gallery can render them for screenshots. Widgets stay Dusk dark, as in the
// design's artboards, and pad themselves (the configurations disable the
// system's content margins) so both places lay them out alike.

private let palette = Palette.dark

extension WidgetSnapshot {
  /// The widget gallery's content, so it never asks to sign in.
  static let sample = WidgetSnapshot(
    signedIn: true,
    nowPlaying: .init(title: "Golden Hour", artist: "Low Tide", albumId: "sample-1"),
    recent: [
      .init(id: "sample-1", name: "Golden Hour"), .init(id: "sample-2", name: "Satellites"),
      .init(id: "sample-3", name: "Paper Moons"), .init(id: "sample-4", name: "Blue Rooms"),
    ])
}

extension View {
  /// A widget's background belongs to the system, which drops it on tinted
  /// and clear Home Screens; the app's gallery paints it itself.
  func widgetBackground(_ color: Color) -> some View {
    #if WIDGET_EXTENSION
      containerBackground(color, for: .widget)
    #else
      background(color)
    #endif
  }
}

/// The small Play Something tile: runs a smart mix without opening the app.
struct PlaySomethingWidgetView: View {
  let snapshot: WidgetSnapshot

  var body: some View {
    Group {
      if snapshot.signedIn {
        Button(intent: PlaySomethingNowIntent()) { tile }.buttonStyle(.plain)
      } else {
        tile.widgetURL(WidgetSnapshot.Link.home)
      }
    }
    .widgetBackground(palette.fill)
  }

  private var tile: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("Ownwave").font(.familjen(16, relativeTo: .headline)).tracking(-0.035 * 16)
        Spacer(minLength: 0)
        Image(systemName: "sparkles").font(.system(size: 22, weight: .medium))
      }
      Spacer(minLength: 0)
      Text("Play Something").font(.familjen(21, relativeTo: .title3)).lineLimit(2)
      Text(snapshot.signedIn ? "Smart mix" : "Sign in to Ownwave")
        .font(.footnote).opacity(0.75).lineLimit(1).padding(.top, 2)
    }
    .foregroundStyle(palette.ink)
    .widgetAccentable()
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .contentShape(Rectangle())
  }
}

/// The song playing, small (the cover filling the tile) or medium (cover and
/// text side by side). Opens Now Playing.
struct NowPlayingWidgetView: View {
  let snapshot: WidgetSnapshot
  let family: WidgetFamily

  @Environment(\.widgetRenderingMode) private var renderingMode

  var body: some View {
    Group {
      if !snapshot.signedIn {
        SignedOutWidgetView()
      } else if let song = snapshot.nowPlaying {
        playing(song).widgetURL(WidgetSnapshot.Link.nowPlaying)
      } else {
        nothingPlaying
      }
    }
    .widgetBackground(palette.surface)
  }

  @ViewBuilder private func playing(_ song: WidgetSnapshot.Song) -> some View {
    if family == .systemSmall {
      ZStack(alignment: .bottomLeading) {
        WidgetCover(albumId: song.albumId)
        // A tinted Home Screen would draw the shade as a flat veil.
        if renderingMode == .fullColor {
          LinearGradient(
            stops: [
              .init(color: .clear, location: 0.3), .init(color: .black.opacity(0.75), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
        }
        songText(song, titleSize: 17).padding(14)
      }
    } else {
      HStack(spacing: 14) {
        WidgetCover(albumId: song.albumId)
          .frame(width: 138, height: 138)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        songText(song, titleSize: 20).frame(maxHeight: .infinity, alignment: .bottomLeading)
      }
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func songText(_ song: WidgetSnapshot.Song, titleSize: CGFloat) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      NowPlayingLabel()
      Text(song.title).font(.familjen(titleSize, relativeTo: .headline))
        .lineLimit(family == .systemSmall ? 1 : 2)
      Text(song.artist).font(.footnote).opacity(0.75).lineLimit(1)
    }
    .foregroundStyle(palette.text)
    .widgetAccentable()
  }

  private var nothingPlaying: some View {
    HStack(spacing: 14) {
      if family != .systemSmall {
        WidgetCover(albumId: "")
          .frame(width: 138, height: 138)
          .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
      }
      VStack(alignment: .leading, spacing: 1) {
        NowPlayingLabel()
        Text("Nothing playing").font(.familjen(17, relativeTo: .headline))
          .foregroundStyle(palette.text).lineLimit(1)
        Spacer(minLength: 8)
        PlaySomethingPill()
      }
      .widgetAccentable()
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
  }
}

/// The four albums played last, each opening its album.
struct RecentlyPlayedWidgetView: View {
  let snapshot: WidgetSnapshot

  var body: some View {
    Group {
      if !snapshot.signedIn {
        SignedOutWidgetView()
      } else {
        VStack(alignment: .leading, spacing: 12) {
          HStack {
            Text("Recently Played").font(.familjen(15, relativeTo: .headline))
            Spacer(minLength: 0)
            BarsBadge()
          }
          if snapshot.recent.isEmpty {
            Text("Albums you play show up here.").font(.footnote).foregroundStyle(palette.secondary)
            Spacer(minLength: 0)
            PlaySomethingPill()
          } else {
            covers
          }
        }
        .foregroundStyle(palette.text)
        .widgetAccentable()
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
    }
    .widgetBackground(palette.surface)
  }

  /// Always four columns, so fewer albums keep their size.
  private var covers: some View {
    HStack(alignment: .top, spacing: 10) {
      ForEach(0..<4, id: \.self) { index in
        if snapshot.recent.indices.contains(index) {
          let album = snapshot.recent[index]
          SwiftUI.Link(destination: WidgetSnapshot.Link.album(album.id)) {
            VStack(alignment: .leading, spacing: 5) {
              WidgetCover(albumId: album.id)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
              Text(album.name).font(.caption2.weight(.semibold)).lineLimit(1)
            }
          }
        } else {
          Color.clear.aspectRatio(1, contentMode: .fit)
        }
      }
    }
  }
}

/// The app's seven bars and its name; opens the app.
struct LauncherWidgetView: View {
  var body: some View {
    VStack(spacing: 0) {
      Spacer(minLength: 0)
      WaveBars(height: 64).foregroundStyle(palette.fill)
      Spacer(minLength: 0)
      Text("Own\(Text("wave").foregroundStyle(palette.accent))").foregroundStyle(palette.text)
        .font(.familjen(18, relativeTo: .headline)).tracking(-0.035 * 18)
    }
    .widgetAccentable()
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .widgetURL(WidgetSnapshot.Link.home)
    .widgetBackground(palette.surface)
  }
}

/// What a widget shows before anyone signed in: tapping opens the app.
struct SignedOutWidgetView: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      BarsBadge()
      Spacer(minLength: 0)
      Text("Sign in to Ownwave").font(.familjen(17, relativeTo: .headline)).lineLimit(2)
    }
    .foregroundStyle(palette.text)
    .widgetAccentable()
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    .widgetURL(WidgetSnapshot.Link.home)
  }
}

/// An album cover the app left in the App Group, else a glyph tile.
private struct WidgetCover: View {
  let albumId: String

  var body: some View {
    let image = WidgetSnapshot.coverURL(albumId: albumId).flatMap {
      UIImage(contentsOfFile: $0.path)
    }
    Color.clear.overlay {
      if let image {
        Image(uiImage: image).resizable().widgetAccentedRenderingMode(.fullColor).scaledToFill()
      } else {
        GeometryReader { proxy in
          palette.surface2.overlay {
            Image(systemName: "music.note")
              .font(.system(size: min(proxy.size.width, proxy.size.height) * 0.3, weight: .medium))
              .foregroundStyle(palette.accent)
          }
        }
      }
    }
    .clipped()
  }
}

private struct NowPlayingLabel: View {
  var body: some View {
    Text("NOW PLAYING").font(.caption2.weight(.bold)).tracking(0.55)
      .foregroundStyle(palette.accent)
  }
}

/// Starts a mix from an empty widget.
private struct PlaySomethingPill: View {
  var body: some View {
    Button(intent: PlaySomethingNowIntent()) {
      Label("Play Something", systemImage: "sparkles")
        .font(.familjen(15, relativeTo: .subheadline))
        .lineLimit(1).minimumScaleFactor(0.8)
        .foregroundStyle(palette.ink)
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(palette.fill, in: Capsule())
    }
    .buttonStyle(.plain)
  }
}

/// The bars on a small lilac tile, as beside the design's widget titles.
private struct BarsBadge: View {
  var body: some View {
    WaveBars(height: 17)
      .foregroundStyle(palette.ink)
      .frame(width: 22, height: 22)
      .background(palette.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}

/// The app icon's seven bars, drawn in the foreground style.
private struct WaveBars: View {
  let height: CGFloat

  /// The icon's bar heights on its tallest bar of 79 units, 7 wide, 5 apart.
  private static let heights: [CGFloat] = [33, 64, 23, 79, 43, 59, 28]

  var body: some View {
    let unit = height / 79
    HStack(spacing: 5 * unit) {
      ForEach(Self.heights.indices, id: \.self) { index in
        Capsule().frame(width: 7 * unit, height: Self.heights[index] * unit)
      }
    }
  }
}
