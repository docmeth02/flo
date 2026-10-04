//
//  WatchSearchView.swift
//  flo Watch App
//

import SwiftUI

/// Searches the artists, albums and songs already on the watch, so it works
/// offline and asks the server nothing. The search field brings dictation
/// and scribble.
struct WatchSearchView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @Environment(\.showPlayer) private var showPlayer
  @State private var query: String
  @State private var library: Library?
  /// Nil while there is nothing to search.
  @State private var results: LibrarySearch.Results?
  @State private var openedAlbumId: String?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  private struct Library {
    let artists: [Artist]
    let albums: [Album]
    let songs: [Song]
  }

  init(query: String = "") {
    _query = State(initialValue: query)
  }

  var body: some View {
    List {
      if let results {
        if results.isEmpty {
          placeholder(
            tint: .floSecondary, title: "No results",
            message: "Nothing in your library matches \u{201C}\(query)\u{201D}.")
        }
        sections(results)
      } else {
        placeholder(
          tint: .floLavender, title: "Search your library",
          message: "Artists, albums and songs on your server.")
      }
    }
    .navigationTitle("Search")
    .searchable(text: $query)
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .navigationDestination(item: $openedAlbumId) { id in
      if let album = results?.albums.first(where: { $0.id == id }) {
        WatchAlbumDetailView(album: album)
      }
    }
    .itemMenu($menu)
    .task {
      async let artists = albumViewModel.loadedOrCached(albumViewModel.artists, .artists)
      async let albums = albumViewModel.loadedOrCached(albumViewModel.albums, .albums)
      async let songs = SmartPlaybackService.shared.loadCachedLibrary().songs
      library = await Library(artists: artists, albums: albums, songs: songs)
    }
    // Nil until the library is loaded, then the query: searches once it is
    // there and again on every edit.
    .task(id: library == nil ? nil : query) {
      guard let library else { return }
      let query = query
      let found = await Task.detached {
        LibrarySearch.search(
          query, artists: library.artists, albums: library.albums, songs: library.songs)
      }.value
      guard !Task.isCancelled else { return }
      results = found
      if let found {
        debugLog(
          "search \"\(query)\": \(found.artists.count) artists, \(found.albums.count) albums, "
            + "\(found.songs.count) songs")
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
  private func sections(_ results: LibrarySearch.Results) -> some View {
    if !results.artists.isEmpty {
      Section {
        ForEach(results.artists) { artist in
          ArtistRow(artist: artist, menu: $menu) { openedArtist = artist }
        }
      } header: {
        FloSectionHeader("Artists")
      }
    }

    if !results.albums.isEmpty {
      Section {
        ForEach(results.albums) { album in
          AlbumRow(album: album, menu: $menu) { openedAlbumId = album.id }
        }
      } header: {
        FloSectionHeader("Albums")
      }
    }

    if !results.songs.isEmpty {
      Section {
        ForEach(Array(results.songs.enumerated()), id: \.element.id) { idx, song in
          TrackRowView(
            trackNumber: idx + 1,
            title: song.title,
            artist: song.artist,
            isPlaying: playerViewModel.isCurrent(song),
            onHold: { menu = .song(song, context: "Search", isFromPlaylist: false) }
          ) {
            let search = SongCollection(id: "search", name: "Search", songs: [song])
            if playerViewModel.playItem(item: search, isFromLocal: false) { showPlayer() }
          }
          .listRowBackground(Color.clear)
        }
      } header: {
        FloSectionHeader("Songs")
      }
    }
  }
}
