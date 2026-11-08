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
  /// Why the top card's Artist Radio played nothing, while that shows.
  @State private var radioMiss: (name: String, message: String)?

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
            tint: Dusk.secondary, title: "No results",
            message: "Nothing in your library matches \u{201C}\(found.query)\u{201D}.")
        }
        sections(found)
      } else {
        placeholder(
          tint: Dusk.fill, title: "Search your library",
          message: "Artists, albums and songs on your server.")
      }
    }
    // Plain and as low as the rows, as in `LibraryList`.
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 1)
    .brandNavigationTitle("Search")
    .searchable(text: $query)
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .itemMenu($menu, openedAlbum: $openedAlbum, openedArtist: $openedArtist)
    .alert(
      radioMiss?.name ?? "",
      isPresented: Binding(get: { radioMiss != nil }, set: { if !$0 { radioMiss = nil } })
    ) {
      Button("OK") {}
    } message: {
      Text(radioMiss?.message ?? "")
    }
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
          top: LibrarySearch.topResult(query, in: $0, isPinned: pinStore.isPinned))
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
          .joinedRow(.alone)
      } header: {
        SectionHeader("Top result")
      }
    }
    rows("Artists", results.artists.map(MenuTarget.artist), without: top)
    rows("Albums", results.albums.map(MenuTarget.album), without: top)

    let songs = results.songs.filter { MenuTarget.searched($0).id != top?.id }
    if !songs.isEmpty {
      Section {
        SongRows(songs: songs, onHold: { menu = .searched($0) }) { play(songs[$0]) }
      } header: {
        SectionHeader("Songs")
      }
    }
  }

  /// Artists or albums on one platter, the pinned ones first.
  @ViewBuilder
  private func rows(_ title: String, _ targets: [MenuTarget], without top: MenuTarget?)
    -> some View
  {
    let targets = LibrarySearch.pinnedFirst(
      targets.filter { $0.id != top?.id }, isPinned: pinStore.isPinned)
    if !targets.isEmpty {
      Section {
        JoinedRows(items: targets) { target in
          LibraryRow(target: target, menu: $menu) { open(target) }
        }
      } header: {
        SectionHeader(title)
      }
    }
  }

  /// The best match on its own card: a tap opens it (a song plays), and an
  /// artist's round button beside it, outside the card's tap, starts Artist
  /// Radio.
  private func topCard(_ target: MenuTarget) -> some View {
    HStack(spacing: 4) {
      CoverRow(
        tile: CoverTile(target), title: target.title, subtitle: target.searchSubtitle,
        titleLineLimit: 2, tileSize: WatchLayout.smallThumbnail
      ) {
        if pinStore.isPinned(target) { PinGlyph() }
      }
      .holdable(onTap: { open(target) }, onHold: { menu = target })
      if case .artist(let artist) = target {
        Button {
          Task {
            let outcome = await playerViewModel.playArtistRadio(id: artist.id, name: artist.name)
            if outcome == .played { showPlayer() }
            radioMiss = outcome.message.map { (artist.name, $0) }
          }
        } label: {
          Image(systemName: Glyph.radio)
        }
        .buttonStyle(RoundButtonStyle(tint: Dusk.ink, fill: Dusk.fill))
        .disabled(playerViewModel.isGeneratingMix)
        .opacity(playerViewModel.isGeneratingMix ? WatchLayout.pressedOpacity : 1)
        .accessibilityLabel("Artist Radio")
      }
    }
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
