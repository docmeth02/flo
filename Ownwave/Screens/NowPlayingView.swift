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
  /// finger travel.
  private static let threshold: CGFloat = 70

  @State private var shades: CoverShades?
  @State private var showsQueue = false
  /// The damped drag on the player; positive toward the queue. A gesture
  /// state, so an interrupted pull (the phone locked mid-drag) springs back.
  @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.4)))
  private var drag: CGFloat = 0
  @State private var queuePosition = ScrollPosition(edge: .top)

  private var albumId: String { player.nowPlayingAlbumId }

  var body: some View {
    GeometryReader { proxy in
      let insets = proxy.safeAreaInsets
      let page = proxy.size.height + insets.top + insets.bottom
      if player.hasNowPlaying() {
        VStack(spacing: 0) {
          PlayerPage(
            tint: shades?.tint ?? palette.accent, isPastPeek: drag > Self.threshold,
            close: { dismiss() }, showQueue: { show(queue: true) }
          )
          .padding(.top, insets.top)
          .padding(.bottom, max(insets.bottom, 20))
          .frame(height: page)
          .contentShape(Rectangle())
          .gesture(playerDrag)
          // A station has no queue to show.
          if !player.isLiveRadio {
            ScrollView {
              UpNextPage(tint: shades?.tint ?? palette.accent, showPlayer: { show(queue: false) })
                .padding(.top, insets.top)
                .padding(.bottom, insets.bottom + 24)
            }
            .ignoresSafeArea()
            .scrollIndicators(.hidden)
            .scrollPosition($queuePosition)
            .onScrollPhaseChange { old, _, context in
              if old == .interacting, context.geometry.contentOffset.y < -Self.threshold {
                show(queue: false)
              }
            }
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
        stops: [.init(color: backdropTop, location: 0), .init(color: palette.background, location: 0.78)],
        startPoint: .top, endPoint: .bottom
      )
      .ignoresSafeArea()
    }
    // The tabs' toast and tour sit under this cover. A step of the tabs shows
    // here too while something else opened the cover, not while it closes.
    .toastOverlay(app.toast, bottom: 24)
    .tourOverlay(app.tour.flatMap { $0.isOnNowPlaying || app.isNowPlayingPresented ? $0 : nil })
    .coverShades($shades, albumId: albumId, url: player.coverArt)
    .onChange(of: player.hasNowPlaying(), initial: true) { _, playing in
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
    if !queue { queuePosition.scrollTo(edge: .top) }
  }

  /// The design's resistance: the farther the finger, the less the player
  /// follows, up to 320 pt. 0.55 is the system's own overscroll factor.
  private static func rubberBand(_ travel: CGFloat) -> CGFloat {
    let limit: CGFloat = 320
    let damped = (1 - 1 / (abs(travel) * 0.55 / limit + 1)) * limit
    return travel < 0 ? -damped : damped
  }
}

/// The first page: cover, song, scrubber, transport, rating and the peek at
/// Up Next.
private struct PlayerPage: View {
  let tint: Color
  let isPastPeek: Bool
  let close: () -> Void
  let showQueue: () -> Void

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @ObservedObject private var ratings = RatingStore.shared
  @ObservedObject private var mixes = RecommendationLog.shared
  @Environment(\.palette) private var palette

  private var song: QueueEntity { player.nowPlaying }

  var body: some View {
    VStack(spacing: 16) {
      header
      CoverArt(albumId: player.nowPlayingAlbumId, url: player.coverArt, radius: 18)
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 322)
        .shadow(color: .black.opacity(0.35), radius: 25, y: 24)
      titleRow
      if let why = mixes.shownReason(for: song) { pill(why.note) }
      if player.isLiveRadio {
        Text("Live")
          .font(.meta.weight(.semibold))
          .foregroundStyle(Color.floLiked)
          .frame(height: 43)
      } else {
        Scrubber(
          clock: player.clock, duration: song.duration, tint: tint, status: status,
          seek: player.seek(to:))
      }
      transport
      if !player.isLiveRadio {
        stars
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
      VStack(spacing: 1) {
        Text("Playing from")
          .font(.counter)
          .tracking(0.12 * 11)
          .textCase(.uppercase)
          .foregroundStyle(palette.secondary)
        Text(player.sourceName).font(.playingFrom).lineLimit(1)
      }
      Spacer()
      // A station is neither queued nor liked like a song.
      if player.isLiveRadio {
        Color.clear.frame(width: 40, height: 40)
      } else {
        Menu {
          ItemMenuItems(
            target: .song(
              Song(from: song), context: song.contextName ?? "", isFromPlaylist: song.isFromPlaylist))
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

  /// Why the mix picked the song, tucked up to the title row.
  private func pill(_ note: String) -> some View {
    Text(note)
      .font(.rowSubtitle)
      .foregroundStyle(palette.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.vertical, 9)
      .padding(.horizontal, 12)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      .tourAnchor(.why)
      .padding(.top, -6)
  }

  /// Why the song is not playing, when it waits on more than its data.
  private var status: String? {
    if player.isStreamingBlocked { return "Streaming on cellular is off" }
    if player.isWaitingForConnection { return "Offline" }
    return nil
  }

  private var transport: some View {
    HStack {
      if !player.isLiveRadio {
        Button(action: player.shuffleCurrentQueue) {
          Image(systemName: "shuffle")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(player.isShuffling ? tint : palette.secondary)
            .frame(width: 44, height: 44)
        }
        Spacer()
        Button(action: player.prevSong) { skipGlyph("backward.fill") }
        Spacer()
      }
      PlayPauseButton(tint: tint)
      if !player.isLiveRadio {
        Spacer()
        Button { player.nextSong(userInitiated: true) } label: { skipGlyph("forward.fill") }
        Spacer()
        Button(action: player.cyclePlaybackMode) {
          Image(systemName: player.playbackMode == PlaybackMode.repeatOnce ? "repeat.1" : "repeat")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(
              player.playbackMode == PlaybackMode.defaultPlayback ? palette.secondary : tint)
            .frame(width: 44, height: 44)
        }
      }
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 2)
  }

  private func skipGlyph(_ name: String) -> some View {
    Image(systemName: name)
      .font(.system(size: 30))
      .foregroundStyle(palette.text)
      .frame(width: 56, height: 56)
      .contentShape(Rectangle())
  }

  private var rating: Int { ratings.rating(for: song.id ?? "") }

  private static let ratingLabels = [
    "", "Avoided · won’t come up in mixes", "Rated 2", "Rated 3", "Rated 4",
    "Boosted · comes up more often",
  ]

  private var stars: some View {
    VStack(spacing: 6) {
      HStack(spacing: 6) {
        ForEach(1...5, id: \.self) { n in
          Button { rate(n) } label: {
            Image(systemName: n <= rating ? "star.fill" : "star")
              .font(.system(size: 24, weight: .medium))
              .foregroundStyle(
                n > rating ? palette.secondary : rating == 1 ? Color.floDestructive : .floWarning
              )
              .frame(width: 40, height: 40)
          }
          .buttonStyle(.plain)
        }
      }
      // Holds its line while unrated, so nothing below moves.
      Text(Self.ratingLabels[rating].isEmpty ? " " : Self.ratingLabels[rating])
        .font(.meta)
        .foregroundStyle(palette.secondary)
    }
    .padding(.top, 4)
    .padding(.bottom, 6)
    .tourAnchor(.rate)
  }

  /// Tapping the current rating again clears it.
  private func rate(_ n: Int) {
    let value = rating == n ? 0 : n
    player.rateNowPlaying(value)
    if value == 1 { app.show("Avoided · skipped from mixes") }
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
        .frame(width: 82, height: 82)
        .background(palette.text, in: Circle())
        .overlay {
          Circle().inset(by: -3).stroke(palette.hairline, lineWidth: 6)
          if isLoading {
            TimelineView(.animation) { context in
              let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
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

/// The song's position, draggable, with elapsed and remaining time; observes
/// the clock itself so the player does not redraw every second.
private struct Scrubber: View {
  @ObservedObject var clock: PlayerClock
  let duration: Double
  let tint: Color
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
        ZStack(alignment: .leading) {
          Capsule().fill(palette.hairline)
          Capsule().fill(tint).frame(width: width * shown)
        }
        .frame(height: 5)
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

/// The second page: the song playing and the songs after it in play order,
/// each removable with Undo.
private struct UpNextPage: View {
  let tint: Color
  let showPlayer: () -> Void

  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var player: PlayerViewModel
  @ObservedObject private var mixes = RecommendationLog.shared
  @Environment(\.palette) private var palette

  /// The rows after the current one, with their index in the play order.
  private var upNext: [(offset: Int, element: QueueEntity)] {
    Array(player.queue.enumerated().dropFirst(player.activeQueueIdx + 1))
  }

  private var meta: String {
    guard player.isSmartMix else { return counted(player.queue.count, "song") }
    return UserDefaultsManager.keepPlaying ? "Smart Mix · Keep Playing on" : "Smart Mix"
  }

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 12) {
        GlassCircle(systemImage: "chevron.down", action: showPlayer)
        Text("Up Next").font(.sectionTitle).frame(maxWidth: .infinity, alignment: .leading)
        Text(meta).font(.meta).foregroundStyle(palette.secondary)
      }
      current
      LazyVStack(spacing: 8) {
        ForEach(upNext, id: \.element.objectID) { index, item in
          row(item, at: index)
        }
      }
      if upNext.isEmpty {
        Text(
          UserDefaultsManager.keepPlaying
            ? "Nothing up next. Keep Playing will continue with Smart Shuffle."
            : "Nothing up next."
        )
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
        .multilineTextAlignment(.center)
        .padding(.top, 24)
      }
    }
    .padding(.horizontal, 20)
  }

  private var current: some View {
    let song = player.nowPlaying
    return HStack(spacing: 12) {
      CoverArt(albumId: player.nowPlayingAlbumId, url: player.coverArt, radius: 8)
        .frame(width: 52, height: 52)
      VStack(alignment: .leading, spacing: 1) {
        Text(song.songName ?? "Unknown")
          .font(.rowTitle.weight(.bold))
          .foregroundStyle(tint)
        Text(song.artistName ?? "Unknown")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
        ProgressLine(clock: player.clock, tint: tint).padding(.top, 6)
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button(action: player.togglePlayback) {
        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
          .font(.system(size: 20))
          .foregroundStyle(palette.text)
          .frame(width: 44, height: 44)
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 10)
    .padding(.leading, 10)
    .padding(.trailing, 8)
    .contentShape(Rectangle())
    .onTapGesture(perform: showPlayer)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  private func row(_ item: QueueEntity, at index: Int) -> some View {
    HStack(spacing: 12) {
      CoverArt(albumId: item.albumId ?? "", radius: 7).frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(item.songName ?? "Unknown").font(.rowTitle.weight(.semibold))
        Text(item.artistName ?? "Unknown").font(.meta).foregroundStyle(palette.secondary)
        if let why = mixes.shownReason(for: item) {
          Text(why.note).font(.whyLine).foregroundStyle(palette.secondary).padding(.top, 1)
        }
      }
      .lineLimit(1)
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        remove(at: index)
      } label: {
        Image(systemName: "xmark")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(palette.secondary)
          .frame(width: 36, height: 36)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
    .padding(.vertical, 10)
    .padding(.leading, 12)
    .padding(.trailing, 6)
    .contentShape(Rectangle())
    .onTapGesture { player.playFromQueue(idx: index) }
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }

  private func remove(at index: Int) {
    guard let removed = player.removeFromQueue(at: index) else { return }
    app.show("Removed from Up Next") { player.undoRemove(removed) }
  }
}

/// A 40 pt round glass button: the chevrons and the song's •••.
private struct GlassCircle: View {
  let systemImage: String
  let action: () -> Void

  var body: some View {
    Button(action: action) { Self.label(systemImage) }.buttonStyle(.plain)
  }

  static func label(_ systemImage: String) -> some View {
    Image(systemName: systemImage)
      .font(.system(size: 17, weight: .semibold))
      .frame(width: 40, height: 40)
      .glassEffect(.regular.interactive(), in: Circle())
  }
}

extension RecommendationLog {
  /// Why a mix queued the entry, while the listener wants to see it.
  fileprivate func shownReason(for entry: QueueEntity) -> MixReason? {
    guard UserDefaultsManager.showMixReasons,
      entry.playbackOrigin.isMix, let id = entry.id
    else { return nil }
    return reason(for: id)
  }
}

extension Font {
  /// The queue's source under "Playing from".
  fileprivate static let playingFrom = familjen(14, relativeTo: .subheadline)
  /// The reason under an Up Next row.
  fileprivate static let whyLine = system(.caption)
}
