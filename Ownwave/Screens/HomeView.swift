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
  // Redraws the liked songs when one is unliked from its menu.
  @ObservedObject private var stars = StarStore.shared
  @Environment(\.palette) private var palette
  @Environment(\.openLibrary) private var openLibrary

  @StateObject private var radios = RadiosViewModel()
  // The lists pins are looked up in, loaded or cached, read again on every
  // return so a pin made elsewhere shows up. Home asks the server for them
  // only while there is no cache.
  @State private var albums: [Album] = []
  @State private var artists: [Artist] = []
  @State private var playlists: [Playlist] = []

  private var pinned: [MenuTarget] {
    pins.targets(albums: albums, artists: artists, playlists: playlists, radios: radios.radios)
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
    // Again once the album list arrives: right after signing in there is no
    // cache to read yet.
    .task(id: albumViewModel.albums.isEmpty) {
      albumViewModel.fetchStarredSongsIfStale()
      await albumViewModel.loadRecentAlbums()
      albums = await albumViewModel.loadedOrCached(albumViewModel.albums, .albums)
      artists = await albumViewModel.loadedOrCached(albumViewModel.artists, .artists)
      playlists = await albumViewModel.loadedOrCached(albumViewModel.playlists, .playlists)
      if albums.isEmpty {
        albumViewModel.fetchAlbums()
        albumViewModel.getPlaylists()
      }
      if !pins.pinned(.radio).isEmpty, radios.radios.isEmpty { radios.fetchAllRadios() }
      // Siri and Shortcuts read the artist names from this cache.
      await albumViewModel.cacheArtistsIfNeeded()
    }
  }

  private var header: some View {
    HStack(spacing: 8) {
      Wordmark()
      Spacer()
      NavigationLink(value: Route.watch) {
        Image(systemName: "applewatch")
      }
      .buttonStyle(CircleButtonStyle(size: 38))
      .accessibilityLabel("Watch")
      NavigationLink(value: Route.settings) {
        Image(systemName: "gearshape")
      }
      .buttonStyle(CircleButtonStyle(size: 38))
      .accessibilityLabel("Settings")
    }
    .padding(.horizontal, 4)
  }

  /// The song loaded, if any, over Play Something.
  private var playCard: some View {
    VStack(spacing: 0) {
      if player.nowPlaying != nil { NowPlayingCard() }
      playSomething
    }
    .background(palette.surface)
    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
  }

  private var playSomething: some View {
    Button {
      Task { await app.playSomething() }
    } label: {
      HStack(spacing: 12) {
        Image(systemName: "sparkles")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(palette.accent)
        VStack(alignment: .leading, spacing: 1) {
          Text(player.isGeneratingMix ? "Building mix…" : "Play Something")
            .font(.familjen(16, relativeTo: .headline))
            .foregroundStyle(palette.text)
          Text("New mix from your whole taste")
            .font(.meta)
            .foregroundStyle(palette.secondary)
        }
        .lineLimit(1)
        Spacer(minLength: 0)
        Group {
          if player.isGeneratingMix {
            ProgressView()
          } else {
            Image(systemName: "play.fill")
          }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(palette.accent)
        .frame(width: 36, height: 36)
        .background(palette.surface2, in: Circle())
      }
      .padding(.leading, 14)
      .padding(.trailing, 12)
      .padding(.vertical, 10)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(player.isGeneratingMix)
    .tourAnchor(.play)
  }

  @ViewBuilder private var pinnedSection: some View {
    let pinned = pinned
    if !pinned.isEmpty {
      VStack(spacing: 12) {
        SectionTitle("Pinned")
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8
        ) {
          ForEach(pinned) { PinLink(target: $0) }
        }
      }
    }
  }

  @ViewBuilder private var recentSection: some View {
    if !albumViewModel.recentAlbums.isEmpty {
      VStack(spacing: 12) {
        HStack(alignment: .firstTextBaseline) {
          SectionTitle("Recently Played")
          NavigationLink("See all", value: Route.recent)
            .font(.rowSubtitle)
            .foregroundStyle(palette.accent)
            .padding(.trailing, 4)
        }
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 12) {
            ForEach(albumViewModel.recentAlbums.prefix(10)) { AlbumTile(album: $0, width: 144) }
          }
          .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
      }
    }
  }

  @ViewBuilder private var likedSection: some View {
    let songs = app.likedSongs
    if !songs.isEmpty {
      VStack(spacing: 12) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          SectionTitle("Liked")
          Button {
            app.shuffle(SongCollection.liked(songs))
          } label: {
            Image(systemName: "shuffle")
          }
          .buttonStyle(CircleButtonStyle(size: 32, foreground: palette.accent))
          .accessibilityLabel("Shuffle Liked Songs")
          Button {
            app.play(SongCollection.liked(songs))
          } label: {
            Image(systemName: "play.fill")
          }
          .buttonStyle(CircleButtonStyle(size: 32, foreground: palette.accent))
          .accessibilityLabel("Play Liked Songs")
          Button("See all") { openLibrary(.liked) }
            .font(.rowSubtitle)
            .foregroundStyle(palette.accent)
            .padding(.leading, 4)
            .padding(.trailing, 4)
        }
        Platter {
          ForEach(Array(songs.prefix(3).enumerated()), id: \.element.id) { index, song in
            let menu = MenuTarget.song(
              song, context: SongCollection.Name.liked, isFromPlaylist: false)
            SongRow(song: song, menu: menu) {
              app.play(SongCollection.liked(songs), startingAt: index)
            } trailing: {
              Image(systemName: "heart.fill").foregroundStyle(Color.floLiked)
            }
          }
        }
      }
    }
  }
}

