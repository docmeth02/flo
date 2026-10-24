//
//  TasteView.swift
//  Ownwave
//

import SwiftUI

/// The Taste tab's parts, one chip each.
enum TasteSegment: String, CaseIterable, Identifiable {
  case profile, top, boosted, avoided, skips

  var id: Self { self }
  var title: String { rawValue.capitalized }
}

/// What Play Something learns from: the latest mix's recipe, the artists of
/// the last 60 days, and the ratings and skips, each of which can be taken
/// back here.
struct TasteView: View {
  @EnvironmentObject private var app: AppModel
  // Liked follows the heart of the song playing.
  @EnvironmentObject private var player: PlayerViewModel
  @EnvironmentObject private var albumViewModel: AlbumViewModel
  @Environment(\.palette) private var palette
  @Environment(\.openLibrary) private var openLibrary
  @ObservedObject private var mixes = RecommendationLog.shared

  // Not private: the debug launch hook picks the segment.
  @SceneStorage("tasteSegment") var segment = TasteSegment.profile
  @State private var summary: TasteSummary?

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        PageTitle("Your Taste")
        segments
        if let summary {
          content(summary)
        } else {
          StateView(kind: .loading)
        }
      }
      .padding(.horizontal, 16)
      .padding(.top, 8)
      .padding(.bottom, 24)
    }
    .toolbar(.hidden, for: .navigationBar)
    // A mix played while the tab is open changes the recipe.
    .task(id: mixes.played.first?.at) {
      albumViewModel.fetchStarredSongsIfStale()
      await reload()
    }
    // The tour's step here points at the recipe on Profile.
    .onChange(of: app.tour, initial: true) { if $1 == .taste { segment = .profile } }
    #if DEBUG
      .onAppear { applyDebugSegment() }
    #endif
  }

  private var segments: some View {
    ChipBar(options: TasteSegment.allCases.map { ($0, $0.title, nil) }, selection: $segment)
  }

  @ViewBuilder private func content(_ summary: TasteSummary) -> some View {
    switch segment {
    case .profile:
      TasteProfile(
        summary: summary,
        likedCount: app.likedSongs.count,
        openLiked: { openLibrary(.liked) }, open: { segment = $0 })
    case .top:
      list(isEmpty: summary.top.isEmpty, empty: "No plays in the last 60 days yet.") {
        ForEach(Array(summary.top.enumerated()), id: \.element.id) { rank, artist in
          TopRow(rank: rank + 1, artist: artist)
        }
      }
    case .boosted:
      list(isEmpty: summary.boosted.isEmpty, empty: "Nothing boosted yet.") {
        ForEach(summary.boosted) { row in
          ratedRow(row, action: "Unboost") { unrate(row, toast: "Boost removed") }
        }
      }
    case .avoided:
      list(isEmpty: summary.avoided.isEmpty, empty: "Nothing avoided.") {
        ForEach(summary.avoided) { row in
          ratedRow(row, action: "Allow") { unrate(row, toast: "Allowed again") }
        }
      }
    case .skips:
      list(isEmpty: summary.skips.isEmpty, empty: "No recent skips.") {
        ForEach(summary.skips) { skip in
          ItemRow(
            art: .cover(albumId: skip.albumId), title: skip.title, subtitle: skip.subtitle,
            artSize: 40, subtitleLines: 2
          ) {
            actionButton("Undo") { forget(skip) }
          }
        }
      }
    }
  }

  /// The segment's rows on one platter, or its empty text there.
  @ViewBuilder private func list(
    isEmpty: Bool, empty: String, @ViewBuilder rows: () -> some View
  ) -> some View {
    Platter {
      if isEmpty {
        Text(empty)
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
          .multilineTextAlignment(.center)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 28)
      } else {
        rows()
      }
    }
  }

  private func ratedRow(
    _ row: TasteSummary.Rated, action: String, perform: @escaping () -> Void
  ) -> some View {
    ItemRow(
      art: row.kind == .song ? .cover(albumId: row.albumId) : .glyph(.artist), title: row.title,
      subtitle: row.subtitle, artSize: 40
    ) {
      actionButton(action, perform: perform)
    }
  }

  private func actionButton(_ title: String, perform: @escaping () -> Void) -> some View {
    Button(title, action: perform)
      .buttonStyle(.plain)
      .font(.rowSubtitle.weight(.semibold))
      .foregroundStyle(palette.accent)
      .padding(.vertical, 8)
      .padding(.leading, 10)
  }

  private func reload() async {
    summary = await TasteSummary.load()
  }

  /// Clears the boost or the avoid; the row leaves at once, Undo rates it
  /// as before and brings it back.
  private func unrate(_ row: TasteSummary.Rated, toast: String) {
    let ratings = RatingStore.shared
    let stars =
      row.kind == .song ? ratings.rating(for: row.id) : ratings.artistRating(row.id)
    rate(row, 0)
    summary?.boosted.removeAll { $0.kind == row.kind && $0.id == row.id }
    summary?.avoided.removeAll { $0.kind == row.kind && $0.id == row.id }
    app.show("\(toast) · \(row.title)") {
      // Taking back the change avoids nothing new.
      rate(row, stars, skipsPlaying: false)
      Task { await reload() }
    }
  }

  private func rate(_ row: TasteSummary.Rated, _ stars: Int, skipsPlaying: Bool = true) {
    switch row.kind {
    case .song: RatingStore.shared.set(stars, playbackID: row.id, skipsPlaying: skipsPlaying)
    case .artist:
      RatingStore.shared.setArtist(stars, artistId: row.id, skipsPlaying: skipsPlaying)
    }
  }

  /// Skips live in this iPhone's journal only, so the toast says so.
  private func forget(_ skip: TasteSummary.Skip) {
    let rows = PlaybackJournal.shared.forgetSkips(songId: skip.songId)
    guard !rows.isEmpty else { return app.show("Could not undo the skip") }
    summary?.skips.removeAll { $0.id == skip.id }
    app.show("Skip undone on this iPhone · \(skip.title)") {
      PlaybackJournal.shared.restoreSkips(rows)
      Task { await reload() }
    }
  }
}

