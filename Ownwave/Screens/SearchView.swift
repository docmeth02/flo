//
//  SearchView.swift
//  Ownwave
//

import SwiftUI

/// Searches the artists, albums and songs already on the phone, so it works
/// offline; the artist, album and playlist lists are refreshed as the
/// Library does. Pinned items that match come first, marked with a pin.
struct SearchView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var albums: AlbumViewModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var pins: PinStore
  @Environment(\.palette) private var palette

  /// The last queries, newest first, one per line.
  @AppStorage("recentSearches") private var storedRecents = ""
  @State private var query = ""
  /// The cached song library, nil until it is read.
  @State private var songs: [Song]?
  /// Nil while there is nothing to search.
  @State private var found: Found?

  private static let maxRecents = 8

  /// What a search depends on: it runs again when the query or a list
  /// changes.
  private struct Input: Equatable {
    let query: String
    let artists: Int
    let albums: Int
    let songs: Int?
  }

  /// The results of the query that was searched, which lags the typed one.
  private struct Found {
    let query: String
    let results: LibrarySearch.Results
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        if let found {
          results(found)
        } else if !recents.isEmpty {
          VStack(alignment: .leading, spacing: 10) {
            header("Recent")
            FlowLayout(spacing: 8) {
              ForEach(recents, id: \.self) { recent in
                Button(recent) { query = recent }
                  .font(.rowSubtitle)
                  .foregroundStyle(palette.text)
                  .padding(.horizontal, 15)
                  .padding(.vertical, 9)
                  .background(palette.surface, in: Capsule())
                  .buttonStyle(.plain)
              }
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .scrollDismissesKeyboard(.immediately)
    // The system search field stands in for the design's own; shown all
    // the time, it leaves the bar only an inline title.
    .navigationTitle("Search")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(
      text: $query, placement: .navigationBarDrawer(displayMode: .always),
      prompt: "Artists, albums, songs")
    .onSubmit(of: .search) { remember(query) }
    .task {
      albums.getArtists()
      albums.fetchAlbums()
      albums.getPlaylists()
      // Once: the view reappears after every pushed album or artist.
      guard songs == nil else { return }
      songs = await SmartPlaybackService.shared.loadCachedLibrary().songs
    }
    .task(
      id: Input(
        query: query, artists: albums.artists.count, albums: albums.albums.count,
        songs: songs?.count)
    ) {
      guard let songs else { return }
      // Typing restarts this task; only a query left alone for a moment is
      // searched, so no scan runs for every keystroke.
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      let (query, artists, albumList) = (query, albums.artists, albums.albums)
      let results = await Task.detached {
        LibrarySearch.search(
          query, artists: artists, albums: albumList, songs: songs, limits: .phone)
      }.value
      guard !Task.isCancelled else { return }
      found = results.map { Found(query: query, results: $0) }
    }
  }

  private var recents: [String] {
    storedRecents.split(separator: "\n").map(String.init)
  }

  /// Keeps `query` at the front of the recent queries.
  private func remember(_ query: String) {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    let others = recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
    storedRecents = ([query] + others).prefix(Self.maxRecents).joined(separator: "\n")
  }

  @ViewBuilder
  private func results(_ found: Found) -> some View {
    let results = found.results
    let pinnedAlbums = pins.pinned(.album)
    let pinnedArtists = pins.pinned(.artist)
    let pinnedPlaylists = pins.pinned(.playlist)
    let pinned: [MenuTarget] =
      results.artists.filter { pinnedArtists.contains($0.id) }.map(MenuTarget.artist)
      + results.albums.filter { pinnedAlbums.contains($0.id) }.map(MenuTarget.album)
      + albums.playlists
      .filter { pinnedPlaylists.contains($0.id) && $0.name.localizedStandardContains(found.query) }
      .map(MenuTarget.playlist)
    let otherArtists = results.artists.filter { !pinnedArtists.contains($0.id) }
    let otherAlbums = results.albums.filter { !pinnedAlbums.contains($0.id) }

    if pinned.isEmpty, otherArtists.isEmpty, otherAlbums.isEmpty, results.songs.isEmpty {
      Text("Nothing on the server matches \u{201C}\(found.query)\u{201D}.")
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    group("Pinned", pinned, pinned: true)
    group("Artists", otherArtists.map(MenuTarget.artist))
    group("Albums", otherAlbums.map(MenuTarget.album))
    group(
      "Songs", results.songs.map { MenuTarget.song($0, context: "Search", isFromPlaylist: false) })
  }

  @ViewBuilder
  private func group(_ title: String, _ targets: [MenuTarget], pinned: Bool = false) -> some View {
    if !targets.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        header(title)
        ForEach(targets) { row($0, pinned: pinned) }
      }
    }
  }

  private func header(_ title: String) -> some View {
    Text(title)
      .font(.rowSubtitle.weight(.semibold))
      .foregroundStyle(palette.secondary)
      .padding(.horizontal, 4)
  }

  @ViewBuilder
  private func row(_ target: MenuTarget, pinned: Bool) -> some View {
    let label = ItemRow(
      art: art(target), title: target.title, subtitle: target.subtitle,
      isPlaying: isPlaying(target), artSize: 44
    ) {
      if pinned {
        Image(systemName: "pin.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(palette.accent)
          .padding(.trailing, 4)
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 2)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

    Group {
      if case .song(let song, _, _) = target {
        Button {
          remember(query)
          let search = SongCollection(id: "search", name: "Search", songs: [song])
          if player.playItem(item: search) { app.isNowPlayingPresented = true }
        } label: {
          label
        }
      } else if let route = route(target) {
        NavigationLink(value: route) { label }
          .simultaneousGesture(TapGesture().onEnded { remember(query) })
      }
    }
    .buttonStyle(.plain)
    .itemMenu(target)
  }

  private func art(_ target: MenuTarget) -> RowArt {
    switch target {
    case .song(let song, _, _): .cover(albumId: song.albumId)
    case .album(let album): .cover(albumId: album.id)
    case .artist: .glyph(.artist)
    case .playlist: .glyph(.playlist)
    case .radio: .glyph(.radio)
    }
  }

  private func route(_ target: MenuTarget) -> Route? {
    switch target {
    case .album(let album): .album(album)
    case .artist(let artist): .artist(artist)
    case .playlist(let playlist): .playlist(playlist)
    case .song, .radio: nil
    }
  }

  private func isPlaying(_ target: MenuTarget) -> Bool {
    if case .song(let song, _, _) = target { return player.isCurrent(song) }
    return false
  }
}

/// Lays its views out in rows, wrapping to the next row when one is full,
/// as the recent queries are.
private struct FlowLayout: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    arrange(subviews, width: proposal.width ?? .infinity).size
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let frames = arrange(subviews, width: bounds.width).frames
    for (subview, frame) in zip(subviews, frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        proposal: ProposedViewSize(frame.size))
    }
  }

  private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
    var frames: [CGRect] = []
    var origin = CGPoint.zero
    var rowHeight: CGFloat = 0
    var usedWidth: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      if origin.x > 0, origin.x + size.width > width {
        origin = CGPoint(x: 0, y: origin.y + rowHeight + spacing)
        rowHeight = 0
      }
      frames.append(CGRect(origin: origin, size: size))
      usedWidth = max(usedWidth, origin.x + size.width)
      origin.x += size.width + spacing
      rowHeight = max(rowHeight, size.height)
    }
    return (frames, CGSize(width: usedWidth, height: origin.y + rowHeight))
  }
}
