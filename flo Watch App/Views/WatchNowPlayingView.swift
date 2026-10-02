//
//  WatchNowPlayingView.swift
//  flo Watch App
//

import SwiftUI
import WatchKit

struct WatchNowPlayingView: View {
  @EnvironmentObject var playerViewModel: WatchPlayerViewModel
  @ObservedObject private var ratings = RatingStore.shared

  // Next to the library page, the crown belongs to the volume control only
  // while the player is the selected page, so the library still scrolls.
  var ownsCrown = true

  @Environment(\.scenePhase) private var scenePhase
  // False while a view such as the queue is pushed on top of the player.
  @State private var isShown = false
  // Bumped when the volume control must claim the crown again: the system
  // takes it back while the app is in the background.
  @State private var focusRequest = 0
  @State private var showRating = false

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
    .onAppear {
      isShown = true
      focusRequest += 1
    }
    .onDisappear { isShown = false }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { focusRequest += 1 }
    }
    .confirmationDialog(
      rating == 0 ? "Not rated" : "Rated \(rating)", isPresented: $showRating,
      titleVisibility: .visible
    ) {
      Button("Boost") { playerViewModel.rateNowPlaying(5) }
      Button("Avoid in Smart Shuffle", role: .destructive) { playerViewModel.rateNowPlaying(1) }
      if rating > 0 {
        Button("Clear rating") { playerViewModel.rateNowPlaying(0) }
      }
      Button("Cancel", role: .cancel) {}
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
        }

        Spacer(minLength: 0)

        SystemVolumeControl(isFocused: ownsCrown && isShown, focusRequest: focusRequest)
          .frame(width: 32, height: 32)
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
              .foregroundColor(playerViewModel.isStarred ? .red : .secondary)
              .overlay(alignment: .topTrailing) { ratingGlyph.offset(x: 7, y: -5) }
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .contentShape(Circle())
          .id("star-\(playerViewModel.isStarred)")
          // Holding the heart rates the song for smart shuffle.
          .onLongPressGesture {
            showRating = true
            WKInterfaceDevice.current().play(.click)
          }

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

  private var rating: Int {
    playerViewModel.hasNowPlaying() ? ratings.rating(for: playerViewModel.nowPlaying.id ?? "") : 0
  }

  /// A boosted or avoided song is marked on the heart; 3 is no statement.
  @ViewBuilder private var ratingGlyph: some View {
    if rating >= 4 {
      Image(systemName: "sparkle")
        .font(.system(size: 9, weight: .bold))
        .foregroundColor(.accentColor)
    } else if (1...2).contains(rating) {
      Image(systemName: "hand.thumbsdown.fill")
        .font(.system(size: 9, weight: .bold))
        .foregroundColor(.secondary)
    }
  }
}

/// The system volume control, as in the Now Playing app: the crown sets the
/// output volume of the watch, including the headphones it plays through.
private struct SystemVolumeControl: WKInterfaceObjectRepresentable {
  let isFocused: Bool
  let focusRequest: Int

  final class Coordinator {
    var isFocused = false
    var focusRequest = 0
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeWKInterfaceObject(context: Context) -> WKInterfaceVolumeControl {
    let control = WKInterfaceVolumeControl(origin: .local)
    control.setTintColor(UIColor(Color.accentColor))
    return control
  }

  func updateWKInterfaceObject(_ control: WKInterfaceVolumeControl, context: Context) {
    // Focus only moves on a change. Moving it on every update lets the focus
    // change trigger the next update, which locked up the app.
    let coordinator = context.coordinator
    let refocus = isFocused && focusRequest != coordinator.focusRequest
    guard isFocused != coordinator.isFocused || refocus else { return }
    coordinator.isFocused = isFocused
    coordinator.focusRequest = focusRequest

    let focus = isFocused
    DispatchQueue.main.async {
      if focus {
        control.focus()
      } else {
        control.resignFocus()
      }
    }
  }
}