/// A Top row: rank, artist and plays; it opens the artist when the library
/// knows it.
private struct TopRow: View {
  let rank: Int
  let artist: TasteSummary.TopArtist

  @Environment(\.palette) private var palette

  var body: some View {
    if let known = artist.artist {
      NavigationLink(value: Route.artist(known)) { row }.buttonStyle(.plain)
    } else {
      row
    }
  }

  private var row: some View {
    HStack(spacing: 12) {
      Text("\(rank)")
        .font(.rowSubtitle.weight(.semibold).monospacedDigit())
        .foregroundStyle(palette.secondary)
        .frame(minWidth: 20)
      Text(artist.name).font(.rowTitle).lineLimit(1)
      Spacer(minLength: 0)
      Text(counted(artist.plays, "play"))
        .font(.rowSubtitle.monospacedDigit())
        .foregroundStyle(palette.secondary)
    }
    .frame(minHeight: 56)
    .contentShape(Rectangle())
  }
}

/// The Profile segment: the recipe, the sound of the last 60 days and the
/// counts that open the other segments.
private struct TasteProfile: View {
  let summary: TasteSummary
  let likedCount: Int
  let openLiked: () -> Void
  let open: (TasteSegment) -> Void

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 12) {
      RecipeCard(recipe: summary.recipe, size: summary.recipeSize).tourAnchor(.taste)
      soundCard
      VarietyCard()
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 2), spacing: 12
      ) {
        StatTile(value: likedCount, label: "Liked", color: .floLiked, action: openLiked)
        StatTile(value: summary.boosted.count, label: "Boosted", color: .floWarning) {
          open(.boosted)
        }
        StatTile(value: summary.avoided.count, label: "Avoided", color: .floDestructive) {
          open(.avoided)
        }
        // Skips make a song less likely for a while; nothing is held back.
        StatTile(value: summary.skips.count, label: "Skipped lately", color: palette.secondary) {
          open(.skips)
        }
      }
    }
  }

  private var soundCard: some View {
    VStack(spacing: 10) {
      CardHeader(title: "Your sound", meta: "Last 60 days").padding(.horizontal, 2)
      let artists = Array(summary.top.prefix(5))
      if artists.isEmpty {
        Text("Your sound fills in as you listen.")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 2)
      } else {
        Treemap(artists: artists)
          .frame(maxWidth: 338)
          .frame(height: 220)
      }
    }
    .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 16))
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }
}

/// A card's title with its meta on the right: muted, or a chosen value in
/// the accent.
private struct CardHeader: View {
  let title: String
  let meta: String
  var isValue = false

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title).font(.sectionTitle)
      Spacer(minLength: 0)
      Text(meta)
        .font(isValue ? .meta.weight(.semibold) : .meta)
        .foregroundStyle(isValue ? palette.accent : palette.secondary)
    }
  }
}

extension MixRanker.Variety {
  fileprivate var title: String { rawValue.capitalized }

  /// What it changes, after `MixRanker.Config(variety:)`.
  fileprivate var detail: String {
    switch self {
    case .familiar: "A heard song rests about a day; fewer picks explore."
    case .balanced: "A heard song rests about 3 days; a sixth of a mix explores."
    case .adventurous: "A heard song rests about a week; a third of a mix explores."
    }
  }
}

