//
//  WatchNowPlayingView.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

struct WatchNowPlayingView: View {
  @EnvironmentObject var playerViewModel: PlayerViewModel
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

  private var accent: Color { tint ?? .floLilac }
  private var albumId: String {
    playerViewModel.nowPlayingAlbumId
  }
  private var coverURL: String { playerViewModel.coverArt }

  var body: some View {
    // Never a scroll view: a drag would scroll it and take the crown from the
    // volume control. The text is capped so the fixed layout always fits.
    Group {
      if let song = playerViewModel.nowPlaying {
        nowPlayingContent(song)
          .dynamicTypeSize(...DynamicTypeSize.large)
          // Clears the round toolbar buttons, which reach below the clock row.
          .padding(.top, 18)
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
      Button("Boost") { ratings.set(5, playbackID: ratingTarget) }
      Button("Avoid in Smart Shuffle", role: .destructive) {
        ratings.set(1, playbackID: ratingTarget)
      }
      if ratingTargetRating > 0 {
        Button("Clear rating") { ratings.set(0, playbackID: ratingTarget) }
      }
      Button("Cancel", role: .cancel) {}
    }
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("")
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        if playerViewModel.nowPlaying != nil {
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

  private func nowPlayingContent(_ song: QueueEntity) -> some View {
    VStack(spacing: 0) {
      VStack(spacing: 1) {
        if !playerViewModel.isLiveRadio, !playerViewModel.sourceName.isEmpty {
          CapsLabel(playerViewModel.sourceName, tint: accent)
            .padding(.bottom, 2)
            // On 41 and 42 mm the round toolbar buttons reach down beside it.
            .padding(.horizontal, Self.compact ? 22 : 0)
        }
        Text(song.songName ?? "Unknown")
          .font(.floSong)
          .foregroundStyle(.white)
        if playerViewModel.isWaitingForConnection {
          Text("Offline")
            .font(.floMeta)
            .foregroundStyle(Color.floWarningText)
        } else {
          Text(song.artistName ?? "Unknown")
            .font(.floMeta)
            .foregroundStyle(accent)
        }
      }
      .lineLimit(1)
      // A long title stops short of the round toolbar buttons above it.
      .padding(.horizontal, 18)

      if playerViewModel.isLiveRadio {
        Badge(kind: .live)
          .padding(.top, 6)

        playPauseButton
          .padding(.top, 8 + Self.ringInset)
      } else {
        HStack(spacing: Self.compact ? 4 : 8) {
          Button(action: {
            playerViewModel.prevSong()
            WKInterfaceDevice.current().play(.click)
          }) {
            transportGlyph("backward.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Previous")

          playPauseButton

          Button(action: {
            playerViewModel.nextSong(userInitiated: true)
            WKInterfaceDevice.current().play(.click)
          }) {
            transportGlyph("forward.fill")
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Next")
        }
        // Room for the loading ring around the disc.
        .padding(.vertical, Self.ringInset)

        SeekBar(
          clock: playerViewModel.clock, duration: song.duration, tint: accent,
          seek: playerViewModel.seek(to:)
        )
        .padding(.horizontal, 12)

        HStack(spacing: 0) {
          Button(action: {
            playerViewModel.shuffleCurrentQueue()
            WKInterfaceDevice.current().play(.click)
          }) {
            utilityGlyph("shuffle", color: playerViewModel.isShuffling ? accent : .floSecondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Shuffle")

          Spacer(minLength: 0)

          // Not a Button: on the watch a button takes the whole touch, so a
          // long press on it never arrives. A tap stars, a hold rates.
          utilityGlyph(
            playerViewModel.isStarred ? "heart.fill" : "heart",
            color: playerViewModel.isStarred ? .floLiked : .floSecondary
          )
          .onTapGesture {
            playerViewModel.toggleStar()
            WKInterfaceDevice.current().play(.click)
          }
          .onLongPressGesture(minimumDuration: FloLayout.holdDuration) { openRating(song) }
          .accessibilityLabel(playerViewModel.isStarred ? "Unlike" : "Like")
          .accessibilityAddTraits(.isButton)
          .accessibilityAction(named: "Rate") { openRating(song) }

          if let chip = RatingChip(rating: rating) {
            Spacer(minLength: 0)
            Button {
              openRating(song)
            } label: {
              chip
            }
            .buttonStyle(.plain)
          }

          Spacer(minLength: 0)

          Button(action: {
            playerViewModel.cyclePlaybackMode()
            WKInterfaceDevice.current().play(.click)
          }) {
            utilityGlyph(
              playerViewModel.playbackMode == PlaybackMode.repeatOnce ? "repeat.1" : "repeat",
              color: playerViewModel.playbackMode != PlaybackMode.defaultPlayback
                ? accent : .floSecondary)
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Repeat")
        }
        .padding(.horizontal, 6)
        // Keeps the heart clear of the page dots.
        .padding(.bottom, Self.compact ? 6 : 8)
      }
    }
  }

  /// The dialog rates the song it was opened on, even if playback moves on.
  private func openRating(_ song: QueueEntity) {
    guard let id = song.id, !id.isEmpty else { return }
    ratingTarget = id
    showRating = true
    WKInterfaceDevice.current().play(.click)
  }

  // The 41 and 42 mm screens need smaller transport controls to keep the
  // shuffle, heart and repeat row above the page dots.
  fileprivate static let compact = WKInterfaceDevice.current().screenBounds.height < 240
  private static let disc: CGFloat = compact ? 52 : 58
  /// How far the loading ring reaches out of the disc.
  private static let ringInset: CGFloat = 6

  private func transportGlyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: Self.compact ? 28 : 32))
      .foregroundStyle(.white)
      .frame(width: Self.compact ? 44 : 48, height: Self.compact ? 44 : 48)
      .contentShape(Rectangle())
  }

  private func utilityGlyph(_ name: String, color: Color) -> some View {
    Image(systemName: name)
      .font(.system(size: 20, weight: .semibold))
      .foregroundStyle(color)
      .frame(width: 34, height: 36)
      .contentShape(Circle())
  }

  /// Fetching the stream, waiting for its data, as after a skip, or for the
  /// server to be back.
  private var isLoading: Bool {
    !playerViewModel.isMediaFailed
      && (playerViewModel.isMediaLoading || playerViewModel.isBuffering
        || playerViewModel.isWaitingForConnection)
  }

  /// A quarter arc going round once a second while the song loads. The
  /// timeline only runs while it is shown.
  private var spinner: some View {
    TimelineView(.animation) { context in
      let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
      Circle()
        .trim(from: 0, to: 0.25)
        .stroke(
          playerViewModel.isLiveRadio ? Color.floLiked : accent,
          style: StrokeStyle(lineWidth: 4, lineCap: .round)
        )
        .rotationEffect(.degrees(turn * 360 - 90))
    }
  }

  /// A white disc, ringed only while the song loads; the ring reaches out of
  /// the button's frame, so the layout stays put.
  private var playPauseButton: some View {
    Button(action: {
      playerViewModel.togglePlayback()
      WKInterfaceDevice.current().play(.success)
    }) {
      ZStack {
        Circle()
          .fill(.white)
        Image(systemName: playerViewModel.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: Self.compact ? 28 : 32))
          .foregroundStyle(Color.floInk)
      }
      .frame(width: Self.disc, height: Self.disc)
      .overlay {
        if isLoading {
          ZStack {
            Circle().stroke(.white.opacity(0.22), lineWidth: 4)
            spinner
          }
          .padding(-Self.ringInset)
        }
      }
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(playerViewModel.isPlaying ? "Pause" : "Play")
  }

  private var rating: Int {
    guard let song = playerViewModel.nowPlaying else { return 0 }
    return ratings.rating(for: song.id ?? "")
  }
}

/// A boosted or avoided song says so next to the heart; other ratings make
/// no statement to the mix.
private struct RatingChip: View {
  let title: String
  let systemImage: String
  let color: Color

  init?(rating: Int) {
    switch rating {
    case 5: (title, systemImage, color) = ("Boosted", "star.fill", .floWarning)
    case 1: (title, systemImage, color) = ("Avoided", "hand.thumbsdown.fill", .floDestructive)
    default: return nil
    }
  }

  var body: some View {
    Group {
      // The 41 and 42 mm row has no room for the label.
      if WatchNowPlayingView.compact {
        chip(Image(systemName: systemImage))
      } else {
        chip(
          HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(title)
          })
      }
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(title)
    .accessibilityAddTraits(.isButton)
  }

  private func chip(_ content: some View) -> some View {
    content
      .font(.floCaption)
      .foregroundStyle(color)
      .lineLimit(1)
      .padding(.horizontal, 8)
      .frame(minHeight: 28)
      .background(Capsule().fill(Color.floSurface2))
      .fixedSize()
  }
}

/// The song's position as a thin bar between elapsed and remaining time; a
/// tap or a drag on the bar seeks. It observes the clock itself so the
/// player does not redraw every second.
private struct SeekBar: View {
  @ObservedObject var clock: PlayerClock
  let duration: Double
  let tint: Color
  let seek: (Double) -> Void

  // The position under the finger while dragging.
  @State private var dragged: Double?

  private let knob: CGFloat = 7

  var body: some View {
    let shown = dragged ?? clock.clampedProgress
    HStack(spacing: 6) {
      Text((shown * duration).minuteSecond)
      GeometryReader { proxy in
        let width = max(proxy.size.width, 1)
        Capsule()
          .fill(.white.opacity(0.22))
          .overlay(alignment: .leading) {
            Capsule().fill(tint).frame(width: width * shown)
          }
          .frame(height: dragged == nil ? 3 : 5)
          .overlay(alignment: .leading) {
            Circle()
              .fill(tint)
              .frame(width: knob, height: knob)
              .offset(x: min(max(width * shown - knob / 2, 0), width - knob))
          }
          .frame(maxHeight: .infinity)
          .contentShape(Rectangle())
          // Ahead of the page swipe, which would take a sideways drag.
          .highPriorityGesture(
            DragGesture(minimumDistance: 0)
              .onChanged { dragged = min(max($0.location.x / width, 0), 1) }
              .onEnded { _ in
                if let dragged { seek(dragged) }
                dragged = nil
              }
          )
      }
      .frame(height: 22)
      Text("-" + (duration * (1 - shown)).minuteSecond)
    }
    .font(.floTime)
    .foregroundStyle(Color.floTimeText)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Position")
    .accessibilityValue("\((shown * duration).minuteSecond) of \(duration.minuteSecond)")
    .accessibilityAdjustableAction { direction in
      guard duration > 0 else { return }
      let step = (direction == .increment ? 15 : -15) / duration
      seek(min(max(clock.clampedProgress + step, 0), 1))
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
