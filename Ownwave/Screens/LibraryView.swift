//
//  LibraryView.swift
//  Ownwave
//

import SwiftUI

/// The Library's lists, one chip each.
enum LibraryChip: String, CaseIterable, Identifiable {
  case albums, artists, playlists, radios, liked, downloads

  var id: Self { self }
  var title: String { rawValue.capitalized }
}

/// The orders the Library's sortable lists offer, kept per list.
private enum AlbumOrder: String, CaseIterable {
  case added, name, artist, year

  var label: String {
    switch self {
    case .added: "Recently added"
    case .name: "A–Z"
    case .artist: "Artist"
    case .year: "Year"
    }
  }
}

private enum ArtistOrder: String, CaseIterable {
  case name, albums

  var label: String { self == .name ? "A–Z" : "Most albums" }
}

private enum PlaylistOrder: String, CaseIterable {
  case name, updated

  var label: String { self == .name ? "A–Z" : "Recently updated" }
}

extension String {
  /// Ascending as Finder sorts names: case-insensitive, numbers by value.
  fileprivate func precedes(_ other: String) -> Bool {
    localizedStandardCompare(other) == .orderedAscending
  }
}

struct LibraryView: View {
  @EnvironmentObject private var app: AppModel
  // Liked follows the heart of the song playing.
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @EnvironmentObject private var downloadSession: DownloadSession
  @EnvironmentObject private var storage: FloooViewModel
  @ObservedObject private var stars = StarStore.shared
  @Environment(\.palette) private var palette

