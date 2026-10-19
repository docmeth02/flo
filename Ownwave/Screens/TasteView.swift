//
//  TasteView.swift
//  Ownwave
//

import SwiftUI

/// The Taste tab's parts, one segment each.
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
    HStack(spacing: 2) {
      ForEach(TasteSegment.allCases) { item in
        let selected = item == segment
        Button {
          segment = item
        } label: {
          Text(item.title)
            .font(.meta.weight(.semibold))
            .foregroundStyle(selected ? palette.text : palette.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
              selected ? palette.surface2 : .clear,
              in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
      }
    }
    .padding(3)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  @ViewBuilder private func content(_ summary: TasteSummary) -> some View {
    switch segment {
    case .profile:
      TasteProfile(
        summary: summary,
        likedCount: albumViewModel.starredSongs.filter { player.isStarred($0) }.count,
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
      rate(row, stars)
      Task { await reload() }
    }
  }

  private func rate(_ row: TasteSummary.Rated, _ stars: Int) {
    switch row.kind {
    case .song: RatingStore.shared.set(stars, playbackID: row.id)
    case .artist: RatingStore.shared.setArtist(stars, artistId: row.id)
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

/// A card's title with its muted meta on the right.
private struct CardHeader: View {
  let title: String
  let meta: String

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Text(title).font(.sectionTitle)
      Spacer(minLength: 0)
      Text(meta).font(.meta).foregroundStyle(palette.secondary)
    }
  }
}

/// The latest mix's picks per kind as a stacked bar with a legend.
private struct RecipeCard: View {
  let recipe: [MixReason.Kind: Int]?
  let size: Int

  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var scheme

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
              Circle().fill(color(kind)).frame(width: 10, height: 10)
              Text(label(kind)).lineLimit(1)
              Spacer(minLength: 0)
              Text("\(Int((Double(recipe[kind] ?? 0) / Double(size) * 100).rounded()))%")
                .fontWeight(.semibold)
                .monospacedDigit()
            }
            .font(.rowSubtitle)
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
          RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color(kind))
            .frame(width: room * CGFloat(count) / CGFloat(size))
        }
      }
    }
    .frame(height: 14)
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

  /// The design's category hues, one lightness and chroma per scheme.
  private func color(_ kind: MixReason.Kind) -> Color {
    let degrees: Double =
      switch kind {
      case .history: 300
      case .liked: 15
      case .rated: 75
      case .explore: 190
      }
    let dark = scheme == .dark
    return CoverTint.color(
      hue: degrees * .pi / 180, lightness: dark ? 0.78 : 0.56, chroma: dark ? 0.12 : 0.15)
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
      ForEach(Array(zip(artists, frames)), id: \.0.id) { artist, frame in
        TreemapTile(artist: artist, size: frame.size)
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

/// One artist of Your sound, in the hue of its most-played album's cover.
private struct TreemapTile: View {
  let artist: TasteSummary.TopArtist
  let size: CGSize

  @Environment(\.palette) private var palette
  @Environment(\.colorScheme) private var scheme
  @State private var hue: Double?

  /// The lilac accent's OKLCH hue, for artists without a coloured cover.
  private static let accentHue = 300 * Double.pi / 180

  var body: some View {
    if let known = artist.artist {
      NavigationLink(value: Route.artist(known)) { tile }.buttonStyle(.plain)
    } else {
      tile
    }
  }

  private var tile: some View {
    let tiny = size.height < 50
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
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
    .background(gradient, in: shape)
    .overlay { shape.strokeBorder(palette.hairline, lineWidth: 1) }
    .contentShape(shape)
    .task(id: artist.albumId) { hue = await CoverTint.hue(albumId: artist.albumId) }
  }

  /// Bold, smaller as the tile gets smaller.
  private func nameFont(tiny: Bool) -> Font {
    let style: Font.TextStyle = size.width >= 130 ? .body : tiny ? .caption2 : .footnote
    return .system(style, weight: .bold)
  }

  /// The design's 160 degree gradient, top left to bottom right.
  private var gradient: LinearGradient {
    let hue = hue ?? Self.accentHue
    let colors =
      scheme == .dark
      ? [
        CoverTint.color(hue: hue, lightness: 0.44, chroma: 0.1),
        CoverTint.color(hue: hue, lightness: 0.26, chroma: 0.06),
      ]
      : [
        CoverTint.color(hue: hue, lightness: 0.94, chroma: 0.045),
        CoverTint.color(hue: hue, lightness: 0.83, chroma: 0.08),
      ]
    return LinearGradient(
      colors: colors, startPoint: UnitPoint(x: 0.33, y: 0.03), endPoint: UnitPoint(x: 0.67, y: 0.97)
    )
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
