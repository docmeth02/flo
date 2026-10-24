//
//  AlbumView.swift
//  Ownwave
//

import SwiftUI

struct AlbumView: View {
  let album: Album

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  // Redraws the track hearts when a song is liked from its menu.
  @ObservedObject private var stars = StarStore.shared
  @Environment(\.palette) private var palette

  @State private var songs: [Song] = []
  @State private var isLoaded = false
  /// Bumped by a removed download, which loads the screen again.
  @State private var reloads = 0
  @State private var shades: CoverShades?

  /// The album with the tracks shown, for playing, downloading and the menu.
  private var loadedAlbum: Album {
    var loaded = album
    loaded.songs = songs
    return loaded
  }

  private var tint: Color { shades?.tint ?? palette.fill }

  /// The album artist as the Artist screen takes it: the listed one when the
  /// library has it.
  private var artist: Artist? {
    let id = album.albumArtistId.isEmpty ? album.artistId : album.albumArtistId
    guard !id.isEmpty else { return nil }
    return albumViewModel.artists.first { $0.id == id }
      ?? Artist(id: id, name: album.albumArtist, albumCount: 0, mbzArtistID: nil)
  }

  private var meta: String {
    var parts: [String] = []
    if album.minYear > 0 { parts.append(String(album.minYear)) }
    let length = songs.countAndLength
    if !length.isEmpty { parts.append(length) }
    return parts.joined(separator: " · ")
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        CoverArt(albumId: album.id, radius: 16)
          .frame(width: 236, height: 236)
          .shadow(color: .black.opacity(0.35), radius: 20, y: 18)
        titleBlock
        CollectionActions(album: loadedAlbum, tint: tint) {
          isLoaded = false
          reloads += 1
        }
        tracks
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
      .background(alignment: .top) { BlurredBackdrop(albumId: album.id, height: 430) }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          ItemMenuItems(target: .album(loadedAlbum))
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
      }
    }
    .coverShades($shades, albumId: album.id)
    // Once: a return from a screen pushed on top keeps the loaded tracks,
    // also offline. A load cut short by that push or left empty runs again,
    // and so does one after a removed download.
    .task(id: reloads) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: album) { self.songs = songs }
      isLoaded = !Task.isCancelled && !songs.isEmpty
    }
  }

  private var titleBlock: some View {
    VStack(spacing: 5) {
      Text(album.name)
        .font(.heroTitle)
        .multilineTextAlignment(.center)
      HStack(spacing: 0) {
        if let artist {
          NavigationLink(value: Route.artist(artist)) {
            Text(album.albumArtist).fontWeight(.semibold).foregroundStyle(tint)
          }
          .buttonStyle(.plain)
        } else {
          Text(album.albumArtist)
        }
        if !meta.isEmpty { Text(" · " + meta) }
      }
      .font(.rowSubtitle)
      .foregroundStyle(palette.secondary)
      .lineLimit(1)
    }
  }

  // MARK: - Tracks

  @ViewBuilder private var tracks: some View {
    if !songs.isEmpty {
      Platter {
        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
          TrackRow(
            number: song.trackNumber, song: song, tint: tint,
            menu: .song(song, context: album.name, isFromPlaylist: false)
          ) {
            app.play(loadedAlbum, startingAt: index)
          }
        }
      }
    }
  }
}

/// A numbered track: a waveform in the cover tint while it plays, a small
/// heart when liked, its length and the ••• menu.
private struct TrackRow: View {
  let number: Int
  let song: Song
  let tint: Color
  let menu: MenuTarget
  let play: () -> Void

  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  var body: some View {
    let playing = player.isCurrent(song)
    HStack(spacing: 12) {
      Group {
        if playing {
          Image(systemName: "waveform")
            .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
        } else {
          Text("\(number)")
        }
      }
      .font(.rowSubtitle.monospacedDigit())
      .foregroundStyle(playing ? tint : palette.secondary)
      .frame(width: 22)
      Text(song.title)
        .font(.rowTitle.weight(.regular))
        .foregroundStyle(playing ? tint : palette.text)
        .lineLimit(1)
      Spacer(minLength: 0)
      if player.isStarred(song) {
        Image(systemName: "heart.fill")
          .font(.system(size: 12))
          .foregroundStyle(Color.floLiked)
      }
      Text(song.duration.minuteSecond)
        .font(.rowSubtitle.monospacedDigit())
        .foregroundStyle(palette.secondary)
      ItemMenuButton(target: menu)
    }
    .frame(minHeight: 52)
    .contentShape(Rectangle())
    .songActions(menu, play: play)
  }
}