  @StateObject private var radios = RadiosViewModel()
  // Kept by the tabs, so Home can open a chip. Not private: the debug launch
  // hook picks the chip.
  @Binding var chip: LibraryChip
  @State private var cachedSongs: [Song] = []
  @AppStorage("albumSort") private var albumOrder = AlbumOrder.added
  @AppStorage("artistSort") private var artistOrder = ArtistOrder.name
  @AppStorage("playlistSort") private var playlistOrder = PlaylistOrder.name
  // The last sorts, so a redraw sorts again only when a list or order changed.
  @State private var albumSort = SortMemo<Album, AlbumOrder>()
  @State private var artistSort = SortMemo<Artist, ArtistOrder>()
  @State private var playlistSort = SortMemo<Playlist, PlaylistOrder>()

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        PageTitle("Library")
        ChipBar(
          options: LibraryChip.allCases.map { ($0, $0.title, $0 == .liked ? "heart.fill" : nil) },
          selection: $chip)
        content
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .toolbar(.hidden, for: .navigationBar)
    .refreshable { await refresh() }
    .task(id: chip) { load() }
    // An album being downloaded shows up with its first song, in Downloads
    // and as a mark in the grid.
    .onReceive(downloadSession.downloadFinished) { id in
      guard chip == .downloads || chip == .albums else { return }
      if !albumViewModel.downloadedAlbums.contains(where: { $0.id == id }) {
        albumViewModel.fetchDownloadedAlbums()
      }
      if chip == .downloads { storage.getLocalStorageInformation() }
    }
    #if DEBUG
      .onAppear { applyDebugChip() }
    #endif
  }

  @ViewBuilder private var content: some View {
    switch chip {
    case .albums:
      listed(
        albumViewModel.state(.albums), isEmpty: albumViewModel.albums.isEmpty,
        empty: "No albums yet"
      ) {
        ListHeader(
          count: counted(albumViewModel.albums.count, "album"),
          orders: AlbumOrder.allCases.map { ($0, $0.label) }, order: $albumOrder)
        AlbumGrid(
          albums: sortedAlbums, downloaded: Set(albumViewModel.downloadedAlbums.map(\.id)))
      }
    case .artists:
      listed(
        albumViewModel.state(.artists), isEmpty: albumViewModel.artists.isEmpty,
        empty: "No artists yet"
      ) {
        let artists = sortedArtists
        ListHeader(
          count: counted(artists.count, "artist"),
          orders: ArtistOrder.allCases.map { ($0, $0.label) }, order: $artistOrder)
        LazyPlatter {
          ForEach(artists) { artist in
            NavigationLink(value: Route.artist(artist)) {
              ItemRow(
                art: .glyph(.artist), title: artist.name,
                subtitle: counted(artist.albumCount, "album"), artSize: 46
              ) {
                Chevron()
              }
            }
            .buttonStyle(.plain)
            .itemMenu(.artist(artist))
            .hairlineAbove(artist.id != artists.first?.id)
          }
        }
      }
    case .playlists:
      listed(
        albumViewModel.state(.playlists), isEmpty: albumViewModel.playlists.isEmpty,
        empty: "No playlists yet"
      ) {
        let playlists = sortedPlaylists
        ListHeader(
          count: counted(playlists.count, "playlist"),
          orders: PlaylistOrder.allCases.map { ($0, $0.label) }, order: $playlistOrder)
        LazyPlatter {
          ForEach(playlists) { playlist in
            NavigationLink(value: Route.playlist(playlist)) {
              PlaylistRow(playlist: playlist) { Chevron() }
            }
            .buttonStyle(.plain)
            .itemMenu(.playlist(playlist))
            .hairlineAbove(playlist.id != playlists.first?.id)
          }
        }
        ListFooter("Playlists you make in Navidrome show up here.")
      }
    case .radios:
      listed(
        radios.state, isEmpty: radios.radios.isEmpty, empty: "No radios on the server"
      ) {
        ListHeader(count: counted(radios.radios.count, "station"))
        LazyPlatter {
          ForEach(radios.radios) { radio in
            Button {
              app.play(radio)
            } label: {
              ItemRow(
                art: .glyph(.radio), title: radio.name, subtitle: "Internet radio", artSize: 46)
            }
            .buttonStyle(.plain)
            .itemMenu(.radio(radio))
            .hairlineAbove(radio.id != radios.radios.first?.id)
          }
        }
      }
    case .liked:
      liked
    case .downloads:
      downloads
    }
  }

  private var sortedAlbums: [Album] {
    albumSort.sorted(albumViewModel.albums, by: albumOrder) { albums, order in
      switch order {
      // An album without a date sorts last: the empty string is the smallest.
      case .added:
        albums.sorted {
          $0.createdAt == $1.createdAt ? $0.name.precedes($1.name) : $0.createdAt > $1.createdAt
        }
      case .name: albums.sorted { $0.name.precedes($1.name) }
      case .artist:
        albums.sorted {
          $0.albumArtist == $1.albumArtist
            ? $0.name.precedes($1.name) : $0.albumArtist.precedes($1.albumArtist)
        }
      case .year:
        albums.sorted {
          $0.minYear == $1.minYear ? $0.name.precedes($1.name) : $0.minYear > $1.minYear
        }
      }
    }
  }

  private var sortedArtists: [Artist] {
    artistSort.sorted(albumViewModel.artists, by: artistOrder) { artists, order in
      switch order {
      case .name: artists.sorted { $0.name.precedes($1.name) }
      case .albums:
        artists.sorted {
          $0.albumCount == $1.albumCount
            ? $0.name.precedes($1.name) : $0.albumCount > $1.albumCount
        }
      }
    }
  }

  private var sortedPlaylists: [Playlist] {
    playlistSort.sorted(albumViewModel.playlists, by: playlistOrder) { playlists, order in
      switch order {
      case .name: playlists.sorted { $0.name.precedes($1.name) }
      case .updated:
        playlists.sorted {
          $0.updatedAt == $1.updatedAt ? $0.name.precedes($1.name) : $0.updatedAt > $1.updatedAt
        }
      }
    }
  }

  /// Liked songs, then liked albums and artists out of the library lists,
  /// StarStore's edits over their listed stars, as on the watch.
  @ViewBuilder private var liked: some View {
    let songs = app.likedSongs
    let albums = app.likedAlbums
    let artists = app.likedArtists
    let states = [AlbumViewModel.Library.starredSongs, .albums, .artists].map(albumViewModel.state)
    listed(
      ListState(
        isLoading: states.contains(where: \.isLoading), failed: states.contains(where: \.failed)),
      isEmpty: songs.isEmpty && albums.isEmpty && artists.isEmpty, empty: "Nothing liked yet"
    ) {
      ListHeader(
        count: [(songs.count, "song"), (albums.count, "album"), (artists.count, "artist")]
          .filter { $0.0 > 0 }.map { counted($0.0, $0.1) }.joined(separator: " · "))
      if !songs.isEmpty {
        HStack(spacing: 10) {
          Button {
            app.play(SongCollection.liked(songs))
          } label: {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FillButtonStyle(height: 50))
          Button {
            app.shuffle(SongCollection.liked(songs))
          } label: {
            Label("Shuffle", systemImage: "shuffle").foregroundStyle(palette.accent)
          }
          .buttonStyle(PlatterButtonStyle(height: 50))
        }
      }
      LazyPlatter {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          let menu = MenuTarget.song(
            song, context: SongCollection.Name.liked, isFromPlaylist: false)
          SongRow(song: song, menu: menu, subtitle: "\(song.artist) · song", artSize: 46) {
            app.play(SongCollection.liked(songs), startingAt: index)
          } trailing: {
            heart
          }
          .hairlineAbove(index > 0)
        }
        ForEach(albums) { album in
          NavigationLink(value: Route.album(album)) {
            ItemRow(
              art: .cover(albumId: album.id), title: album.name,
              subtitle: "\(album.albumArtist) · album", artSize: 46
            ) {
              heart
            }
          }
          .buttonStyle(.plain)
          .itemMenu(.album(album))
          .hairlineAbove(!songs.isEmpty || album.id != albums.first?.id)
        }
        ForEach(artists) { artist in
          NavigationLink(value: Route.artist(artist)) {
            ItemRow(art: .glyph(.artist), title: artist.name, subtitle: "Artist", artSize: 46) {
              heart
            }
          }
          .buttonStyle(.plain)
          .itemMenu(.artist(artist))
          .hairlineAbove(!songs.isEmpty || !albums.isEmpty || artist.id != artists.first?.id)
        }
      }
    }
  }

  private var heart: some View {
    Image(systemName: "heart.fill").foregroundStyle(Color.floLiked)
  }

  /// The stream cache, then the downloaded albums and playlists with their
  /// progress, as the watch's Downloads.
  @ViewBuilder private var downloads: some View {
    let albums = albumViewModel.downloadedAlbums
    if albums.isEmpty && cachedSongs.isEmpty {
      StateView(kind: .empty("Download an album to play it without a connection."))
    } else {
      ListHeader(
        count: "\(counted(albums.count, "album")) · \(storage.localDirectorySize)")
      LazyPlatter {
        if !cachedSongs.isEmpty {
          NavigationLink {
            CachedSongsView(songs: cachedSongs)
          } label: {
            ItemRow(
              art: .glyph(.playlist), title: "Cached", subtitle: counted(cachedSongs.count, "song"),
              artSize: 46
            ) {
              Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.floDownloaded)
            }
          }
          .buttonStyle(.plain)
        }
        ForEach(albums) { album in
          DownloadRow(album: album)
            .hairlineAbove(!cachedSongs.isEmpty || album.id != albums.first?.id)
        }
      }
      let rate = UserDefaultsManager.downloadBitRate
      // The setting, not the files: earlier downloads keep their bitrate.
      ListFooter(
        rate == TranscodingSettings.sourceBitRate
          ? "Downloads in original quality." : "Downloads at \(rate) kbps.")
    }
  }

  /// The rows, or while there are none the list's loading, failed or empty
  /// state.
  @ViewBuilder private func listed(
    _ state: ListState, isEmpty: Bool, empty: String,
    @ViewBuilder rows: () -> some View
  ) -> some View {
    if !isEmpty {
      rows()
    } else if state.isLoading {
      StateView(kind: .loading)
    } else if state.failed {
      StateView(
        kind: .error("The server could not be reached.", retry: { Task { await refresh() } }))
    } else {
      StateView(kind: .empty(empty))
    }
  }

  /// Shows the chip's list from the cache at once and reloads it unless it
  /// was loaded a moment ago.
  private func load() {
    switch chip {
    case .albums:
      albumViewModel.fetchAlbums()
      albumViewModel.fetchDownloadedAlbums()
    case .artists: albumViewModel.getArtists()
    case .playlists: albumViewModel.getPlaylists()
    case .radios: radios.fetchAllRadios()
    case .liked:
      // The listed stars may predate a like made since.
      albumViewModel.fetchStarredSongs()
      albumViewModel.fetchAlbums()
      albumViewModel.getArtists()
    case .downloads:
      albumViewModel.fetchDownloadedAlbums()
      cachedSongs = StreamCacheManager.shared.getCachedSongs()
      storage.getLocalStorageInformation()
    }
  }

  private func refresh() async {
    switch chip {
    case .albums: await albumViewModel.refreshAlbums()
    case .artists: await albumViewModel.refreshArtists()
    case .playlists: await albumViewModel.refreshPlaylists()
    case .radios: await radios.refresh()
    case .liked:
      async let songs: Void = albumViewModel.refreshStarredSongs()
      async let albums: Void = albumViewModel.refreshAlbums()
      async let artists: Void = albumViewModel.refreshArtists()
      _ = await (songs, albums, artists)
    case .downloads: load()
    }
  }
}