/// How far Play Something reaches past the favourites, on a slider with a
/// stop per variety. A watch that follows the phone takes it along.
private struct VarietyCard: View {
  @AppStorage(UserDefaultsKeys.mixVariety) private var variety = MixRanker.Variety.balanced

  @Environment(\.palette) private var palette

  private static let stops = MixRanker.Variety.allCases
  private static let knob: CGFloat = 28

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      CardHeader(title: "Mix variety", meta: variety.title, isValue: true)
      VStack(spacing: 6) {
        slider
        labels
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Mix variety")
      .accessibilityValue(variety.title)
      .accessibilityAdjustableAction { direction in
        switch direction {
        case .increment: step(1)
        case .decrement: step(-1)
        @unknown default: break
        }
      }
      Text(variety.detail)
        .font(.meta)
        .foregroundStyle(palette.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(EdgeInsets(top: 18, leading: 16, bottom: 16, trailing: 16))
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    .sensoryFeedback(.selection, trigger: variety)
    .onChange(of: variety) { WatchLink.shared.updateWatch() }
  }

  private var index: Int { Self.stops.firstIndex(of: variety) ?? 1 }

  /// The track with the chosen part filled, a dot at each stop still ahead
  /// and the knob; a tap or a drag snaps to the nearest stop.
  private var slider: some View {
    GeometryReader { proxy in
      let inset = Self.knob / 2
      let room = proxy.size.width - Self.knob
      let x = inset + room * CGFloat(index) / CGFloat(Self.stops.count - 1)
      ZStack(alignment: .leading) {
        Capsule().fill(palette.surface2).frame(height: 6).padding(.horizontal, inset - 3)
        Capsule().fill(palette.accent).frame(width: x - inset + 6, height: 6)
          .offset(x: inset - 3)
        ForEach(Self.stops.indices.filter { $0 > index }, id: \.self) { stop in
          Circle()
            .fill(palette.secondary.opacity(0.6))
            .frame(width: 6, height: 6)
            .offset(x: inset - 3 + room * CGFloat(stop) / CGFloat(Self.stops.count - 1))
        }
        Circle()
          .fill(.white)
          .frame(width: Self.knob, height: Self.knob)
          .shadow(color: .black.opacity(0.3), radius: 3, y: 2)
          .offset(x: x - inset)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
      .contentShape(Rectangle())
      .gesture(
        DragGesture(minimumDistance: 0).onChanged { drag in
          let position = (drag.location.x - inset) / room * CGFloat(Self.stops.count - 1)
          let stop = min(max(Int(position.rounded()), 0), Self.stops.count - 1)
          select(Self.stops[stop])
        }
      )
    }
    .frame(height: Self.knob + 8)
  }

  private var labels: some View {
    HStack {
      ForEach(Self.stops, id: \.self) { stop in
        let isOn = stop == variety
        Button(stop.title) { select(stop) }
          .buttonStyle(.plain)
          .font(isOn ? .meta.weight(.semibold) : .meta)
          .foregroundStyle(isOn ? palette.text : palette.secondary)
          .frame(
            maxWidth: .infinity,
            alignment: stop == Self.stops.first
              ? .leading : stop == Self.stops.last ? .trailing : .center)
      }
    }
  }

  private func step(_ offset: Int) {
    let stop = min(max(index + offset, 0), Self.stops.count - 1)
    select(Self.stops[stop])
  }

  private func select(_ stop: MixRanker.Variety) {
    guard stop != variety else { return }
    withAnimation(.snappy(duration: 0.25)) { variety = stop }
  }
}

/// The latest mix's picks per kind as a stacked bar with a legend.
private struct RecipeCard: View {
  let recipe: [MixReason.Kind: Int]?
  let size: Int

  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var scheme

  /// The shares in the counters' mono face, a size up from `.counter`.
  private static let shareFont = Font.custom(
    "JetBrainsMono-Medium", size: 13, relativeTo: .footnote)

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      CardHeader(
        title: "Smart Mix recipe", meta: recipe == nil ? "" : "Last mix · \(counted(size, "song"))")
      if let recipe, size > 0 {
        bar(recipe)
        LazyVGrid(
          columns: Array(repeating: GridItem(.flexible(), spacing: 18), count: 2), spacing: 10
        ) {
          ForEach(MixReason.Kind.allCases, id: \.self) { kind in
            HStack(spacing: 8) {
              Circle().fill(kind.color(scheme)).frame(width: 8, height: 8)
              Text(label(kind)).font(.rowSubtitle).lineLimit(1)
              Spacer(minLength: 0)
              Text("\(Int((Double(recipe[kind] ?? 0) / Double(size) * 100).rounded()))%")
                .font(Self.shareFont)
                .foregroundStyle(palette.secondary)
            }
          }
        }
      } else {
        Text("Play Something to see what goes into a mix.")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
  }

  /// One segment per kind in the mix, as wide as its share.
  private func bar(_ recipe: [MixReason.Kind: Int]) -> some View {
    let parts = MixReason.Kind.allCases.compactMap { kind in
      recipe[kind].flatMap { $0 > 0 ? (kind, $0) : nil }
    }
    return GeometryReader { proxy in
      let room = proxy.size.width - 3 * CGFloat(parts.count - 1)
      HStack(spacing: 3) {
        ForEach(parts, id: \.0) { kind, count in
          Capsule()
            .fill(kind.color(scheme))
            .frame(width: room * CGFloat(count) / CGFloat(size))
        }
      }
    }
    .frame(height: 10)
  }

  private func label(_ kind: MixReason.Kind) -> String {
    switch kind {
    // The design's "Often played" would claim too much of picks that only
    // fit the listening.
    case .history: "Your plays"
    case .liked: "Liked"
    case .rated: "Rated high"
    case .explore: "Explore"
    }
  }
}

/// The top artists as tiles sized by plays: each takes its share of the
/// room left, cut alternately across and down. Shares follow the square
/// root of the plays, since listening leans on one artist and plain shares
/// would leave the others too thin to read.
private struct Treemap: View {
  let artists: [TasteSummary.TopArtist]

  private static let gap: CGFloat = 4

  var body: some View {
    GeometryReader { proxy in
      let weights = artists.map { Double($0.plays).squareRoot() }
      let frames = Self.layout(weights, in: CGRect(origin: .zero, size: proxy.size))
      ForEach(Array(zip(artists, frames).enumerated()), id: \.element.0.id) { rank, tile in
        let (artist, frame) = tile
        TreemapTile(artist: artist, rank: rank, size: frame.size)
          .frame(width: frame.width, height: frame.height)
          .offset(x: frame.minX, y: frame.minY)
      }
    }
  }

  private static func layout(_ weights: [Double], in rect: CGRect) -> [CGRect] {
    var rest = rect
    var left = weights.reduce(0, +)
    return weights.indices.map { index in
      guard index < weights.count - 1, left > 0 else { return rest }
      let share = weights[index] / left
      left -= weights[index]
      let edge: CGRectEdge = index.isMultiple(of: 2) ? .minXEdge : .minYEdge
      let length = ((edge == .minXEdge ? rest.width : rest.height) - gap) * share
      let (tile, remainder) = rest.divided(atDistance: length, from: edge)
      rest = remainder.divided(atDistance: gap, from: edge).remainder
      return tile
    }
  }
}

/// One artist of Your sound on a quiet wash of the accent, stronger for the
/// more played.
private struct TreemapTile: View {
  let artist: TasteSummary.TopArtist
  let rank: Int
  let size: CGSize

  @Environment(\.palette) private var palette

  /// The accent's share in each tile, by rank, as in the design.
  private static let washes = [0.34, 0.22, 0.16, 0.12, 0.08]

  var body: some View {
    if let known = artist.artist {
      NavigationLink(value: Route.artist(known)) { tile }.buttonStyle(.plain)
    } else {
      tile
    }
  }

  private var tile: some View {
    let tiny = size.height < 50
    let wash = Self.washes[min(rank, Self.washes.count - 1)]
    return VStack(alignment: .leading, spacing: 3) {
      Text(artist.name)
        .font(nameFont(tiny: tiny))
        .lineLimit(tiny ? 1 : 2)
      if !tiny {
        Text(counted(artist.plays, "play"))
          .font(.caption.monospacedDigit())
          .foregroundStyle(palette.secondary)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    .padding(
      tiny
        ? EdgeInsets(top: 0, leading: 8, bottom: 9, trailing: 8)
        : EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
    )
    .background(
      palette.surface.mix(with: palette.accent, by: wash),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  /// The brand face, smaller as the tile gets smaller.
  private func nameFont(tiny: Bool) -> Font {
    size.width >= 130
      ? .familjen(17, relativeTo: .body)
      : tiny ? .familjen(13, relativeTo: .caption) : .familjen(14, relativeTo: .footnote)
  }
}

/// A count with its colour bar; a tap opens the list behind it.
private struct StatTile: View {
  let value: Int
  let label: String
  let color: Color
  let action: () -> Void

  @Environment(\.palette) private var palette

  var body: some View {
    Button(action: action) {
      VStack(alignment: .leading, spacing: 8) {
        RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 20, height: 4)
        Text("\(value)").font(.pageTitle.monospacedDigit())
        Text(label).font(.rowSubtitle).foregroundStyle(palette.secondary).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(16)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
