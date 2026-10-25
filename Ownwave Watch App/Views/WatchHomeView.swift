//
//  WatchHomeView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchHomeView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel
  @EnvironmentObject var albumViewModel: AlbumViewModel
  @EnvironmentObject private var pinStore: PinStore

  @Environment(\.showPlayer) private var showPlayer
  @Environment(\.selectPlayerPage) private var selectPlayerPage
  @State private var openedAlbum: Album?
  @State private var openedArtist: Artist?
  @State private var openedPlaylist: Playlist?
  @State private var openedScreen: LibraryScreen?
  @State private var menu: MenuTarget?

  @StateObject private var radios = RadiosViewModel()
  // The lists pins are looked up in, loaded or cached, read again on every
  // return so a pin made elsewhere shows up.
  @State private var albums: [Album] = []
  @State private var artists: [Artist] = []
  @State private var playlists: [Playlist] = []

  /// Ids of Home's sections, kept across redesigns: screenshots scroll to
  /// them (FLO_DEBUG_HOME_SCROLL).
  enum Anchor: String {
    case card, pinned, recent, library, settings
  }

  private var pinned: [MenuTarget] {
    pinStore.targets(albums: albums, artists: artists, playlists: playlists, radios: radios.radios)
  }

  var body: some View {
    List {
      if CoreDataManager.shared.isUsingVolatileStore {
        StorageWarningRow()
      }

      card
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
        .id(Anchor.card)

      let pinned = pinned
      if !pinned.isEmpty {
        Section {
          ForEach(Array(pinned.enumerated()), id: \.element.id) { index, target in
            pinRow(target)
              .floJoinedRow(RowPosition(index: index, count: pinned.count))
          }
        } header: {
          FloSectionHeader("Pinned").id(Anchor.pinned)
        }
      }

      let recent = albumViewModel.recentAlbums
      if !recent.isEmpty {
        Section {
          ForEach(Array(recent.enumerated()), id: \.element.id) { index, album in
            CoverRow(
              tile: .cover(albumId: album.id), title: album.name, subtitle: album.albumArtist,
              tileSize: FloLayout.smallThumbnail
            )
            .holdable(onTap: { openedAlbum = album }, onHold: { menu = .album(album) })
            .floJoinedRow(RowPosition(index: index, count: recent.count))
          }
        } header: {
          FloSectionHeader("Recently Played").id(Anchor.recent)
        }
      }

      Section {
        library
          .listRowBackground(Color.clear)
          .listRowInsets(EdgeInsets())
          .id(Anchor.settings)
      } header: {
        FloSectionHeader("Library").id(Anchor.library)
      }
    }
    // Joined rows: the default style shrinks the rows at the screen's edges
    // and splits their platter.
    .listStyle(.plain)
    // As low as their content; at 0 watchOS skips a section's edge rows.
    .environment(\.defaultMinListRowHeight, 1)
    .scrollContentBackground(.hidden)
    .background(alignment: .top) {
      // Fixed behind the list like the mockup: rows scroll over the cover.
      if playerViewModel.nowPlaying != nil {
        CoverBackdrop(
          albumId: playerViewModel.nowPlayingAlbumId,
          url: playerViewModel.coverArt, height: 190)
      }
    }
    .navigationDestination(item: $openedAlbum) { WatchAlbumDetailView(album: $0) }
    .navigationDestination(item: $openedArtist) { WatchArtistDetailView(artist: $0) }
    .navigationDestination(item: $openedPlaylist) { WatchPlaylistDetailView(playlist: $0) }
    .navigationDestination(item: $openedScreen) { $0.view }
    .itemMenu($menu)
    .navigationTitle("")
    // Runs again on every return to Home, so a song just heard shows up, and
    // after a login fills the artist cache Siri and Shortcuts read. Again as
    // the lists arrive: right after signing in there is no cache to read.
    .task(
      id: [
        albumViewModel.albums.isEmpty, albumViewModel.artists.isEmpty,
        albumViewModel.playlists.isEmpty,
      ]
    ) {
      await albumViewModel.loadRecentAlbums()
      albums = await albumViewModel.loadedOrCached(albumViewModel.albums, .albums)
      artists = await albumViewModel.loadedOrCached(albumViewModel.artists, .artists)
      playlists = await albumViewModel.loadedOrCached(albumViewModel.playlists, .playlists)
      if albums.isEmpty { albumViewModel.fetchAlbums() }
      if playlists.isEmpty { albumViewModel.getPlaylists() }
      // Stations have no cache; asked once while one is pinned.
      if !pinStore.pinned(.radio).isEmpty, radios.radios.isEmpty { radios.fetchAllRadios() }
      await albumViewModel.cacheArtistsIfNeeded()
    }
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Wordmark()
      }
    }
    #if DEBUG
      .task { await runDebugFetchAlbums() }
      .modifier(DebugHomeScroll())
    #endif
  }

  /// The playing song, if any, over Play Something, on one platter.
  private var card: some View {
    VStack(spacing: 0) {
      if playerViewModel.nowPlaying != nil {
        NowPlayingIndicator()
          .holdable(onTap: { selectPlayerPage() }, onHold: nil)
      }
      playSomething
    }
    .background(Color.floSurface)
    .clipShape(RoundedRectangle(cornerRadius: FloLayout.platterRadius, style: .continuous))
  }

  /// The whole strip plays; its round mark says so. One tap target, so a
  /// tap never starts two mixes.
  private var playSomething: some View {
    HStack(spacing: FloLayout.tileSpacing) {
      Image(systemName: "sparkles")
        .font(.system(size: 20))
        .foregroundStyle(Color.floLilac)
      VStack(alignment: .leading, spacing: 1) {
        Text(playerViewModel.isGeneratingMix ? "Building mix…" : "Play Something")
          .font(.floSong)
          .lineLimit(1)
          // Whole on 41 and 42 mm too.
          .minimumScaleFactor(0.7)
        Text("From your whole taste")
          .font(.floMeta)
          .foregroundStyle(Color.floSecondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      Image(systemName: "play.fill")
        .floRoundGlyph()
    }
    .padding(.leading, 12)
    .padding(.trailing, 10)
    .padding(.vertical, 10)
    .holdable(onTap: playSomethingNow, onHold: nil)
    .opacity(playerViewModel.isGeneratingMix ? 0.6 : 1)
    .disabled(playerViewModel.isGeneratingMix)
  }

  private func playSomethingNow() {
    guard !playerViewModel.isGeneratingMix else { return }
    Task { if await playerViewModel.playSomething() { showPlayer() } }
  }

  /// Albums, artists and playlists open, a station plays; a hold opens the
  /// menu.
  private func pinRow(_ target: MenuTarget) -> some View {
    CoverRow(
      tile: CoverTile(target), title: target.title, subtitle: target.subtitle,
      tileSize: FloLayout.smallThumbnail
    )
    .holdable(
      onTap: {
        switch target {
        case .album(let album): openedAlbum = album
        case .artist(let artist): openedArtist = artist
        case .playlist(let playlist): openedPlaylist = playlist
        case .radio(let radio): if playerViewModel.playRadioItem(radio: radio) { showPlayer() }
        case .song: break
        }
      },
      onHold: { menu = target })
  }

  /// Two tiles a row, in one clear list row. Buttons, not navigation links:
  /// a list draws a link in a row as the row itself, without the tile style.
  private var library: some View {
    LazyVGrid(
      columns: Array(repeating: GridItem(spacing: FloLayout.listRowGap), count: 2),
      spacing: FloLayout.listRowGap
    ) {
      ForEach(LibraryScreen.allCases, id: \.self) { screen in
        Button {
          openedScreen = screen
        } label: {
          Label(screen.title, systemImage: screen.systemImage)
        }
        .buttonStyle(FloTileButtonStyle(tint: screen.tint))
      }
    }
  }
}

/// The screens Home's library grid opens.
private enum LibraryScreen: CaseIterable {
  case search, liked, artists, albums, playlists, radios, downloads, settings

  var title: String {
    switch self {
    case .search: "Search"
    case .liked: "Liked"
    case .artists: "Artists"
    case .albums: "Albums"
    case .playlists: "Playlists"
    case .radios: "Radios"
    case .downloads: "Downloads"
    case .settings: "Settings"
    }
  }

  var systemImage: String {
    switch self {
    case .search: "magnifyingglass"
    case .liked: "heart.fill"
    case .artists: "music.mic"
    case .albums: "square.stack"
    case .playlists: "music.note.list"
    case .radios: CoverTile.radioGlyph
    case .downloads: "arrow.down.circle"
    case .settings: "gear"
    }
  }

  var tint: Color {
    switch self {
    case .liked: .floLiked
    case .settings: .floSecondary
    default: .floLilac
    }
  }

  @ViewBuilder var view: some View {
    switch self {
    case .search: WatchSearchView()
    case .liked: WatchLikedView()
    case .artists: WatchArtistsListView()
    case .albums: WatchAlbumsListView()
    case .playlists: WatchPlaylistsListView()
    case .radios: WatchRadiosView()
    case .downloads: WatchDownloadsView()
    case .settings: WatchSettingsView()
    }
  }
}
