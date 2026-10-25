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
  @ObservedObject private var starStore = StarStore.shared

  @Environment(\.showPlayer) private var showPlayer
  @State private var showsSongs = false
  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var menu: MenuTarget?

  /// Unliked songs leave at once, before the list reloads.
  private var songs: [Song] {
    albumViewModel.starredSongs.filter { playerViewModel.isStarred($0) }
  }

  private var albums: [Album] {
    albumViewModel.albums.filter { starStore.isStarred($0.id, listed: $0.starred) }
  }

  private var artists: [Artist] {
    albumViewModel.artists.filter { starStore.isStarred($0.id, listed: $0.starred) }
  }

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
        systemImage: "heart.fill", tint: .floLiked, title: "Nothing liked yet",
        message: "Liked songs, albums and artists show up here."),
      refresh: refresh
    ) {
      if !songs.isEmpty {
        songsRow(songs)
          .floJoinedRow(.alone)
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
    .itemMenu($menu)
    .onAppear {
      // The cached lists show at once; their stars may predate a like made
      // since, so they reload unless loaded a moment ago.
      albumViewModel.fetchStarredSongs()
      albumViewModel.fetchAlbums()
      albumViewModel.getArtists()
    }
  }

  /// Liked Songs: a tap opens the list, the round button shuffles it.
  private func songsRow(_ songs: [Song]) -> some View {
    HStack(spacing: 4) {
      HStack(spacing: FloLayout.tileSpacing) {
        Image(systemName: "heart.fill")
          .font(.system(size: 16))
          .foregroundStyle(Color.floLiked)
          .frame(width: FloLayout.smallThumbnail, height: FloLayout.smallThumbnail)
          .background(Circle().fill(Color.floLiked.opacity(0.22)))
        VStack(alignment: .leading, spacing: 1) {
          Text("Liked Songs")
            .font(.floRowTitle)
          Text("Play or shuffle")
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
        }
        .lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        if playerViewModel.shuffleItem(item: SongCollection.liked(songs)) { showPlayer() }
      } label: {
        Image(systemName: "shuffle")
      }
      .buttonStyle(FloRoundButtonStyle())
      .accessibilityLabel("Shuffle Liked Songs")
    }
    .frame(minHeight: FloLayout.joinedRowHeight)
    .holdable(onTap: { showsSongs = true }, onHold: nil)
  }

  @ViewBuilder
  private func section<Item: Identifiable, Row: View>(
    _ title: String, _ items: [Item], @ViewBuilder row: @escaping (Item) -> Row
  ) -> some View {
    if !items.isEmpty {
      Section {
        JoinedRows(items: items, row: row)
      } header: {
        FloSectionHeader(title)
      }
    }
  }

  private func refresh() async {
    async let songs: Void = albumViewModel.refreshStarredSongs()
    async let albums: Void = albumViewModel.refreshAlbums()
    async let artists: Void = albumViewModel.refreshArtists()
    _ = await (songs, albums, artists)
  }
}
