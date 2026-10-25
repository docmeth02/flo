//
//  NowPlayingView.swift
//  Ownwave
//

import SwiftUI

/// The player, and one page down Up Next. The player follows a vertical
/// drag through a rubber band, so the queue opens, and a pull down closes the
/// player, only past a point; short of it the player springs back. The queue
/// scrolls on its own, and pulling down at its top returns to the player
/// through the system's own bounce.
struct NowPlayingView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette
  @Environment(\.dismiss) private var dismiss

  /// A drag commits once its damped distance passes this, about 165 pt of
  /// finger travel; the pull at Up Next's top uses it too.
  static let threshold: CGFloat = 70

  @State private var shades: CoverShades?
  @State private var showsQueue = false
  /// The damped drag on the player; positive toward the queue. A gesture
  /// state, so an interrupted pull (the phone locked mid-drag) springs back.
  @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.4)))
  private var drag: CGFloat = 0

  private var albumId: String { player.nowPlayingAlbumId }

  var body: some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      let page = proxy.size.height + insets.top + insets.bottom
      if let song = player.nowPlaying {
        VStack(spacing: 0) {
          PlayerPage(
            song: song, tint: shades?.tint ?? palette.accent, isPastPeek: drag > Self.threshold,
            close: { dismiss() }, showQueue: { show(queue: true) }
          )
          .padding(.top, insets.top)
          .padding(.bottom, max(insets.bottom, 20))
          .frame(height: page)
          .contentShape(Rectangle())
          .gesture(playerDrag)
          // A station has no queue to show.
          if !player.isLiveRadio {
            UpNextList(
              tint: shades?.tint ?? palette.accent,
              insets: EdgeInsets(
                top: insets.top, leading: 0, bottom: insets.bottom + 24, trailing: 0),
              isShown: showsQueue, showPlayer: { show(queue: false) }
            )
            .ignoresSafeArea()
            .frame(height: page)
          }
        }
        .offset(y: (showsQueue ? -page : 0) - drag)
        .frame(height: page, alignment: .top)
        .ignoresSafeArea()
        #if DEBUG
          .task { await runDebugUpNext { show(queue: true) } }
        #endif
      }
    }
    // Keeps the queue's rows from running under the status bar.
    .overlay(alignment: .top) {
      GeometryReader { proxy in
        LinearGradient(
          colors: [backdropTop, backdropTop.opacity(0)], startPoint: .top, endPoint: .bottom
        )
        .frame(height: proxy.safeAreaInsets.top + 8)
        .ignoresSafeArea()
      }
      .allowsHitTesting(false)
    }
    .background {
      LinearGradient(
        stops: [
          .init(color: backdropTop, location: 0), .init(color: palette.background, location: 0.78),
        ],
        startPoint: .top, endPoint: .bottom
      )
      .ignoresSafeArea()
    }
    // The tabs' toast and tour sit under this cover. A step of the tabs shows
    // here too while something else opened the cover, not while it closes.
    .toastOverlay(app.toast, bottom: 24)
    .tourOverlay(app.tour.flatMap { $0.isOnNowPlaying || app.isNowPlayingPresented ? $0 : nil })
    .coverShades($shades, albumId: albumId, url: player.coverArt)
    .onChange(of: player.nowPlaying != nil, initial: true) { _, playing in
      if !playing { dismiss() }
    }
  }

  private var backdropTop: Color { shades?.background ?? palette.surface }

  /// Up toward the queue, down to close; the scrubber's own drag wins on it.
  private var playerDrag: some Gesture {
    DragGesture(minimumDistance: 10)
      .updating($drag) { value, drag, _ in drag = damped(value) }
      .onEnded { value in
        let pulled = damped(value)
        if pulled > Self.threshold, !player.isLiveRadio {
          show(queue: true)
        } else if pulled < -Self.threshold {
          dismiss()
        }
      }
  }

  private func damped(_ value: DragGesture.Value) -> CGFloat {
    let travel = -value.translation.height
    // A station has no queue: the pull up only gives.
    return Self.rubberBand(player.isLiveRadio ? min(travel, 0) : travel)
  }

  private func show(queue: Bool) {
    withAnimation(.smooth(duration: 0.5)) { showsQueue = queue }
  }

  /// The design's resistance: the farther the finger, the less the player
  /// follows, up to 320 pt. 0.55 is the system's own overscroll factor.
  private static func rubberBand(_ travel: CGFloat) -> CGFloat {
    let limit: CGFloat = 320
    let damped = (1 - 1 / (abs(travel) * 0.55 / limit + 1)) * limit
    return travel < 0 ? -damped : damped
  }
}

