//
//  LibraryParts.swift
//  Ownwave
//

import SwiftUI

/// An album's cover with its name and a line under it, opening the album:
/// Recently Played, the Library grid, Search and an artist's albums. Without
/// a `width` it fills its grid column.
struct AlbumTile: View {
  let album: Album
  var subtitle: String?
  var width: CGFloat?
  var mark: Mark?

  /// A glyph after the line under the name.
  enum Mark {
    case downloaded, pinned
  }

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
          HStack(spacing: 4) {
            Text(subtitle ?? album.albumArtist)
            switch mark {
            case .downloaded:
              Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(Color.floDownloaded)
                .accessibilityLabel("Downloaded")
            case .pinned:
              Image(systemName: "pin.fill")
                .foregroundStyle(palette.accent)
                .accessibilityLabel("Pinned")
            case nil:
              EmptyView()
            }
          }
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

/// Albums two to a row, as the Library and Recently Played show them.
struct AlbumGrid: View {
  let albums: [Album]
  /// The albums on the phone, marked as downloaded.
  var downloaded: Set<String> = []

  var body: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18
    ) {
      ForEach(albums) { album in
        AlbumTile(album: album, mark: downloaded.contains(album.id) ? .downloaded : nil)
      }
    }
  }
}

/// A playlist with its mosaic cover and its length, for the Library and
/// Search.
struct PlaylistRow<Trailing: View>: View {
  let playlist: Playlist
  @ViewBuilder var trailing: Trailing

  @Environment(\.palette) private var palette

  /// "3 songs · 16 min"; the comment while the server gives no count.
  private var subtitle: String {
    guard playlist.songCount > 0 else {
      return playlist.comment.isEmpty ? "Playlist" : playlist.comment
    }
    let minutes = Int((playlist.duration / 60).rounded())
    return "\(counted(playlist.songCount, "song")) · \(minutes) min"
  }

  var body: some View {
    HStack(spacing: 12) {
      CoverArt(albumId: playlist.id, artId: playlist.artId, radius: 7)
        .frame(width: 46, height: 46)
      VStack(alignment: .leading, spacing: 2) {
        Text(playlist.name).font(.rowTitle).foregroundStyle(palette.text)
        Text(subtitle).font(.rowSubtitle).foregroundStyle(palette.secondary)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      trailing
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }
}

/// Rows on one platter like `Platter`, but made as they scroll into view,
/// for the Library's long lists. Every row but the first draws its hairline
/// with `hairlineAbove()`.
struct LazyPlatter<Content: View>: View {
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette

  var body: some View {
    LazyVStack(spacing: 0) { content }
      .padding(.horizontal, 12)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

extension View {
  /// The hairline over a row of a `LazyPlatter`, unless `shown` is false
  /// for its first row.
  func hairlineAbove(_ shown: Bool = true) -> some View {
    modifier(HairlineAbove(shown: shown))
  }
}

private struct HairlineAbove: ViewModifier {
  let shown: Bool

  @Environment(\.palette) private var palette

  func body(content: Content) -> some View {
    content.overlay(alignment: .top) {
      if shown { palette.hairline.frame(height: 1).padding(.leading, 12) }
    }
  }
}

/// A note under a list, such as the playlists' and the downloads' setting.
struct ListFooter: View {
  let text: String

  @Environment(\.palette) private var palette

  init(_ text: String) { self.text = text }

  var body: some View {
    Text(text)
      .font(.meta)
      .foregroundStyle(palette.secondary)
      .multilineTextAlignment(.center)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 8)
      .padding(.top, 12)
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

extension [Song] {
  /// "12 songs · 48 min", empty while no song is loaded.
  var countAndLength: String {
    guard !isEmpty else { return "" }
    let seconds = reduce(0) { $0 + ($1.duration.isFinite ? $1.duration : 0) }
    let minutes = Int((seconds / 60).rounded())
    return "\(counted(count, "song")) · \(minutes) min"
  }
}
