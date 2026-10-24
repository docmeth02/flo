//
//  PlaylistView.swift
//  Ownwave
//

import SwiftUI

struct PlaylistView: View {
  let playlist: Playlist

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @Environment(\.palette) private var palette

  @State private var songs: [Song] = []
  @State private var isLoaded = false
  /// Bumped by a removed download, which loads the screen again.
  @State private var reloads = 0

  /// The playlist with the songs shown, for downloading and the menu.
  private var loaded: Playlist {
    var loaded = playlist
    loaded.songs = songs
    return loaded
  }

  /// "Playlist · 3 songs · 16 min", from the server's counts until the
  /// songs are loaded.
  private var meta: String {
    var length = songs.countAndLength
    if length.isEmpty, playlist.songCount > 0 {
      length = counted(playlist.songCount, "song")
      if playlist.duration > 0 { length += " · \(Int((playlist.duration / 60).rounded())) min" }
    }
    return length.isEmpty ? "Playlist" : "Playlist · " + length
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        CoverArt(albumId: playlist.id, artId: playlist.artId, radius: 24)
          .frame(width: 216, height: 216)
          .shadow(color: .black.opacity(0.35), radius: 20, y: 18)
        VStack(spacing: 4) {
          Text(playlist.name)
            .font(.heroTitle)
            .multilineTextAlignment(.center)
          Text(meta)
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
        }
        CollectionActions(playlist: loaded) {
          isLoaded = false
          reloads += 1
        }
        if !songs.isEmpty {
          Platter {
            // A playlist can hold a song twice.
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
              PlaylistTrackRow(
                song: song, menu: .song(song, context: playlist.name, isFromPlaylist: true)
              ) {
                app.play(Album(from: loaded), startingAt: index)
              }
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          ItemMenuItems(target: .playlist(loaded))
        } label: {
          Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More")
      }
    }
    // Once, as an album: a return from a screen pushed on top keeps the
    // songs, also offline. A removed download loads them again.
    .task(id: reloads) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: playlist) { self.songs = songs }
      isLoaded = !Task.isCancelled && !songs.isEmpty
    }
  }
}

/// A playlist song: its cover, the title with a waveform in the accent
/// while it plays, the artist, its length and the ••• menu.
private struct PlaylistTrackRow: View {
  let song: Song
  let menu: MenuTarget
  let play: () -> Void

  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  var body: some View {
    let playing = player.isCurrent(song)
    HStack(spacing: 12) {
      CoverArt(albumId: song.albumId, radius: 7).frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 2) {
        HStack(spacing: 5) {
          if playing {
            Image(systemName: "waveform")
              .font(.system(size: 13, weight: .semibold))
              .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
          }
          Text(song.title).lineLimit(1)
        }
        .font(.rowTitle)
        .foregroundStyle(playing ? palette.accent : palette.text)
        Text(song.artist)
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
          .lineLimit(1)
      }
      Spacer(minLength: 0)
      Text(song.duration.minuteSecond)
        .font(.meta.monospacedDigit())
        .foregroundStyle(palette.secondary)
      ItemMenuButton(target: menu)
    }
    .padding(.vertical, 8)
    .contentShape(Rectangle())
    .songActions(menu, play: play)
  }
}