/// The first page: cover, song, scrubber, transport, the row of shuffle,
/// rating and repeat, why the mix picked the song, and the peek at Up Next.
private struct PlayerPage: View {
  let song: QueueEntity
  let tint: Color
  let isPastPeek: Bool
  let close: () -> Void
  let showQueue: () -> Void

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @ObservedObject private var ratings = RatingStore.shared
  @ObservedObject private var mixes = RecommendationLog.shared
  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 16) {
      header
      CoverArt(albumId: player.nowPlayingAlbumId, url: player.coverArt, radius: 20)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 345)
        .shadow(color: .black.opacity(0.35), radius: 25, y: 24)
      titleRow
      if player.isLiveRadio {
        Text("Live")
          .font(.meta.weight(.semibold))
          .foregroundStyle(Color.floLiked)
          .frame(height: 43)
      } else {
        Scrubber(
          clock: player.clock, duration: song.duration, status: status, seek: player.seek(to:))
      }
      transport
      if !player.isLiveRadio {
        utilityRow
        reason
        Spacer(minLength: 0)
        peek
      } else {
        Spacer(minLength: 0)
      }
    }
    .padding(.horizontal, 24)
  }

  private var header: some View {
    HStack {
      GlassCircle(systemImage: "chevron.down", action: close)
      Spacer()
      source
      Spacer()
      // A station is neither queued nor liked like a song.
      if player.isLiveRadio {
        Color.clear.frame(width: 40, height: 40)
      } else {
        Menu {
          ItemMenuItems(
            target: .song(
              Song(from: song), context: song.contextName ?? "", isFromPlaylist: song.isFromPlaylist
            ))
        } label: {
          GlassCircle.label("ellipsis")
        }
      }
    }
  }

  private var titleRow: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(song.songName ?? "Unknown").font(.playerTitle)
        Text(song.artistName ?? "Unknown")
          .font(.rowTitle.weight(.regular))
          .foregroundStyle(tint)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      if !player.isLiveRadio { heart }
    }
  }

  private var heart: some View {
    Button {
      let liked = !player.isStarred
      player.toggleStar()
      app.show(liked ? "Liked" : "Removed from Liked")
    } label: {
      Image(systemName: player.isStarred ? "heart.fill" : "heart")
        .font(.system(size: 20, weight: .semibold))
        .foregroundStyle(player.isStarred ? Color.floLiked : palette.text)
        .frame(width: 46, height: 46)
        .glassEffect(.regular.interactive(), in: Circle())
    }
    .buttonStyle(.plain)
  }

  /// Where the queue came from, behind a glyph for its kind.
  private var source: some View {
    HStack(spacing: 6) {
      Image(systemName: sourceSymbol)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(tint)
      Text(player.sourceName).font(.source).lineLimit(1)
    }
    .padding(.horizontal, 12)
    .frame(height: 28)
    .glassEffect(.regular, in: Capsule())
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Playing from \(player.sourceName)")
  }

  /// The queue entry knows only its queue's name and whether a playlist
  /// queued it, so the rest is told by the name.
  private var sourceSymbol: String {
    if player.isLiveRadio { return "dot.radiowaves.left.and.right" }
    switch song.playbackOrigin {
    case .smartShuffle, .keepPlaying: return "sparkles"
    case .starred: return "heart.fill"
    case .cached: return "arrow.down.circle"
    case .playlist: return "music.note.list"
    case .album:
      guard let name = song.contextName else { return "music.note" }
      if name == song.albumName { return "square.stack" }
      if name == song.artistName { return "music.mic" }
      if name == SongCollection.Name.search { return "magnifyingglass" }
      if name.hasSuffix(SongCollection.Name.artistRadioSuffix) {
        return "dot.radiowaves.left.and.right"
      }
      return "music.note"
    }
  }

  /// Why the song is not playing, when it waits on more than its data.
  private var status: String? {
    if player.isStreamingBlocked { return "Streaming on cellular is off" }
    if player.isWaitingForConnection { return "Offline" }
    return nil
  }

  private var transport: some View {
    HStack(spacing: 40) {
      if !player.isLiveRadio {
        Button(action: player.prevSong) { skipGlyph("backward.fill") }
      }
      PlayPauseButton(tint: tint)
      if !player.isLiveRadio {
        Button {
          player.nextSong(userInitiated: true)
        } label: {
          skipGlyph("forward.fill")
        }
      }
    }
    .buttonStyle(.plain)
  }

  /// Shuffle, the rating and repeat under the transport.
  private var utilityRow: some View {
    HStack {
      Button(action: player.shuffleCurrentQueue) {
        modeGlyph("shuffle", isOn: player.isShuffling)
      }
      Spacer(minLength: 0)
      stars
      Spacer(minLength: 0)
      Button(action: player.cyclePlaybackMode) {
        modeGlyph(
          player.playbackMode == PlaybackMode.repeatOnce ? "repeat.1" : "repeat",
          isOn: player.playbackMode != PlaybackMode.defaultPlayback)
      }
    }
    .buttonStyle(.plain)
  }

  private func modeGlyph(_ name: String, isOn: Bool) -> some View {
    Image(systemName: name)
      .font(.system(size: 20, weight: .semibold))
      .foregroundStyle(isOn ? tint : palette.secondary)
      .frame(width: 44, height: 44)
  }

  private func skipGlyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 30))
      .foregroundStyle(palette.text)
      .frame(width: 56, height: 56)
      .contentShape(Rectangle())
  }

  private var rating: Int { ratings.rating(for: song.id ?? "") }

  private static let ratingLabels = ["", "Avoided", "Rated 2", "Rated 3", "Rated 4", "Boosted"]

  private var ratingColor: Color {
    switch rating {
    case 1: .floDestructive
    case 5: .floWarning
    default: palette.secondary
    }
  }

  /// Five stars and the rating's label after them.
  private var stars: some View {
    HStack(spacing: 10) {
      HStack(spacing: 0) {
        ForEach(1...5, id: \.self) { n in
          Button {
            rate(n)
          } label: {
            Image(systemName: n <= rating ? "star.fill" : "star")
              .font(.system(size: 18, weight: .medium))
              .foregroundStyle(
                n > rating ? palette.secondary : rating == 1 ? Color.floDestructive : .floWarning
              )
              .frame(width: 28, height: 44)
              .contentShape(Rectangle())
          }
          .accessibilityLabel(counted(n, "star"))
        }
      }
      // Every label holds the slot, so the stars stay put as the rating
      // changes.
      ZStack(alignment: .leading) {
        ForEach(Self.ratingLabels, id: \.self) { Text($0).hidden() }
        Text(Self.ratingLabels[rating]).foregroundStyle(ratingColor)
      }
      .font(.meta.weight(.semibold))
    }
    .tourAnchor(.rate)
  }

  /// Why the mix picked the song, on a line kept while there is none, so
  /// the page does not move between songs.
  private var reason: some View {
    Text(" ")
      .hidden()
      .frame(maxWidth: .infinity)
      .overlay {
        if let why = mixes.shownReason(for: song) {
          ReasonLabel(reason: why, isShort: false)
            .foregroundStyle(palette.secondary)
            .tourAnchor(.why)
        }
      }
      .font(.meta)
      .padding(.top, -10)
  }

  /// Tapping the current rating again clears it.
  private func rate(_ n: Int) {
    let value = rating == n ? 0 : n
    player.rateNowPlaying(value)
    if value == 1 { app.show("Avoided · skipped") }
    if value == 5 { app.show("Boosted") }
  }

  private var peek: some View {
    Button(action: showQueue) {
      VStack(spacing: 6) {
        Capsule()
          .fill(palette.secondary)
          .frame(width: 36, height: 5)
          .opacity(isPastPeek ? 1 : 0.45)
        HStack(spacing: 6) {
          Text(isPastPeek ? "Release for Up Next" : "Up Next")
            .fontWeight(.bold)
            .foregroundStyle(isPastPeek ? tint : palette.text)
          if !isPastPeek {
            Text(nextUp).foregroundStyle(palette.secondary).lineLimit(1)
          }
        }
        .font(.rowSubtitle)
      }
      .padding(.top, 4)
      .frame(maxWidth: .infinity)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .tourAnchor(.peek)
  }

  private var nextUp: String {
    let index = player.activeQueueIdx + 1
    guard player.queue.indices.contains(index) else { return "End of queue" }
    let next = player.queue[index]
    return "\(next.songName ?? "Unknown") · \(next.artistName ?? "Unknown")"
  }
}

