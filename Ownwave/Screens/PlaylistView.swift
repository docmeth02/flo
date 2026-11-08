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

  @StateObject private var loader = CollectionSongs()

  /// The playlist with the songs shown, for downloading and the menu.
  private var loaded: Playlist {
    var loaded = playlist
    loaded.songs = loader.songs
    return loaded
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
          Text(playlist.meta(loaded: loader.songs))
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
        }
        CollectionActions(playlist: loaded, reload: loader.reload)
        if !loader.songs.isEmpty {
          Platter {
            // A playlist can hold a song twice.
            ForEach(Array(loader.songs.enumerated()), id: \.offset) { index, song in
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
    .task(id: loader.reloads) { await loader.load { albumViewModel.loadSongs(of: playlist) } }
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
