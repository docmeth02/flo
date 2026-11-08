//
//  WatchLikedView.swift
//  Ownwave Watch App
//

import SwiftUI

/// The liked songs behind one row, then the liked albums and artists out of
/// the library lists on the watch, StarStore's edits over their listed stars.
struct WatchLikedView: View {
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject var playerViewModel: PlayerViewModel
  // Redraws the lists when an item is unliked.
  @ObservedObject private var starStore = StarStore.shared

  @Environment(\.showPlayer) private var showPlayer
  @State private var showsSongs = false
  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  /// Unliked songs leave at once, before the list reloads.
  private var songs: [Song] { albumViewModel.likedSongs(playerViewModel) }
  private var albums: [Album] { albumViewModel.likedAlbums }
  private var artists: [Artist] { albumViewModel.likedArtists }

  /// Loading while any of the three lists loads, failed when any failed.
  private var state: ListState {
    let states = [AlbumViewModel.Library.starredSongs, .albums, .artists].map(albumViewModel.state)
    return ListState(
      isLoading: states.contains(where: \.isLoading), failed: states.contains(where: \.failed))
  }

  var body: some View {
    let songs = songs
    let albums = albums
    let artists = artists
    LibraryList(
      title: "Liked", state: state,
      isEmpty: songs.isEmpty && albums.isEmpty && artists.isEmpty,
      empty: .empty(
        systemImage: "heart.fill", tint: .liked, title: "Nothing liked yet",
        message: "Liked songs, albums and artists show up here."),
      refresh: refresh
    ) {
      if !songs.isEmpty {
        songsRow(songs)
          .joinedRow(.alone)
      }
      section("Albums", albums) { album in
        LibraryRow(target: .album(album), menu: $menu) { openedAlbum = album }
      }
      section("Artists", artists) { artist in
        LibraryRow(target: .artist(artist), menu: $menu) { openedArtist = artist }
      }
    }
    .navigationDestination(isPresented: $showsSongs) { WatchStarredSongsView() }
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .itemMenu($menu, openedAlbum: $openedAlbum, openedArtist: $openedArtist)
    .onAppear {
      // The cached lists show at once; their stars may predate a like made
      // since, so they reload unless loaded a moment ago.
      albumViewModel.fetch(.starredSongs)
      albumViewModel.fetch(.albums)
      albumViewModel.fetch(.artists)
    }
  }

  /// Liked Songs: a tap opens the list, the round button beside it, outside
  /// the row's tap, shuffles it.
  private func songsRow(_ songs: [Song]) -> some View {
    HStack(spacing: 4) {
      HStack(spacing: WatchLayout.tileSpacing) {
        Image(systemName: "heart.fill")
          .font(.system(size: 16))
          .foregroundStyle(Color.liked)
          .frame(width: WatchLayout.smallThumbnail, height: WatchLayout.smallThumbnail)
          .background(Circle().fill(Color.liked.opacity(0.22)))
        VStack(alignment: .leading, spacing: 1) {
          Text("Liked Songs")
            .font(.rowTitle)
          Text("Play or shuffle")
            .font(.meta)
            .foregroundStyle(Dusk.secondary)
        }
        .lineLimit(1)
      }
      .frame(maxWidth: .infinity, minHeight: WatchLayout.joinedRowHeight, alignment: .leading)
      .holdable(onTap: { showsSongs = true }, onHold: nil)
      Button {
        if playerViewModel.shuffleItem(item: SongCollection.liked(songs)) { showPlayer() }
      } label: {
        Image(systemName: "shuffle")
      }
      .buttonStyle(RoundButtonStyle())
      .accessibilityLabel("Shuffle Liked Songs")
    }
  }

  @ViewBuilder
  private func section<Item: Identifiable, Row: View>(
    _ title: String, _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
  ) -> some View {
    if !items.isEmpty {
      Section {
        JoinedRows(items: items, row: row)
      } header: {
        SectionHeader(title)
      }
    }
  }

  private func refresh() async {
    async let songs: Void = albumViewModel.refresh(.starredSongs)
    async let albums: Void = albumViewModel.refresh(.albums)
    async let artists: Void = albumViewModel.refresh(.artists)
    _ = await (songs, albums, artists)
  }
}
