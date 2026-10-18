//
//  PlaylistView.swift
//  Ownwave
//

import SwiftUI

struct PlaylistView: View {
  let playlist: Playlist

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @Environment(\.palette) private var palette

  // The loaded playlist stays with this screen when another one opens on top.
  @State private var localPlaylist: Playlist?

  private var displayPlaylist: Playlist { localPlaylist ?? playlist }

  var body: some View {
    let songs = displayPlaylist.songs
    ScrollView {
      VStack(spacing: 18) {
        GlyphTile(systemImage: "music.note.list", radius: 30)
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
            if player.playItem(item: Album(from: displayPlaylist)) {
              app.isNowPlayingPresented = true
            }
          } label: {
            Label("Play", systemImage: "play.fill")
          }
          .buttonStyle(FillButtonStyle())
          Button {
            if player.shuffleItem(item: Album(from: displayPlaylist)) {
              app.isNowPlayingPresented = true
            }
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
              ItemRow(
                art: .cover(albumId: song.albumId), title: song.title, subtitle: song.artist,
                isPlaying: player.isCurrent(song), artSize: 44
              ) {
                ItemMenuButton(target: menu)
              }
              .onTapGesture {
                if player.playItem(item: Album(from: displayPlaylist), startingAt: index) {
                  app.isNowPlayingPresented = true
                }
              }
              .accessibilityAddTraits(.isButton)
              .itemMenu(menu)
            }
          }
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
    .onAppear {
      if localPlaylist == nil { albumViewModel.setActivePlaylist(playlist: playlist) }
    }
    .onReceive(albumViewModel.$playlist) { updated in
      if updated.id == playlist.id, !updated.songs.isEmpty { localPlaylist = updated }
    }
  }
}
