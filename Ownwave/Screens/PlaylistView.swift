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

  /// The playlist with the songs shown, as the player takes it.
  private var playable: Album {
    var loaded = playlist
    loaded.songs = songs
    return Album(from: loaded)
  }

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        GlyphTile.playlist.squared(radius: 30)
          .frame(width: 180, height: 180)
        VStack(spacing: 4) {
          Text(playlist.name)
            .font(.heroTitle)
            .multilineTextAlignment(.center)
          Text(songs.isEmpty ? playlist.comment : songs.countAndLength)
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
            .lineLimit(1)
        }
        HStack(spacing: 10) {
          Button {
            app.play(playable)
          } label: {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FillButtonStyle())
          Button {
            app.shuffle(playable)
          } label: {
            Label("Shuffle", systemImage: "shuffle").foregroundStyle(palette.accent)
          }
          .buttonStyle(PlatterButtonStyle())
        }
        if !songs.isEmpty {
          Platter {
            // A playlist can hold a song twice.
            ForEach(Array(songs.enumerated()), id: \.offset) { index, song in
              let menu = MenuTarget.song(song, context: playlist.name, isFromPlaylist: true)
              SongRow(song: song, menu: menu) {
                app.play(playable, startingAt: index)
              } trailing: {
                ItemMenuButton(target: menu)
              }
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
    // Once, as an album: a return from a screen pushed on top keeps the
    // songs, also offline.
    .task(id: isLoaded) {
      guard !isLoaded else { return }
      for await songs in albumViewModel.loadSongs(of: playlist) { self.songs = songs }
      isLoaded = !Task.isCancelled && !songs.isEmpty
    }
  }
}
