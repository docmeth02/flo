//
//  ArtistView.swift
//  Ownwave
//

import SwiftUI

struct ArtistView: View {
  let artist: Artist

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var scheme

  @StateObject private var radio = ArtistDetailViewModel()
  @State private var topSongs: [Song] = []
  @State private var hue: Double?
  @State private var showsRadioError = false

  /// The screen takes its backdrop and tint from the artist's first album.
  private var albums: [Album] { albumViewModel.albums(byArtist: artist.id) }

  private var tint: Color {
    hue.map { CoverShades(hue: $0, scheme: scheme).tint } ?? palette.accent
  }

  private var meta: String {
    let albumCount = albums.isEmpty ? artist.albumCount : albums.count
    var parts: [String] = []
    // An artist opened from an album the artist list lacks has no count yet.
    if albumCount > 0 { parts.append(counted(albumCount, "album")) }
    if !topSongs.isEmpty { parts.append(counted(topSongs.count, "top song")) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        VStack(alignment: .leading, spacing: 4) {
          Text(artist.name)
            .font(.pageTitle)
            .tracking(-0.02 * 34)
            .foregroundStyle(tint)
          Text(meta)
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
        .padding(.top, 36)
        buttons
        if !topSongs.isEmpty { topSongsSection }
        if !albums.isEmpty { albumsSection }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
      .background(alignment: .top) {
        if let albumId = albums.first?.id {
          BlurredBackdrop(albumId: albumId, height: 300, opacity: 0.6)
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { albumViewModel.fetchAlbumsByArtist(id: artist.id) }
    .task(id: artist.id) { await loadTopSongs() }
    .task(id: albums.first?.id) {
      if let albumId = albums.first?.id { hue = await CoverTint.hue(albumId: albumId) }
    }
    .alert(artist.name, isPresented: $showsRadioError) {
      Button("OK") {}
    } message: {
      Text(ArtistDetailViewModel.noRadioMessage)
    }
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      Button {
        Task {
          let songs = await radio.fetchArtistRadio(artist: artist)
          if songs.isEmpty {
            showsRadioError = true
          } else if player.playItem(
            item: SongCollection.artistRadio(id: artist.id, name: artist.name, songs: songs))
          {
            app.isNowPlayingPresented = true
          }
        }
      } label: {
        if radio.isLoadingRadio {
          ProgressView()
        } else {
          Label("Artist Radio", systemImage: "dot.radiowaves.up.forward")
            .foregroundStyle(palette.accent)
        }
      }
      // Top songs online, else the artist's songs on the phone, as Siri plays
      // an artist.
      Button {
        Task {
          if await player.playArtist(id: artist.id, name: artist.name) {
            app.isNowPlayingPresented = true
          }
        }
      } label: {
        Label("Top Songs", systemImage: "music.note.list").foregroundStyle(palette.accent)
      }
    }
    .buttonStyle(PlatterButtonStyle(height: 56))
    .disabled(radio.isLoadingRadio || player.isGeneratingMix)
  }

  private var topSongsSection: some View {
    VStack(spacing: 10) {
      SectionTitle("Top Songs")
      Platter {
        ForEach(Array(topSongs.enumerated()), id: \.element.id) { index, song in
          let menu = MenuTarget.song(song, context: artist.name, isFromPlaylist: false)
          ItemRow(
            art: .cover(albumId: song.albumId), title: song.title, subtitle: song.albumName,
            isPlaying: player.isCurrent(song), artSize: 40
          ) {
            ItemMenuButton(target: menu)
          }
          .onTapGesture {
            let playable = SongCollection.artist(id: artist.id, name: artist.name, songs: topSongs)
            if player.playItem(item: playable, startingAt: index) {
              app.isNowPlayingPresented = true
            }
          }
          .accessibilityAddTraits(.isButton)
          .itemMenu(menu)
        }
      }
    }
  }

  private var albumsSection: some View {
    VStack(spacing: 10) {
      SectionTitle("Albums")
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 2), spacing: 14
      ) {
        ForEach(albums) { album in
          AlbumTile(album: album, subtitle: album.minYear > 0 ? String(album.minYear) : "")
        }
      }
    }
  }

  /// The five the design lists; Top Songs plays the server's full list.
  /// Once per screen: it reappears after every pushed album.
  private func loadTopSongs() async {
    guard topSongs.isEmpty else { return }
    let result = await withCheckedContinuation { continuation in
      RadioService.shared.getTopSongs(artistId: artist.id, count: 5) {
        continuation.resume(returning: $0)
      }
    }
    topSongs = (try? result.get()) ?? []
  }
}