/// The big play button: a disc in the text color inside a hairline ring,
/// which spins a tinted arc while the song loads or waits.
private struct PlayPauseButton: View {
  let tint: Color

  @EnvironmentObject private var player: PlayerViewModel
  @Environment(\.palette) private var palette

  private var isLoading: Bool {
    !player.isMediaFailed
      && (player.isMediaLoading || player.isBuffering || player.isWaitingForConnection)
  }

  var body: some View {
    Button(action: player.togglePlayback) {
      Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
        .font(.system(size: 32))
        .foregroundStyle(palette.background)
        .frame(width: 76, height: 76)
        .background(palette.text, in: Circle())
        .overlay {
          Circle().inset(by: -3).stroke(palette.hairline, lineWidth: 6)
          if isLoading {
            TimelineView(.animation) { context in
              let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(
                dividingBy: 1)
              Circle()
                .inset(by: -3)
                .trim(from: 0, to: 0.25)
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(turn * 360 - 90))
            }
          }
        }
    }
    .buttonStyle(.plain)
  }
}

/// The song's position as a thin track with a knob, draggable, with elapsed
/// and remaining time; observes the clock itself so the player does not
/// redraw every second.
private struct Scrubber: View {
  @ObservedObject var clock: PlayerClock
  let duration: Double
  let status: String?
  let seek: (Double) -> Void