/// A downloaded album: its songs when done, the progress while
/// it downloads, and a failure a tap retries.
private struct DownloadRow: View {
  let album: Album

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var downloads: DownloadSession
  @Environment(\.palette) private var palette

  private var downloading: Bool { downloads.isDownloading(collectionId: album.id) }
  private var failed: Bool { !downloading && downloads.hasFailed(collectionId: album.id) }

  var body: some View {
    Group {
      // A failed album retries in place.
      if failed {
        Button {
          app.download(album)
        } label: {
          row
        }
      } else {
        NavigationLink(value: Route.album(album)) { row }
      }
    }
    .buttonStyle(.plain)
    .itemMenu(.album(album))
  }

  private var row: some View {
    let percent = downloads.progress(collectionId: album.id) * 100
    return HStack(spacing: 12) {
      CoverArt(albumId: album.id, radius: 7).frame(width: 46, height: 46)
      VStack(alignment: .leading, spacing: 2) {
        Text(album.name).font(.rowTitle).foregroundStyle(palette.text)
        Group {
          if failed {
            Text("Failed · tap to retry").foregroundStyle(Color.floDestructive)
          } else if downloading {
            Text("Downloading · \(Int(percent))%")
          } else {
            Text(
              counted(
                DownloadStore.downloadedMediaFileIds(collectionId: album.id).count, "song"))
          }
        }
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
        if downloading {
          ProgressView(value: percent, total: 100)
            .tint(palette.accent)
            .padding(.top, 5)
        }
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      Group {
        if failed {
          Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.floDestructive)
        } else if !downloading {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.floDownloaded)
        }
      }
      .font(.system(size: 20))
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
  }
}

/// The songs in the stream cache, most recently played first.
private struct CachedSongsView: View {
  let songs: [Song]

  @EnvironmentObject private var app: AppModel
  @Environment(\.palette) private var palette

  var body: some View {
    ScrollView {
      Platter {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          let menu = MenuTarget.song(
            song, context: SongCollection.Name.cached, isFromPlaylist: false)
          SongRow(song: song, menu: menu) {
            app.play(SongCollection.cached(songs), startingAt: index)
          } trailing: {
            ItemMenuButton(target: menu)
          }
        }
      }
      .padding(16)
    }
    .containerBackground(palette.background, for: .navigation)
    .navigationTitle("Cached")
    .navigationBarTitleDisplayMode(.inline)
  }
}

/// A list's last sort, kept while neither the list nor the order changes; a
/// list that is the same array compares in constant time.
private final class SortMemo<Item: Equatable, Order: Equatable> {
  private var last: (items: [Item], order: Order, sorted: [Item])?

  func sorted(_ items: [Item], by order: Order, _ sort: ([Item], Order) -> [Item]) -> [Item] {
    if let last, last.order == order, last.items == items { return last.sorted }
    let sorted = sort(items, order)
    last = (items, order, sorted)
    return sorted
  }
}
