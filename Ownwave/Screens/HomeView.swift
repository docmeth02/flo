//
//  HomeView.swift
//  Ownwave
//

import SwiftUI

struct HomeView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @EnvironmentObject private var pins: PinStore
  @ObservedObject private var stars = StarStore.shared
  @Environment(\.palette) private var palette
  @Environment(\.openLibrary) private var openLibrary

  @StateObject private var radios = RadiosViewModel()
  // The lists pins are looked up in, loaded or cached, read again on every
  // return so a pin made elsewhere shows up. Home never asks the server for
  // them.
  @State private var albums: [Album] = []
  @State private var artists: [Artist] = []
  @State private var playlists: [Playlist] = []

  /// Unliked songs leave at once, before the list reloads.
  private var likedSongs: [Song] {
    albumViewModel.starredSongs.filter { player.isStarred($0) }
  }

  private var pinned: [MenuTarget] {
    func pinned<T: Identifiable>(_ items: [T], _ kind: PinStore.Kind) -> [T] where T.ID == String {
      let ids = pins.pinned(kind)
      return ids.isEmpty ? [] : items.filter { ids.contains($0.id) }
    }
    return pinned(albums, .album).map(MenuTarget.album)
      + pinned(artists, .artist).map(MenuTarget.artist)
      + pinned(playlists, .playlist).map(MenuTarget.playlist)
      + pinned(radios.radios, .radio).map(MenuTarget.radio)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 26) {
        header
        playCard
        pinnedSection
        recentSection
        likedSection
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .toolbar(.hidden, for: .navigationBar)
    .task {
      albumViewModel.fetchStarredSongsIfStale()
      await albumViewModel.loadRecentAlbums()
      albums = await albumViewModel.loadedOrCached(albumViewModel.albums, .albums)
      artists = await albumViewModel.loadedOrCached(albumViewModel.artists, .artists)
      playlists = await albumViewModel.loadedOrCached(albumViewModel.playlists, .playlists)
      if !pins.pinned(.radio).isEmpty, radios.radios.isEmpty { radios.fetchAllRadios() }
      // Siri and Shortcuts read the artist names from this cache.
      await albumViewModel.cacheArtistsIfNeeded()
    }
  }

  private var header: some View {
    HStack(spacing: 10) {
      Wordmark()
      Spacer()
      NavigationLink(value: Route.watch) {
        Image(systemName: "applewatch")
      }
      .buttonStyle(CircleButtonStyle(size: 42))
      .accessibilityLabel("Watch")
      NavigationLink(value: Route.settings) {
        Image(systemName: "gearshape")
      }
      .buttonStyle(CircleButtonStyle(size: 42))
      .accessibilityLabel("Settings")
    }
    .padding(.horizontal, 4)
  }

  private var playCard: some View {
    let hasNowPlaying = player.hasNowPlaying()
    return VStack(spacing: 0) {
      if hasNowPlaying { NowPlayingCard() }
      Button {
        Task { if await player.playSomething() { app.isNowPlayingPresented = true } }
      } label: {
        Label(player.isGeneratingMix ? "Building mix…" : "Play Something", systemImage: "sparkles")
      }
      .buttonStyle(FillButtonStyle())
      .disabled(player.isGeneratingMix)
      .tourAnchor(.play)
      .padding(
        hasNowPlaying ? EdgeInsets(top: 16, leading: 14, bottom: 14, trailing: 14) : EdgeInsets())
    }
    .background(hasNowPlaying ? palette.surface : .clear)
    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
  }

  @ViewBuilder private var pinnedSection: some View {
    let pinned = pinned
    if !pinned.isEmpty {
      section("Pinned") {
        ForEach(pinned) { PinLink(target: $0) }
      }
    }
  }

  @ViewBuilder private var recentSection: some View {
    if !albumViewModel.recentAlbums.isEmpty {
      section("Recently Played") {
        ForEach(albumViewModel.recentAlbums) { AlbumTile(album: $0, width: 150) }
      }
    }
  }

  @ViewBuilder private var likedSection: some View {
    let songs = likedSongs
    if !songs.isEmpty {
      VStack(spacing: 10) {
        HStack(spacing: 14) {
          SectionTitle("Liked")
          Button("See all") { openLibrary(.liked) }
            .font(.rowSubtitle)
            .foregroundStyle(palette.accent)
          Button {
            if player.shuffleItem(item: SongCollection.liked(songs)) {
              app.isNowPlayingPresented = true
            }
          } label: {
            Image(systemName: "shuffle")
          }
          .buttonStyle(CircleButtonStyle(size: 36, foreground: palette.accent))
          .accessibilityLabel("Shuffle Liked Songs")
          Button {
            if player.playItem(item: SongCollection.liked(songs)) {
              app.isNowPlayingPresented = true
            }
          } label: {
            Image(systemName: "play.fill").font(.system(size: 15, weight: .semibold))
          }
          .buttonStyle(FillButtonStyle(height: 36))
          .frame(width: 36)
          .accessibilityLabel("Play Liked Songs")
        }
        .padding(.trailing, 4)
        VStack(spacing: 8) {
          ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
            ItemRow(
              art: .cover(albumId: song.albumId), title: song.title, subtitle: song.artist,
              isPlaying: player.isCurrent(song), artSize: 44
            ) {
              Image(systemName: "heart.fill").foregroundStyle(Color.floLiked)
            }
            .card()
            .onTapGesture {
              if player.playItem(item: SongCollection.liked(songs), startingAt: index) {
                app.isNowPlayingPresented = true
              }
            }
            .accessibilityAddTraits(.isButton)
            .itemMenu(.song(song, context: SongCollection.Name.liked, isFromPlaylist: false))
          }
        }
      }
    }
  }

  /// A titled row of tiles that scrolls sideways to the screen's edges.
  private func section(_ title: String, @ViewBuilder tiles: () -> some View) -> some View {
    VStack(spacing: 12) {
      SectionTitle(title)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 12) { tiles() }
          .padding(.horizontal, 16)
      }
      .padding(.horizontal, -16)
    }
  }
}

