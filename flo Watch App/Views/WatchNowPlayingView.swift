//
//  WatchNowPlayingView.swift
//  flo Watch App
//

import SwiftUI
import WatchKit

struct WatchNowPlayingView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel

  @State private var volume: Double = 1
  // The crown drives 1 - volume: with the system indicator drawing the bound
  // value, turning the crown so the indicator moves up raises the volume.
  @State private var crownValue: Double = 0
  @State private var showVolume: Bool = false
  @State private var volumeHideTask: Task<Void, Never>?
  @FocusState private var crownFocused: Bool

  var body: some View {
    ViewThatFits(in: .vertical) {
      if playerViewModel.hasNowPlaying() {
        nowPlayingContent
        ScrollView { nowPlayingContent }
      } else {
        Text("Nothing playing")
          .foregroundStyle(.secondary)
      }
    }
    .focusable(true)
    .focused($crownFocused)
    .digitalCrownRotation(
      $crownValue,
      from: 0,
      through: 1,
      by: 0.01,
      sensitivity: .medium,
      isContinuous: false,
      isHapticFeedbackEnabled: true
    )
    .onAppear {
      // Start from the player's real volume so the first crown notch does not
      // jump to a default.
      volume = Double(playerViewModel.player?.volume ?? 1)
      crownValue = 1 - volume
      crownFocused = true
    }
    .onDisappear {
      volumeHideTask?.cancel()
    }
    .onChange(of: crownValue) { _, newValue in
      let newVolume = 1 - newValue
      // Seeding the crown on appear is not a user change.
      guard abs(newVolume - Double(playerViewModel.player?.volume ?? 1)) > 0.001 else { return }
      volume = newVolume
      playerViewModel.player?.volume = Float(volume)
      showVolume = true
      volumeHideTask?.cancel()
      volumeHideTask = Task {
        try? await Task.sleep(for: .seconds(2))
        if !Task.isCancelled {
          showVolume = false
        }
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        if !playerViewModel.isLiveRadio {
          NavigationLink(destination: WatchQueueView()) {
            Image(systemName: "list.bullet")
          }
        }
      }
    }
  }

  private var nowPlayingContent: some View {
    VStack(spacing: 7) {
      // Header: art + metadata side by side
      HStack(spacing: 8) {
        WatchAlbumArtView(
          url: playerViewModel.getAlbumCoverArt(),
          size: 48,
          albumId: playerViewModel.nowPlaying.albumId ?? ""
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))

        VStack(alignment: .leading, spacing: 2) {
          Text(playerViewModel.nowPlaying.songName ?? "Unknown")
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)

          Text(playerViewModel.nowPlaying.artistName ?? "Unknown")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
            .lineLimit(1)

          if showVolume {
            Label("\(Int(volume * 100))%", systemImage: "speaker.wave.2.fill")
              .font(.system(size: 10))
              .foregroundColor(.secondary)
              .transition(.opacity)
          }
        }

        Spacer(minLength: 0)
      }

      if playerViewModel.isLiveRadio {
        // Live radio indicator
        Text("LIVE")
          .font(.system(size: 11, weight: .bold))
          .foregroundColor(.red)
          .padding(.horizontal, 8)
          .padding(.vertical, 2)
          .background(Capsule().fill(Color.red.opacity(0.2)))

        // Play/Pause only
        Button(action: {
          if playerViewModel.isPlaying {
            playerViewModel.pause()
          } else {
            playerViewModel.play()
          }
          WKInterfaceDevice.current().play(.success)
        }) {
          Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 22, weight: .semibold))
            .frame(width: 48, height: 48)
        }
        .buttonStyle(.plain)
        .background(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
      } else {
        // Progress bar
        VStack(spacing: 2) {
          ProgressView(value: playerViewModel.progress.isFinite ? playerViewModel.progress : 0)
            .tint(.accentColor)

          HStack {
            Text(playerViewModel.currentTimeString)
              .font(.system(size: 9))
              .foregroundColor(.secondary)
            Spacer()
            Text(playerViewModel.totalTimeString)
              .font(.system(size: 9))
              .foregroundColor(.secondary)
          }
        }

        // Transport controls
        HStack(spacing: 14) {
          Button(action: { playerViewModel.prevSong() }) {
            Image(systemName: "backward.fill")
              .font(.system(size: 18, weight: .semibold))
              .frame(width: 40, height: 40)
          }
          .buttonStyle(.plain)
          .background(Circle().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1.5))

          Button(action: {
            if playerViewModel.isPlaying {
              playerViewModel.pause()
            } else {
              playerViewModel.play()
            }
            WKInterfaceDevice.current().play(.success)
          }) {
            Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 22, weight: .semibold))
              .frame(width: 48, height: 48)
          }
          .buttonStyle(.plain)
          .background(Circle().strokeBorder(Color.accentColor, lineWidth: 2))

          Button(action: { playerViewModel.nextSong(userInitiated: true) }) {
            Image(systemName: "forward.fill")
              .font(.system(size: 18, weight: .semibold))
              .frame(width: 40, height: 40)
          }
          .buttonStyle(.plain)
          .background(Circle().strokeBorder(Color.accentColor.opacity(0.4), lineWidth: 1.5))
        }

        // Secondary controls
        HStack(spacing: 18) {
          Button(action: {
            playerViewModel.shuffleCurrentQueue()
            WKInterfaceDevice.current().play(.click)
          }) {
            Image(systemName: "shuffle")
              .font(.system(size: 21, weight: .semibold))
              .frame(width: 44, height: 44)
              .foregroundColor(playerViewModel.isShuffling ? .accentColor : .secondary)
          }
          .buttonStyle(.plain)
          .contentShape(Circle())

          Button(action: {
            playerViewModel.toggleStar()
            WKInterfaceDevice.current().play(.click)
          }) {
            Image(systemName: playerViewModel.isStarred ? "heart.fill" : "heart")
              .font(.system(size: 21, weight: .semibold))
              .frame(width: 44, height: 44)
              .foregroundColor(playerViewModel.isStarred ? .red : .secondary)
          }
          .buttonStyle(.plain)
          .contentShape(Circle())
          .id("star-\(playerViewModel.isStarred)")

          Button(action: {
            playerViewModel.setPlaybackMode()
            WKInterfaceDevice.current().play(.click)
          }) {
            Image(
              systemName: playerViewModel.playbackMode == PlaybackMode.repeatOnce
                ? "repeat.1" : "repeat"
            )
            .font(.system(size: 21, weight: .semibold))
            .frame(width: 44, height: 44)
            .foregroundColor(
              playerViewModel.playbackMode != PlaybackMode.defaultPlayback
                ? .accentColor : .secondary)
          }
          .buttonStyle(.plain)
          .contentShape(Circle())
        }
      }
    }
    .padding(.horizontal, 8)
  }
}
