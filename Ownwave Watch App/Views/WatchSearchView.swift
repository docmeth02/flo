//
//  WatchSearchView.swift
//  Ownwave Watch App
//

import SwiftUI

/// Searches the artists, albums and songs already on the watch, so it works
/// offline and asks the server nothing. The search field brings dictation
/// and scribble.
struct WatchSearchView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: PlayerViewModel
  @EnvironmentObject private var pinStore: PinStore

  @Environment(\.showPlayer) private var showPlayer
  @State private var query: String
  @State private var library: Library?
  /// Nil while there is nothing to search.
  @State private var found: Found?
  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  private struct Library {
    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]
  }

  /// The results of one query and the best of them.
  private struct Found {
    let query: String
    let results: LibrarySearch.Results
    let top: MenuTarget?
  }

  init(query: String = "") {
    _query = State(initialValue: query)
  }

  var body: some View {
    List {
      if let found {
        if found.results.isEmpty {
          placeholder(
            tint: .floSecondary, title: "No results",
            message: "Nothing in your library matches \u{201C}\(found.query)\u{201D}.")
        }
        sections(found)
      } else {
        placeholder(
          tint: .floLilac, title: "Search your library",
          message: "Artists, albums and songs on your server.")
      }
    }
    // Plain with the default row height, as in `LibraryList`.
    .listStyle(.plain)
    .floNavigationTitle("Search")
    .searchable(text: $query)
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .itemMenu($menu)
    .task {
      // Once: the view reappears after every pushed album or artist.
      guard library == nil else { return }
      async let artists = albumViewModel.loadedOrCached(albumViewModel.artists, .artists)
      async let albums = albumViewModel.loadedOrCached(albumViewModel.albums, .albums)
      async let songs = SmartPlaybackService.shared.loadCachedLibrary().songs
      library = await Library(artists: artists, albums: albums, songs: songs)
    }
    // Nil until the library is loaded, then the query: searches once it is
    // there and again on every edit.
    .task(id: library == nil ? nil : query) {
      guard let library else { return }
      // Typing restarts this task; only a query left alone for a moment is
      // searched, so no scan runs for every keystroke.
      try? await Task.sleep(for: .milliseconds(250))
      guard !Task.isCancelled else { return }
      let query = query
      let results = await Task.detached {
        LibrarySearch.search(
          query, artists: library.artists, albums: library.albums, songs: library.songs,
          limits: .watch)
      }.value
      guard !Task.isCancelled else { return }
      found = results.map {
        Found(
          query: query, results: $0,
          top: LibrarySearch.topResult(query, in: $0, isPinned: isPinned))
      }
      if let results {
        debugLog(
          "search \"\(query)\": \(results.artists.count) artists, \(results.albums.count) albums, "
            + "\(results.songs.count) songs")
      }
    }
  }

  private func placeholder(tint: Color, title: String, message: String) -> some View {
    StateView(
      kind: .empty(systemImage: "magnifyingglass", tint: tint, title: title, message: message)
    )
    .padding(.top, 8)
    .listRowBackground(Color.clear)
  }

  @ViewBuilder
  private func sections(_ found: Found) -> some View {
    let results = found.results
    let top = found.top
    if let top {
      Section {
        topCard(top)
          .floJoinedRow(.alone)
      } header: {
        FloSectionHeader("Top result")
      }
    }
    rows("Artists", results.artists.map(MenuTarget.artist), without: top)
    rows("Albums", results.albums.map(MenuTarget.album), without: top)

    let songs = results.songs.filter { MenuTarget.searched($0).id != top?.id }
    if !songs.isEmpty {
      Section {
        ForEach(Array(songs.enumerated()), id: \.element.id) { idx, song in
          TrackRowView(
            trackNumber: idx + 1,
            title: song.title,
            artist: song.artist,
            isPlaying: playerViewModel.isCurrent(song),
            onHold: { menu = .searched(song) }
          ) {
            play(song)
          }
          // The row's own platter, as wide as the joined ones above.
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
        }
      } header: {
        FloSectionHeader("Songs")
      }
    }
  }

  /// Artists or albums on one platter, the pinned ones first.
  @ViewBuilder
  private func rows(_ title: String, _ targets: [MenuTarget], without top: MenuTarget?)
    -> some View
  {
    let targets = LibrarySearch.pinnedFirst(
      targets.filter { $0.id != top?.id }, isPinned: isPinned)
    if !targets.isEmpty {
      Section {
        JoinedRows(items: targets) { target in
          LibraryRow(target: target, menu: $menu) { open(target) }
        }
      } header: {
        FloSectionHeader(title)
      }
    }
  }

  /// The best match on its own card: a tap opens it (a song plays), and an
  /// artist's round button starts Artist Radio.
  private func topCard(_ target: MenuTarget) -> some View {
    CoverRow(
      tile: LibraryRow.tile(target), title: target.title, subtitle: topSubtitle(target),
      titleLineLimit: 2, tileSize: FloLayout.smallThumbnail
    ) {
      if case .artist(let artist) = target {
        Button {
          Task {
            if await playerViewModel.playArtistRadio(id: artist.id, name: artist.name) {
              showPlayer()
            }
          }
        } label: {
          Image(systemName: LibraryRow.radioGlyph)
        }
        .buttonStyle(FloRoundButtonStyle(tint: .floInk, fill: .floLilac))
        .disabled(playerViewModel.isGeneratingMix)
        .opacity(playerViewModel.isGeneratingMix ? FloLayout.pressedOpacity : 1)
        .accessibilityLabel("Artist Radio")
      } else if isPinned(target) {
        PinGlyph()
      }
    }
    .holdable(onTap: { open(target) }, onHold: { menu = target })
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

  private func isPinned(_ target: MenuTarget) -> Bool {
    target.pin.map { pinStore.isPinned($0.id, $0.kind) } ?? false
  }

  /// A song plays, an album or artist opens.
  private func open(_ target: MenuTarget) {
    switch target {
    case .song(let song, _, _): play(song)
    case .album(let album): openedAlbum = album
    case .artist(let artist): openedArtist = artist
    case .playlist, .radio: break
    }
  }

  private func play(_ song: Song) {
    if playerViewModel.playItem(item: SongCollection.search(song)) { showPlayer() }
  }
}
