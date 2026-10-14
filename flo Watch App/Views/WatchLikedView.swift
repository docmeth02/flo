//
//  WatchLikedView.swift
//  flo Watch App
//

import SwiftUI

/// The liked songs behind one row, then the liked albums and artists out of
/// the library lists on the watch, StarStore's edits over their listed stars.
struct WatchLikedView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @ObservedObject private var starStore = StarStore.shared

  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  private var albums: [Album] {
    albumViewModel.albums.filter { starStore.isStarred($0.id, listed: $0.starred) }
  }

  private var artists: [Artist] {
    albumViewModel.artists.filter { starStore.isStarred($0.id, listed: $0.starred) }
  }

  var body: some View {
    let albums = albums
    let artists = artists
    LibraryList(
      title: "Liked", state: albumViewModel.state(.starredSongs),
      isEmpty: albumViewModel.starredSongs.isEmpty && albums.isEmpty && artists.isEmpty,
      empty: .empty(
        systemImage: "heart.fill", tint: .floLiked, title: "Nothing liked yet",
        message: "Liked songs, albums and artists show up here."),
      refresh: refresh
    ) {
      if !albumViewModel.starredSongs.isEmpty {
        NavigationLink(destination: WatchStarredSongsView()) {
          FloNavRow(title: "Songs", systemImage: "heart.fill", tint: .floLiked)
        }
        .floRow()
      }
      if !albums.isEmpty {
        Section {
          ForEach(albums) { album in
            AlbumRow(album: album, menu: $menu) { openedAlbum = album }
          }
        } header: {
          FloSectionHeader("Albums")
        }
      }
      if !artists.isEmpty {
        Section {
          ForEach(artists) { artist in
            ArtistRow(artist: artist, menu: $menu) { openedArtist = artist }
          }
        } header: {
          FloSectionHeader("Artists")
        }
      }
    }
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .itemMenu($menu)
    .onAppear {
      // The cached lists show at once; their stars may predate a like made
      // since, so they reload unless loaded a moment ago.
      albumViewModel.fetchStarredSongs()
      albumViewModel.fetchAlbums()
      albumViewModel.getArtists()
    }
  }

  private func refresh() async {
    async let songs: Void = albumViewModel.refreshStarredSongs()
    async let albums: Void = albumViewModel.refreshAlbums()
    async let artists: Void = albumViewModel.refreshArtists()
    _ = await (songs, albums, artists)
  }
}