/// The loaded song on its cover's shade: its state and time, Resume or
/// Pause, and a tap anywhere else opens the player.
private struct NowPlayingCard: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  @State private var shades: CoverShades?

  var body: some View {
    let albumId = player.nowPlayingAlbumId
    let tint = shades?.tint ?? palette.accent
    HStack(spacing: 14) {
      CoverArt(albumId: albumId, url: player.coverArt, radius: 14)
        .frame(width: 108, height: 108)
      VStack(alignment: .leading, spacing: 0) {
        PlaybackLabel(
          clock: player.clock, isPlaying: player.isPlaying,
          duration: player.isLiveRadio ? nil : player.nowPlaying?.duration
        )
        .foregroundStyle(tint)
        Text(player.nowPlaying?.songName ?? "")
          .font(.familjen(20, relativeTo: .title3))
          .foregroundStyle(palette.text)
          .padding(.top, 5)
        Text(player.nowPlaying?.artistName ?? "")
          .font(.rowSubtitle)
          .foregroundStyle(tint)
        Spacer(minLength: 10)
        Button {
          player.togglePlayback()
        } label: {
          Label(
            player.isPlaying ? "Pause" : "Resume",
            systemImage: player.isPlaying ? "pause.fill" : "play.fill")
        }
        .buttonStyle(FillButtonStyle(tint: tint, height: 40))
      }
      .lineLimit(1)
      .frame(maxHeight: .infinity)
    }
    .fixedSize(horizontal: false, vertical: true)
    .padding(14)
    .background(shades?.background ?? palette.surface2)
    .contentShape(Rectangle())
    .onTapGesture { app.isNowPlayingPresented = true }
    .accessibilityAction(named: "Open Player") { app.isNowPlayingPresented = true }
    .coverShades($shades, albumId: albumId, url: player.coverArt)
  }
}

/// "PLAYING · 0:09 / 8:34", or "LIVE" for a station. It observes the clock
/// itself, so Home does not redraw every second.
private struct PlaybackLabel: View {
  @ObservedObject var clock: PlayerClock
  let isPlaying: Bool
  /// Nil for a station, which has no length.
  let duration: Double?

  var body: some View {
    Group {
      if let duration {
        Text(
          "\(isPlaying ? "Playing" : "Paused") · "
            + "\((clock.clampedProgress * duration).minuteSecond) / \(duration.minuteSecond)")
      } else {
        Text("Live")
      }
    }
    .font(.counter)
    .tracking(1.3)
    .textCase(.uppercase)
    .monospacedDigit()
  }
}

/// A pinned album, artist, playlist or radio as a compact row: albums and
/// playlists show their cover, artists and radios their glyph. Radios play,
/// the rest open.
private struct PinLink: View {
  let target: MenuTarget

  @EnvironmentObject private var app: AppModel
  @Environment(\.palette) private var palette

  private let height: CGFloat = 56

  var body: some View {
    Group {
      switch target {
      case .album(let album): NavigationLink(value: Route.album(album)) { row }
      case .artist(let artist): NavigationLink(value: Route.artist(artist)) { row }
      case .playlist(let playlist): NavigationLink(value: Route.playlist(playlist)) { row }
      case .radio(let radio):
        Button {
          app.play(radio)
        } label: {
          row
        }
      case .song: EmptyView()
      }
    }
    .buttonStyle(.plain)
    .itemMenu(target)
  }

  private var row: some View {
    HStack(spacing: 10) {
      art
      Text(target.title)
        .font(.rowSubtitle.weight(.semibold))
        .foregroundStyle(palette.text)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.trailing, 10)
    .frame(height: height)
    .background(palette.surface)
    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  /// Covers fill the row's height at its rounded left edge; glyphs sit
  /// inset.
  @ViewBuilder private var art: some View {
    switch target {
    case .album(let album):
      CoverArt(albumId: album.id, radius: 0).frame(width: height, height: height)
    case .playlist(let playlist):
      CoverArt(albumId: playlist.id, artId: playlist.artId, radius: 0)
        .frame(width: height, height: height)
    case .artist: glyph(.artist)
    case .radio: glyph(.radio)
    case .song: EmptyView()
    }
  }

  private func glyph(_ tile: GlyphTile) -> some View {
    tile.frame(width: 40, height: 40).padding(.leading, 8)
  }
}
