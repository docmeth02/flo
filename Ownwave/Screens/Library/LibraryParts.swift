//
//  LibraryParts.swift
//  Ownwave
//

import SwiftUI

/// An album's cover with its name and a line under it, opening the album:
/// Recently Played, the Library grid and an artist's albums. Without a
/// `width` it fills its grid column.
struct AlbumTile: View {
  let album: Album
  var subtitle: String?
  var width: CGFloat?

  @Environment(\.palette) private var palette

  var body: some View {
    NavigationLink(value: Route.album(album)) {
      VStack(alignment: .leading, spacing: 7) {
        CoverArt(albumId: album.id, radius: 14)
          .aspectRatio(1, contentMode: .fit)
        VStack(alignment: .leading, spacing: 1) {
          Text(album.name)
            .font(.rowSubtitle.weight(.semibold))
            .foregroundStyle(palette.text)
          Text(subtitle ?? album.albumArtist)
            .font(.meta)
            .foregroundStyle(palette.secondary)
        }
        .lineLimit(1)
      }
      .frame(width: width)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .itemMenu(.album(album))
  }
}

/// A cover blurred behind a screen's header, fading into the background.
/// It reaches up under the navigation bar, which the scroll content starts
/// below.
struct BlurredBackdrop: View {
  let albumId: String
  let height: CGFloat
  var opacity = 0.55

  @Environment(\.palette) private var palette

  private let underBar: CGFloat = 120

  var body: some View {
    CoverArt(albumId: albumId, radius: 0)
      .blur(radius: 40, opaque: true)
      .opacity(opacity)
      .overlay {
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0), .init(color: palette.background, location: 0.92),
          ],
          startPoint: .top, endPoint: .bottom)
      }
      .frame(height: height + underBar)
      .clipped()
      .offset(y: -underBar)
      .allowsHitTesting(false)
  }
}

extension View {
  /// One row on its own platter, as the design's library lists set them.
  func card() -> some View {
    modifier(Card())
  }
}

private struct Card: ViewModifier {
  @Environment(\.palette) private var palette

  func body(content: Content) -> some View {
    content
      .padding(.horizontal, 12)
      .padding(.vertical, 2)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}

extension SongCollection {
  /// Liked Songs as Home and Library play them, under the watch's id and name.
  static func liked(_ songs: [Song]) -> SongCollection {
    SongCollection(id: "starred-songs", name: "Liked Songs", songs: songs)
  }
}

extension [Song] {
  /// "12 songs · 48 min", empty while no song is loaded.
  var countAndLength: String {
    guard !isEmpty else { return "" }
    let minutes = Int((reduce(0) { $0 + $1.duration } / 60).rounded())
    return "\(counted(count, "song")) · \(minutes) min"
  }
}

extension Song {
  /// "3:45", as the track lists show it.
  var durationText: String {
    Duration.seconds(duration.isFinite ? duration : 0).formatted(.time(pattern: .minuteSecond))
  }
}
