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

struct LibraryView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @EnvironmentObject private var downloadViewModel: DownloadViewModel
  @EnvironmentObject private var storage: FloooViewModel
  @ObservedObject private var stars = StarStore.shared
  @Environment(\.palette) private var palette

  @StateObject private var radios = RadiosViewModel()
  // Kept by the tabs, so Home can open a chip. Not private: the debug launch
  // hook picks the chip.
  @Binding var chip: LibraryChip
  @State private var cachedSongs: [Song] = []

  var body: some View {
    ScrollView {
      VStack(spacing: 16) {
        PageTitle("Library")
        chips
        content
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .toolbar(.hidden, for: .navigationBar)
    .refreshable { await refresh() }
    .task(id: chip) { load() }
    // An album being downloaded shows up with its first song.
    .onReceive(downloadViewModel.downloadFinished) { id in
      guard chip == .downloads else { return }
      if !albumViewModel.downloadedAlbums.contains(where: { $0.id == id }) {
        albumViewModel.fetchDownloadedAlbums()
      }
      storage.getLocalStorageInformation()
    }
    #if DEBUG
      .onAppear { applyDebugChip() }
    #endif
  }

  private var chips: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(LibraryChip.allCases) { item in
            let selected = item == chip
            Button(item.title) { chip = item }
              .font(.rowSubtitle.weight(.semibold))
              .foregroundStyle(selected ? palette.ink : palette.text)
              .padding(.horizontal, 15)
              .padding(.vertical, 9)
              .background(selected ? palette.fill : palette.surface, in: Capsule())
              .accessibilityAddTraits(selected ? .isSelected : [])
          }
        }
        .padding(.horizontal, 16)
      }
      .padding(.horizontal, -16)
      // The chips overflow the width; the chosen one stays in view.
      .onAppear { proxy.scrollTo(chip) }
      .onChange(of: chip) { withAnimation { proxy.scrollTo(chip) } }
    }
  }

  @ViewBuilder private var content: some View {
    switch chip {
    case .albums:
      listed(
        albumViewModel.state(.albums), isEmpty: albumViewModel.albums.isEmpty,
        empty: "No albums yet"
      ) {
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 18
        ) {
          ForEach(albumViewModel.albums) { AlbumTile(album: $0) }
        }
      }
    case .artists:
      listed(
        albumViewModel.state(.artists), isEmpty: albumViewModel.artists.isEmpty,
        empty: "No artists yet"
      ) {
        LazyVStack(spacing: 8) {
          ForEach(albumViewModel.artists) { artist in
            NavigationLink(value: Route.artist(artist)) {
              ItemRow(
                art: .glyph(.artist), title: artist.name,
                subtitle: counted(artist.albumCount, "album"), artSize: 46
              ) { EmptyView() }
            }
            .buttonStyle(.plain)
            .card()
            .itemMenu(.artist(artist))
          }
        }
      }
    case .playlists:
      listed(
        albumViewModel.state(.playlists), isEmpty: albumViewModel.playlists.isEmpty,
        empty: "No playlists yet"
      ) {
        LazyVStack(spacing: 8) {
          ForEach(albumViewModel.playlists) { playlist in
            NavigationLink(value: Route.playlist(playlist)) {
              ItemRow(
                art: .glyph(.playlist), title: playlist.name,
                subtitle: playlist.comment.isEmpty ? "Playlist" : playlist.comment, artSize: 46
              ) { EmptyView() }
            }
            .buttonStyle(.plain)
            .card()
            .itemMenu(.playlist(playlist))
          }
        }
      }
    case .radios:
      listed(
        AlbumViewModel.ListState(isLoading: radios.isLoading, failed: radios.error != nil),
        isEmpty: radios.radios.isEmpty, empty: "No radios on the server"
      ) {
        LazyVStack(spacing: 8) {
          ForEach(radios.radios) { radio in
            Button {
              app.play(radio)
            } label: {
              ItemRow(
                art: .glyph(.radio), title: radio.name, subtitle: "Internet radio", artSize: 46
              ) { EmptyView() }
            }
            .buttonStyle(.plain)
            .card()
            .itemMenu(.radio(radio))
          }
        }
      }
    case .liked:
      liked
    case .downloads:
      downloads
    }
  }

  /// Liked songs, then liked albums and artists out of the library lists,
  /// StarStore's edits over their listed stars, as on the watch.
  @ViewBuilder private var liked: some View {
    let songs = albumViewModel.starredSongs.filter { player.isStarred($0) }
    let albums = albumViewModel.albums.filter { stars.isStarred($0.id, listed: $0.starred) }
    let artists = albumViewModel.artists.filter { stars.isStarred($0.id, listed: $0.starred) }
    let states = [AlbumViewModel.Library.starredSongs, .albums, .artists].map(albumViewModel.state)
    listed(
      AlbumViewModel.ListState(
        isLoading: states.contains(where: \.isLoading), failed: states.contains(where: \.failed)),
      isEmpty: songs.isEmpty && albums.isEmpty && artists.isEmpty, empty: "Nothing liked yet"
    ) {
      if !songs.isEmpty {
        HStack(spacing: 10) {
          Button {
            if player.playItem(item: SongCollection.liked(songs)) {
              app.isNowPlayingPresented = true
            }
          } label: {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FillButtonStyle(height: 50))
          Button {
            if player.shuffleItem(item: SongCollection.liked(songs)) {
              app.isNowPlayingPresented = true
            }
          } label: {
            Label("Shuffle", systemImage: "shuffle").foregroundStyle(palette.accent)
          }
          .buttonStyle(PlatterButtonStyle(height: 50))
        }
      }
      LazyVStack(spacing: 8) {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          ItemRow(
            art: .cover(albumId: song.albumId), title: song.title,
            subtitle: "\(song.artist) · song",
            isPlaying: player.isCurrent(song), artSize: 46
          ) {
            heart
          }
          .card()
          .onTapGesture {
            if player.playItem(item: SongCollection.liked(songs), startingAt: index) {
              app.isNowPlayingPresented = true
            }
          }
          .accessibilityAddTraits(.isButton)
          .itemMenu(.song(song, context: "Liked Songs", isFromPlaylist: false))
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
          .card()
          .itemMenu(.album(album))
        }
        ForEach(artists) { artist in
          NavigationLink(value: Route.artist(artist)) {
            ItemRow(art: .glyph(.artist), title: artist.name, subtitle: "Artist", artSize: 46) {
              heart
            }
          }
          .buttonStyle(.plain)
          .card()
          .itemMenu(.artist(artist))
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
      LazyVStack(spacing: 8) {
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
          .card()
        }
        ForEach(albums) { DownloadRow(album: $0) }
      }
      let rate = UserDefaultsManager.downloadBitRate
      Text(
        (rate == TranscodingSettings.sourceBitRate
          ? "Downloaded in original quality." : "Downloaded at \(rate) kbps.")
          + " \(storage.localDirectorySize) on this iPhone."
      )
      .font(.meta)
      .foregroundStyle(palette.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
    }
  }

  /// The rows, or while there are none the list's loading, failed or empty
  /// state.
  @ViewBuilder private func listed(
    _ state: AlbumViewModel.ListState, isEmpty: Bool, empty: String,
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
    case .albums: albumViewModel.fetchAlbums()
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

/// A downloaded album or playlist: its songs when done, the progress while
/// it downloads, and a failure a tap retries.
private struct DownloadRow: View {
  let album: Album

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var downloadViewModel: DownloadViewModel
  @Environment(\.palette) private var palette

  var body: some View {
    let downloading = downloadViewModel.isDownloading(collectionId: album.id)
    let failed = !downloading && downloadViewModel.hasFailed(collectionId: album.id)
    Group {
      // A failed album retries in place.
      if failed {
        Button {
          app.download(album)
        } label: {
          row(downloading: false, failed: true)
        }
      } else {
        NavigationLink(value: Route.album(album)) { row(downloading: downloading, failed: failed) }
      }
    }
    .buttonStyle(.plain)
    .card()
    .itemMenu(.album(album))
  }

  private func row(downloading: Bool, failed: Bool) -> some View {
    let percent = downloadViewModel.getDownloadedTrackProgress(collectionId: album.id)
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
                AlbumService.shared.downloadedMediaFileIds(collectionId: album.id).count, "song"))
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
    .padding(.vertical, 10)
    .contentShape(Rectangle())
  }
}

/// The songs in the stream cache, most recently played first.
private struct CachedSongsView: View {
  let songs: [Song]

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  var body: some View {
    ScrollView {
      Platter {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          ItemRow(
            art: .cover(albumId: song.albumId), title: song.title, subtitle: song.artist,
            isPlaying: player.isCurrent(song), artSize: 44
          ) {
            ItemMenuButton(target: .song(song, context: "Cached", isFromPlaylist: false))
          }
          .onTapGesture {
            let cached = SongCollection(id: "cached-songs", name: "Cached", songs: songs)
            if player.playItem(item: cached, startingAt: index) { app.isNowPlayingPresented = true }
          }
          .accessibilityAddTraits(.isButton)
          .itemMenu(.song(song, context: "Cached", isFromPlaylist: false))
        }
      }
      .padding(16)
    }
    .containerBackground(palette.background, for: .navigation)
    .navigationTitle("Cached")
  }
}
