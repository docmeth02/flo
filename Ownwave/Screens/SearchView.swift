//
//  SearchView.swift
//  Ownwave
//

import SwiftUI

/// Searches the artists, albums, playlists and songs already on the phone,
/// so it works offline; the artist, album and playlist lists are refreshed
/// as the Library does. The best match leads as the top result; pinned
/// items come first in their section, marked with a pin.
struct SearchView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var albums: AlbumViewModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var pins: PinStore
  @Environment(\.palette) private var palette

  /// The last queries, newest first, one per line.
  @AppStorage("recentSearches") private var storedRecents = ""
  @State private var query = ""
  @FocusState private var isFieldFocused: Bool
  /// The cached song library, nil until it is read.
  @State private var songs: [Song]?
  /// Nil while there is nothing to search.
  @State private var found: Found?

  @StateObject private var radio = ArtistDetailViewModel()
  /// Ends with the screen, as on the artist's, so a late answer never
  /// replaces a newer queue.
  @State private var radioTask: Task<Void, Never>?
  /// The artist whose radio found nothing, and whether its request failed.
  @State private var radioMiss: (name: String, failed: Bool)?

  private static let maxRecents = 8

  /// What a search depends on: it runs again when the query or a list
  /// changes. An unchanged list keeps its storage, so comparing it is cheap.
  private struct Input: Equatable {
    let query: String
    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]?
  }

  /// The results of the query that was searched, which lags the typed one.
  private struct Found {
    let query: String
    let results: LibrarySearch.Results
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 20) {
        if let found {
          results(found)
        } else if !recents.isEmpty {
          section("Recent") {
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
      .padding(.top, 4)
      .padding(.bottom, 24)
    }
    .safeAreaInset(edge: .top, spacing: 0) {
      field
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(palette.background)
    }
    .scrollDismissesKeyboard(.immediately)
    .toolbar(.hidden, for: .navigationBar)
    .onAppear {
      #if DEBUG
        applyDebugQuery()
      #endif
      if query.isEmpty { isFieldFocused = true }
    }
    .onDisappear { radioTask?.cancel() }
    .alert(
      radioMiss?.name ?? "",
      isPresented: Binding(get: { radioMiss != nil }, set: { if !$0 { radioMiss = nil } })
    ) {
      Button("OK") {}
    } message: {
      Text(ArtistDetailViewModel.noRadioMessage(failed: radioMiss?.failed ?? false))
    }
    .task {
      albums.getArtists()
      albums.fetchAlbums()
      albums.getPlaylists()
      // Read on every return, so a library synced meanwhile is searched. A
      // new phone has no song library before its first mix, so Search syncs
      // it then.
      var library = await SmartPlaybackService.shared.loadCachedLibrary().songs
      if library.isEmpty, ConnectivityMonitor.shared.canReachServer {
        library = await SmartPlaybackService.shared.syncSongLibrary()
      }
      songs = library
    }
    .task(id: Input(query: query, artists: albums.artists, albums: albums.albums, songs: songs)) {
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

  /// The design's own field: the accent rim while typing, a clear button
  /// once there is a query.
  private var field: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(palette.secondary)
      TextField(
        "Search", text: $query,
        prompt: Text("Artists, albums, songs").foregroundStyle(palette.secondary)
      )
      .focused($isFieldFocused)
      .submitLabel(.search)
      .autocorrectionDisabled()
      .onSubmit { remember(query) }
      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.secondary)
        .accessibilityLabel("Clear")
      }
    }
    .padding(.horizontal, 14)
    .frame(minHeight: 46)
    .background(palette.surface, in: Capsule())
    .overlay {
      Capsule()
        .strokeBorder(palette.accent, lineWidth: 1.5)
        .opacity(isFieldFocused ? 1 : 0)
    }
    .contentShape(Capsule())
    .onTapGesture { isFieldFocused = true }
    .animation(.snappy(duration: 0.2), value: isFieldFocused)
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

  // MARK: - Results

  @ViewBuilder
  private func results(_ found: Found) -> some View {
    let results = found.results
    let top = topResult(found.query, results)
    let artists = pinnedFirst(
      results.artists.map(MenuTarget.artist).filter { $0.id != top?.id })
    let albumTargets = pinnedFirst(
      results.albums.map(MenuTarget.album).filter { $0.id != top?.id })
    let playlists = pinnedFirst(
      albums.playlists.filter { $0.name.localizedStandardContains(found.query) }
        .map(MenuTarget.playlist))
    let songs = results.songs.map { MenuTarget.song($0, context: SongCollection.Name.search, isFromPlaylist: false) }
      .filter { $0.id != top?.id }

    if let top {
      section("Top result") { topCard(top) }
    } else if playlists.isEmpty {
      Text("Nothing on the server matches \u{201C}\(found.query)\u{201D}.")
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
    if !albumTargets.isEmpty {
      section("Albums") {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(albumTargets) { target in
              if case .album(let album) = target {
                AlbumTile(album: album, width: 120, mark: isPinned(target) ? .pinned : nil)
                  .simultaneousGesture(TapGesture().onEnded { remember(query) })
              }
            }
          }
          .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
      }
    }
    rows("Artists", artists)
    rows("Playlists", playlists)
    rows("Songs", songs)
  }

  /// The best match: an exact name beats a name that starts with the query,
  /// which beats any other match; on a tie a pinned item, then an artist
  /// before an album before a song, then the search's own order.
  private func topResult(_ query: String, _ results: LibrarySearch.Results) -> MenuTarget? {
    let candidates: [MenuTarget] =
      results.artists.map(MenuTarget.artist) + results.albums.map(MenuTarget.album)
      + results.songs.map { MenuTarget.song($0, context: SongCollection.Name.search, isFromPlaylist: false) }
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
    func match(_ name: String) -> Int {
      if name.compare(query, options: options) == .orderedSame { return 2 }
      return name.range(of: query, options: options.union(.anchored)) != nil ? 1 : 0
    }
    return candidates.enumerated()
      .min { a, b in
        (-match(a.element.title), isPinned(a.element) ? 0 : 1, a.offset)
          < (-match(b.element.title), isPinned(b.element) ? 0 : 1, b.offset)
      }?
      .element
  }

  private func isPinned(_ target: MenuTarget) -> Bool {
    target.pin.map { pins.isPinned($0.id, $0.kind) } ?? false
  }

  private func pinnedFirst(_ targets: [MenuTarget]) -> [MenuTarget] {
    targets.filter(isPinned) + targets.filter { !isPinned($0) }
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.rowSubtitle.weight(.semibold))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 4)
      content()
    }
  }

  /// Artists, playlists or songs as rows on one platter.
  @ViewBuilder
  private func rows(_ title: String, _ targets: [MenuTarget]) -> some View {
    if !targets.isEmpty {
      section(title) {
        Platter {
          ForEach(targets) { row($0) }
        }
      }
    }
  }

  @ViewBuilder
  private func row(_ target: MenuTarget) -> some View {
    switch target {
    case .song(let song, _, _):
      SongRow(song: song, menu: target, artSize: 42) {
        play(song)
      } trailing: {
        EmptyView()
      }
    case .playlist(let playlist):
      opening(target) {
        PlaylistRow(playlist: playlist) { pinMark(target) }
      }
      .itemMenu(target)
    case .artist:
      opening(target) {
        ItemRow(
          art: .glyph(.artist), title: target.title, subtitle: target.subtitle, artSize: 42
        ) {
          pinMark(target)
        }
      }
      .itemMenu(target)
    case .album, .radio:
      EmptyView()
    }
  }

  @ViewBuilder
  private func pinMark(_ target: MenuTarget) -> some View {
    if isPinned(target) {
      Image(systemName: "pin.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(palette.accent)
        .padding(.trailing, 4)
        .accessibilityLabel("Pinned")
    }
  }

  /// What a tap on a result does around `label`: a song plays, an album,
  /// artist or playlist opens; the query is remembered on the way.
  @ViewBuilder
  private func opening(_ target: MenuTarget, @ViewBuilder label: () -> some View) -> some View {
    Group {
      switch target {
      case .song(let song, _, _):
        Button {
          play(song)
        } label: {
          label()
        }
      case .album(let album):
        NavigationLink(value: Route.album(album), label: label)
      case .artist(let artist):
        NavigationLink(value: Route.artist(artist), label: label)
      case .playlist(let playlist):
        NavigationLink(value: Route.playlist(playlist), label: label)
      case .radio:
        EmptyView()
      }
    }
    .buttonStyle(.plain)
    .simultaneousGesture(TapGesture().onEnded { remember(query) })
  }

  // MARK: - Top result

  /// The best match on its own card: a tap opens it (a song plays), the
  /// round button plays it, or for an artist starts Artist Radio.
  private func topCard(_ target: MenuTarget) -> some View {
    HStack(spacing: 12) {
      opening(target) {
        HStack(spacing: 14) {
          topArt(target)
          VStack(alignment: .leading, spacing: 2) {
            Text(target.title)
              .font(.familjen(22, relativeTo: .title2))
              .foregroundStyle(palette.text)
            Text(topSubtitle(target))
              .font(.rowSubtitle)
              .foregroundStyle(palette.secondary)
          }
          .lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(.vertical, 14)
        .padding(.leading, 14)
        .contentShape(Rectangle())
      }
      topAction(target)
        .padding(.trailing, 14)
    }
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .itemMenu(target)
  }

  private func topArt(_ target: MenuTarget) -> some View {
    Group {
      switch target {
      case .song(let song, _, _): CoverArt(albumId: song.albumId, radius: 12)
      case .album(let album): CoverArt(albumId: album.id, radius: 12)
      default: GlyphTile.artist
      }
    }
    .frame(width: 64, height: 64)
    .overlay(alignment: .topTrailing) {
      if isPinned(target) {
        Image(systemName: "pin.fill")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(palette.accent)
          .padding(4)
          .background(palette.surface, in: Circle())
          .offset(x: 4, y: -4)
          .accessibilityLabel("Pinned")
      }
    }
  }

  private func topSubtitle(_ target: MenuTarget) -> String {
    switch target {
    case .artist(let artist):
      artist.albumCount > 0 ? "Artist · \(counted(artist.albumCount, "album"))" : "Artist"
    case .album(let album): "Album · \(album.albumArtist)"
    case .song(let song, _, _): "Song · \(song.artist)"
    case .playlist, .radio: target.subtitle
    }
  }

  @ViewBuilder
  private func topAction(_ target: MenuTarget) -> some View {
    switch target {
    case .artist(let artist):
      Button {
        startRadio(artist)
      } label: {
        if radio.isLoadingRadio {
          ProgressView().tint(palette.ink)
        } else {
          Image(systemName: "dot.radiowaves.up.forward")
        }
      }
      .buttonStyle(FillButtonStyle(height: 44))
      .frame(width: 44)
      .disabled(radio.isLoadingRadio || player.isGeneratingMix)
      .accessibilityLabel("Artist Radio")
    case .album(let album):
      playButton { play(album) }
    case .song(let song, _, _):
      playButton { play(song) }
    case .playlist, .radio:
      EmptyView()
    }
  }

  private func playButton(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: "play.fill")
    }
    .buttonStyle(FillButtonStyle(height: 44))
    .frame(width: 44)
    .accessibilityLabel("Play")
  }

  // MARK: - Playing

  private func play(_ song: Song) {
    remember(query)
    app.play(SongCollection.search(song))
  }

  /// The album's songs as Play Next would queue them: from the library or
  /// the server, offline from its download.
  private func play(_ album: Album) {
    remember(query)
    Task {
      var album = album
      album.songs = await MenuTarget.album(album).queueSongs(
        serverReachable: ConnectivityMonitor.shared.canReachServer
      ).songs
      guard !album.songs.isEmpty else { return app.show("Not available offline") }
      app.play(album)
    }
  }

  /// Artist Radio as the artist's screen starts it.
  private func startRadio(_ artist: Artist) {
    remember(query)
    radioTask?.cancel()
    radioTask = Task {
      let songs = await radio.fetchArtistRadio(artist: artist)
      guard !Task.isCancelled else { return }
      if let songs, !songs.isEmpty {
        app.play(SongCollection.artistRadio(id: artist.id, name: artist.name, songs: songs))
      } else {
        radioMiss = (artist.name, songs == nil)
      }
    }
  }

  #if DEBUG
    /// Simulator verification only: FLO_DEBUG_SEARCH=<query> types a query,
    /// as on the watch.
    private func applyDebugQuery() {
      guard query.isEmpty, let debugQuery = ProcessInfo.processInfo.environment["FLO_DEBUG_SEARCH"]
      else { return }
      query = debugQuery
    }
  #endif
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