/// The playing song over its cover; a tap opens the player.
private struct NowPlayingCard: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  @State private var shades: CoverShades?

  var body: some View {
    let albumId = player.nowPlayingAlbumId
    let tint = shades?.tint ?? palette.accent
    Button {
      app.isNowPlayingPresented = true
    } label: {
      ZStack(alignment: .bottom) {
        CoverArt(albumId: albumId, url: player.coverArt, radius: 0)
        LinearGradient(
          stops: [
            .init(color: .clear, location: 0.15), .init(color: palette.surface, location: 0.92),
          ],
          startPoint: .top, endPoint: .bottom)
        VStack(spacing: 3) {
          Label(
            player.isPlaying ? "Now Playing" : "Paused",
            systemImage: player.isPlaying ? "pause.fill" : "play.fill"
          )
          .font(.buttonLabel)
          .foregroundStyle(tint)
          Text(player.nowPlaying.songName ?? "")
            .font(.playerTitle)
            .foregroundStyle(palette.text)
          Text((player.nowPlaying.artistName ?? "").uppercased())
            .font(.rowSubtitle)
            .tracking(0.3)
            .foregroundStyle(palette.secondary)
          ProgressLine(clock: player.clock, tint: tint, track: palette.surface2, height: 4)
            .frame(width: 150)
            .padding(.top, 8)
        }
        .lineLimit(1)
        .padding(.horizontal, 18)
        .padding(.bottom, 6)
      }
      .frame(height: 196)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .coverShades($shades, albumId: albumId, url: player.coverArt)
  }
}

/// A pinned album, artist, playlist or radio: albums show their cover, the
/// others their glyph. Radios play, the rest open.
private struct PinLink: View {
  let target: MenuTarget

  @EnvironmentObject private var app: AppModel
  @Environment(\.palette) private var palette

  var body: some View {
    Group {
      switch target {
      case .album(let album): NavigationLink(value: Route.album(album)) { tile }
      case .artist(let artist): NavigationLink(value: Route.artist(artist)) { tile }
      case .playlist(let playlist): NavigationLink(value: Route.playlist(playlist)) { tile }
      case .radio(let radio):
        Button {
          app.play(radio)
        } label: {
          tile
        }
      case .song: EmptyView()
      }
    }
    .buttonStyle(.plain)
    .itemMenu(target)
  }

  private var tile: some View {
    VStack(alignment: .leading, spacing: 7) {
      art.frame(width: 128, height: 128)
      VStack(alignment: .leading, spacing: 1) {
        Text(target.title)
          .font(.rowSubtitle.weight(.semibold))
          .foregroundStyle(palette.text)
        Text(target.subtitle)
          .font(.meta)
          .foregroundStyle(palette.secondary)
      }
      .lineLimit(1)
    }
    .frame(width: 128, alignment: .leading)
    .contentShape(Rectangle())
  }

  @ViewBuilder private var art: some View {
    switch target {
    case .album(let album): CoverArt(albumId: album.id, radius: 14)
    case .artist: GlyphTile(systemImage: "music.mic", radius: 14)
    case .playlist: GlyphTile(systemImage: "music.note.list", radius: 14)
    case .radio: GlyphTile(systemImage: "dot.radiowaves.up.forward", radius: 14)
    case .song: EmptyView()
    }
  }
}
