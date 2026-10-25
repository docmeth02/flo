//
//  MiniPlayer.swift
//  Ownwave
//

import SwiftUI

/// The tab bar's accessory: the song playing, which opens Now Playing, or
/// Play Something while nothing is queued. The system draws the glass.
struct MiniPlayer: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement

  var body: some View {
    if let song = player.nowPlaying {
      nowPlaying(song)
    } else {
      playSomething
    }
  }

  private func nowPlaying(_ song: QueueEntity) -> some View {
    // Inline, beside the minimized tab bar, there is room for less.
    let isInline = placement == .inline
    return HStack(spacing: 11) {
      CoverArt(albumId: player.nowPlayingAlbumId, url: player.coverArt, radius: isInline ? 14 : 20)
        .frame(width: isInline ? 28 : 40, height: isInline ? 28 : 40)
      VStack(alignment: .leading, spacing: 0) {
        Text(song.songName ?? "Unknown").font(.rowSubtitle.weight(.semibold))
        if !isInline {
          Text(song.artistName ?? "Unknown").font(.meta).foregroundStyle(palette.secondary)
        }
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: player.togglePlayback) {
        glyph(player.isPlaying ? "pause.fill" : "play.fill")
      }
      if !isInline && !player.isLiveRadio {
        Button {
          player.nextSong(userInitiated: true)
        } label: {
          glyph("forward.fill")
        }
      }
    }
    .buttonStyle(.plain)
    .padding(.leading, isInline ? 6 : 9)
    .padding(.trailing, 8)
    .contentShape(Rectangle())
    .onTapGesture { app.isNowPlayingPresented = true }
  }

  private var playSomething: some View {
    Button {
      Task { await app.playSomething() }
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "sparkles").foregroundStyle(palette.accent)
        Text("Play Something").font(.buttonLabel)
        Spacer(minLength: 0)
        if player.isGeneratingMix { ProgressView() }
      }
      .padding(.horizontal, 16)
      .frame(maxHeight: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(player.isGeneratingMix)
  }

  private func glyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 20))
      .foregroundStyle(palette.text)
      .frame(width: 42, height: 42)
      .contentShape(Rectangle())
  }
}
