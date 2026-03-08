//
//  WatchNowPlayingView.swift
//  flo Watch App
//

import SwiftUI
import WatchKit

struct WatchNowPlayingView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  var body: some View {
    VStack(spacing: 4) {
      // Album art
      WatchAlbumArtView(
        url: playerViewModel.getAlbumCoverArt(),
        size: 75,
        albumId: playerViewModel.nowPlaying.albumId ?? ""
      )
      .clipShape(RoundedRectangle(cornerRadius: 10))

      // Song title
      Text(playerViewModel.nowPlaying.songName ?? "Unknown")
        .font(.system(size: 13, weight: .bold))
        .lineLimit(1)
        .multilineTextAlignment(.center)

      // Artist name
      Text(playerViewModel.nowPlaying.artistName ?? "Unknown")
        .font(.system(size: 11))
        .foregroundColor(.secondary)
        .lineLimit(1)

      if playerViewModel.isLiveRadio {
        // Live radio: simple LIVE indicator
        Text("LIVE")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.red)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.red.opacity(0.2)))

        // Play/Pause only, centered
        Button(action: {
          if playerViewModel.isPlaying {
            playerViewModel.pause()
          } else {
            playerViewModel.play()
          }
          WKInterfaceDevice.current().play(.success)
        }) {
          Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 20))
            .frame(width: 44, height: 44)
            .foregroundColor(.accentColor)
            .background(
              Circle()
                .strokeBorder(Color.accentColor, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
      } else {
        // Progress bar with time labels
        VStack(spacing: 1) {
          ProgressView(value: playerViewModel.progress.isFinite ? playerViewModel.progress : 0)
            .tint(.accentColor)

          HStack {
            Text(playerViewModel.currentTimeString)
              .font(.system(size: 10))
              .foregroundColor(.secondary)
            Spacer()
            Text(playerViewModel.totalTimeString)
              .font(.system(size: 10))
              .foregroundColor(.secondary)
          }
        }
        .padding(.horizontal, 2)

        // Playback controls
        HStack(spacing: 12) {
          Button(action: {
            playerViewModel.prevSong()
          }) {
            Image(systemName: "backward.fill")
              .font(.system(size: 14))
              .frame(width: 36, height: 36)
              .foregroundColor(.accentColor)
              .background(
                Circle()
                  .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1.5)
              )
          }
          .buttonStyle(.plain)

          Button(action: {
            if playerViewModel.isPlaying {
              playerViewModel.pause()
            } else {
              playerViewModel.play()
            }
            WKInterfaceDevice.current().play(.success)
          }) {
            Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 20))
              .frame(width: 44, height: 44)
              .foregroundColor(.accentColor)
              .background(
                Circle()
                  .strokeBorder(Color.accentColor, lineWidth: 2)
              )
          }
          .buttonStyle(.plain)

          Button(action: {
            playerViewModel.nextSong()
          }) {
            Image(systemName: "forward.fill")
              .font(.system(size: 14))
              .frame(width: 36, height: 36)
              .foregroundColor(.accentColor)
              .background(
                Circle()
                  .strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1.5)
              )
          }
          .buttonStyle(.plain)
        }

        // Shuffle, Heart & Repeat
        HStack(spacing: 16) {
          Button(action: {
            playerViewModel.shuffleCurrentQueue()
          }) {
            Image(systemName: "shuffle")
              .font(.system(size: 15))
              .frame(width: 36, height: 36)
              .foregroundColor(playerViewModel.isShuffling ? .accentColor : .secondary)
          }
          .buttonStyle(.plain)

          Button(action: {
            playerViewModel.toggleStar()
            WKInterfaceDevice.current().play(.click)
          }) {
            Image(systemName: playerViewModel.isStarred ? "heart.fill" : "heart")
              .font(.system(size: 15))
              .frame(width: 36, height: 36)
              .foregroundColor(playerViewModel.isStarred ? .red : .secondary)
          }
          .buttonStyle(.plain)
          .id("star-\(playerViewModel.isStarred)")

          Button(action: {
            playerViewModel.setPlaybackMode()
          }) {
            Image(
              systemName: playerViewModel.playbackMode == PlaybackMode.repeatOnce
                ? "repeat.1" : "repeat"
            )
            .font(.system(size: 15))
            .frame(width: 36, height: 36)
            .foregroundColor(
              playerViewModel.playbackMode != PlaybackMode.defaultPlayback
                ? .accentColor : .secondary)
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(.horizontal, 8)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !playerViewModel.isLiveRadio {
        ToolbarItem(placement: .topBarTrailing) {
          NavigationLink(destination: WatchQueueView()) {
            Image(systemName: "list.bullet")
          }
        }
      }
    }
  }
}
