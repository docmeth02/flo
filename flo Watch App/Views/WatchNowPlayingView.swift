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
  @State private var ratingTarget = ""

  private var ratingTargetRating: Int { ratings.rating(for: ratingTarget) }

  @State private var tint: Color?

  private var accent: Color { tint ?? .floLavender }
  // nowPlaying indexes the queue, which can be empty here.
  private var albumId: String {
    playerViewModel.hasNowPlaying() ? playerViewModel.nowPlaying.albumId ?? "" : ""
  }
  private var coverURL: String {
    playerViewModel.hasNowPlaying() ? playerViewModel.getAlbumCoverArt() : ""
  }

  var body: some View {
    ViewThatFits(in: .vertical) {
      if playerViewModel.hasNowPlaying() {
        nowPlayingContent
        ScrollView { nowPlayingContent }
      } else {
        Text("Nothing playing")
          .foregroundStyle(Color.floSecondary)
      }
    }
    .background { CoverBackdrop(albumId: albumId, url: coverURL) }
    .task(id: albumId) { tint = await CoverTint.color(albumId: albumId, url: coverURL) }
    .onAppear {
      isShown = true
      focusRequest += 1
    }
    .onDisappear { isShown = false }
    .onChange(of: scenePhase) { _, phase in
      if phase == .active { focusRequest += 1 }
    }
    .confirmationDialog(
      ratingTargetRating == 0 ? "Not rated" : "Rated \(ratingTargetRating)",
      isPresented: $showRating, titleVisibility: .visible
    ) {
      // The song the dialog was opened for, even if playback moved on.
      Button("Boost") { playerViewModel.rate(5, playbackID: ratingTarget) }
      Button("Avoid in Smart Shuffle", role: .destructive) {
        playerViewModel.rate(1, playbackID: ratingTarget)
      }
      if ratingTargetRating > 0 {
        Button("Clear rating") { playerViewModel.rate(0, playbackID: ratingTarget) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        if playerViewModel.hasNowPlaying() {
          SystemVolumeControl(isFocused: ownsCrown && isShown, focusRequest: focusRequest)
            .frame(width: 26, height: 26)
        }
      }
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
    VStack(spacing: 0) {
      VStack(spacing: 1) {
        Text(playerViewModel.nowPlaying.songName ?? "Unknown")
          .font(.floSong)
          .foregroundStyle(.white)
        Text(playerViewModel.nowPlaying.artistName ?? "Unknown")
          .font(.floMeta)
          .foregroundStyle(Color.floOnCover)
      }
      .lineLimit(1)
      .padding(.horizontal, 8)

      if playerViewModel.isLiveRadio {
        Badge(kind: .live)
          .padding(.top, 6)

        playPauseButton
          .padding(.top, 8)
      } else {
        HStack(spacing: Self.compact ? 0 : 4) {
          Button(action: { playerViewModel.prevSong() }) {
            transportGlyph("backward.fill")
          }
          .buttonStyle(.plain)

          playPauseButton

          Button(action: { playerViewModel.nextSong(userInitiated: true) }) {
            transportGlyph("forward.fill")
          }
          .buttonStyle(.plain)
        }
        .padding(.top, Self.compact ? 0 : 3)

        HStack(spacing: 6) {
          Text(elapsed)
          Text("/").opacity(0.5)
          Text(remaining)
        }
        .font(.floTime)
        .foregroundStyle(Self.timeColor)
        .padding(.top, Self.compact ? 0 : 2)

        HStack(spacing: 0) {
          Button(action: {
            playerViewModel.shuffleCurrentQueue()
            WKInterfaceDevice.current().play(.click)
          }) {
            Image(systemName: "shuffle")
              .font(.system(size: 22, weight: .semibold))
              .foregroundStyle(playerViewModel.isShuffling ? accent : .floSecondary)
              .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .contentShape(Circle())

          Spacer(minLength: 0)

          // Not a Button: on the watch a button takes the whole touch, so a
          // long press on it never arrives. A tap stars, a hold rates.
          Image(systemName: playerViewModel.isStarred ? "heart.fill" : "heart")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(playerViewModel.isStarred ? Color.floLiked : .floSecondary)
            .overlay(alignment: .topTrailing) { ratingGlyph.offset(x: 7, y: -5) }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .onTapGesture {
              playerViewModel.toggleStar()
              WKInterfaceDevice.current().play(.click)
            }
            .onLongPressGesture(minimumDuration: 0.5) {
              ratingTarget = playerViewModel.nowPlaying.id ?? ""
              showRating = true
              WKInterfaceDevice.current().play(.click)
            }

          Spacer(minLength: 0)

          Button(action: {
            playerViewModel.setPlaybackMode()
            WKInterfaceDevice.current().play(.click)
          }) {
            Image(
              systemName: playerViewModel.playbackMode == PlaybackMode.repeatOnce
                ? "repeat.1" : "repeat"
            )
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(
              playerViewModel.playbackMode != PlaybackMode.defaultPlayback
                ? accent : .floSecondary)
            .frame(width: 44, height: 44)
          }
          .buttonStyle(.plain)
          .contentShape(Circle())
        }
        .padding(.horizontal, 14)
        // Keeps the heart clear of the page dots.
        .padding(.bottom, Self.compact ? 8 : 10)
      }
    }
  }

  private static let timeColor = Color(red: 0xC4 / 255, green: 0xC3 / 255, blue: 0xCF / 255)
  // The 41 and 42 mm screens need smaller transport controls to keep the
  // shuffle, heart and repeat row above the page dots.
  private static let compact = WKInterfaceDevice.current().screenBounds.height < 240

  private func transportGlyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: Self.compact ? 28 : 32))
      .foregroundStyle(.white)
      .frame(width: Self.compact ? 44 : 48, height: Self.compact ? 44 : 48)
      .contentShape(Rectangle())
  }

  /// A white disc inside a ring: song progress in the cover tint, or red for
  /// live radio, which has no progress.
  private var playPauseButton: some View {
    Button(action: {
      if playerViewModel.isPlaying {
        playerViewModel.pause()
      } else {
        playerViewModel.play()
      }
      WKInterfaceDevice.current().play(.success)
    }) {
      ZStack {
        if playerViewModel.isLiveRadio {
          Circle().stroke(Color.floLiked, lineWidth: 4)
        } else {
          Circle().stroke(.white.opacity(0.22), lineWidth: 4)
          Circle()
            .trim(from: 0, to: progress)
            .stroke(accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            .rotationEffect(.degrees(-90))
        }
        Circle()
          .fill(.white)
          .frame(width: Self.compact ? 54 : 62, height: Self.compact ? 54 : 62)
        Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: Self.compact ? 28 : 34))
          .foregroundStyle(.black)
      }
      .padding(2)
      .frame(width: Self.compact ? 68 : 78, height: Self.compact ? 68 : 78)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
  }

  private var progress: Double {
    let value = playerViewModel.progress
    return value.isFinite ? min(max(value, 0), 1) : 0
  }

  /// "00:18" as "0:18".
  private var elapsed: String {
    let time = playerViewModel.currentTimeString
    return time.count > 4 && time.hasPrefix("0") ? String(time.dropFirst()) : time
  }

  private var remaining: String {
    let duration = playerViewModel.nowPlaying.duration
    let left = duration.isFinite && duration > 0 ? max(duration * (1 - progress), 0) : 0
    let seconds = Int(left.rounded())
    return String(format: "-%d:%02d", seconds / 60, seconds % 60)
  }

  private var rating: Int {
    playerViewModel.hasNowPlaying() ? ratings.rating(for: playerViewModel.nowPlaying.id ?? "") : 0
  }

  /// A boosted or avoided song is marked on the heart; 3 is no statement.
  @ViewBuilder private var ratingGlyph: some View {
    if rating >= 4 {
      Image(systemName: "sparkle")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.floLavender)
    } else if (1...2).contains(rating) {
      Image(systemName: "hand.thumbsdown.fill")
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(Color.floSecondary)
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