  @Environment(\.palette) private var palette
  // The position under the finger while dragging.
  @State private var dragged: Double?
  // Decided when a drag starts: sideways seeks, up or down is the pager's.
  @State private var seeks: Bool?

  var body: some View {
    let shown = dragged ?? clock.clampedProgress
    VStack(spacing: 7) {
      GeometryReader { proxy in
        let width = max(proxy.size.width, 1)
        let knob: CGFloat = dragged == nil ? 10 : 14
        ZStack(alignment: .leading) {
          Capsule().fill(palette.hairline)
          Capsule().fill(palette.text).frame(width: width * shown)
        }
        .frame(height: 4)
        .overlay(alignment: .leading) {
          Circle()
            .fill(palette.text)
            .frame(width: knob, height: knob)
            .offset(x: min(max(width * shown - knob / 2, 0), width - knob))
        }
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { seek(min(max($0.x / width, 0), 1)) }
        .gesture(
          DragGesture(minimumDistance: 6)
            .onChanged {
              if seeks == nil { seeks = abs($0.translation.width) > abs($0.translation.height) }
              guard seeks == true else { return }
              dragged = min(max($0.location.x / width, 0), 1)
            }
            .onEnded { _ in
              if let dragged { seek(dragged) }
              dragged = nil
              seeks = nil
            }
        )
      }
      .frame(height: 18)
      HStack {
        Text((shown * duration).minuteSecond)
        Spacer()
        if let status {
          Text(status).foregroundStyle(Color.floWarning)
          Spacer()
        }
        Text("-" + (duration * (1 - shown)).minuteSecond)
      }
      .font(.meta.weight(.semibold))
      .monospacedDigit()
      .foregroundStyle(palette.secondary)
    }
  }
}

extension Font {
  /// The queue's source in the header's pill.
  fileprivate static let source = brand(14, relativeTo: .subheadline)
}
