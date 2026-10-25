//
//  FloComponents.swift
//  Ownwave Watch App
//

import SwiftUI

/// The app's name, "Own" in the text color and "wave" in light lilac, on
/// Home and the login screen.
struct Wordmark: View {
  var body: some View {
    (Text("Own").foregroundStyle(Color.floText) + Text("wave").foregroundStyle(Color.floWave))
      .font(.floWordmark)
      // 0.035 em tighter at 18 pt, as in the design.
      .tracking(-0.035 * 18)
  }
}

/// A row's small cover, or a lilac glyph standing in for one.
enum CoverTile {
  /// The album's cover, read from its download when there is one; `artId`
  /// for a cover of its own, such as a playlist's mosaic.
  case cover(albumId: String, artId: String? = nil)
  /// A lilac glyph, round for an artist or a station.
  case glyph(String, round: Bool = false)

  /// A station's glyph, also on Artist Radio.
  static let radioGlyph = "dot.radiowaves.up.forward"
  /// The round glyph standing in for an artist's picture.
  static let artist = glyph("music.mic", round: true)
  static let radio = glyph(radioGlyph, round: true)

  /// The cover or glyph of a menu's item.
  init(_ target: MenuTarget) {
    switch target {
    case .song(let song, _, _): self = .cover(albumId: song.albumId)
    case .album(let album): self = .cover(albumId: album.id)
    case .artist: self = .artist
    case .playlist(let playlist): self = .cover(albumId: playlist.id, artId: playlist.artId)
    case .radio: self = .radio
    }
  }

  @ViewBuilder
  func view(size: CGFloat) -> some View {
    switch self {
    case .cover(let albumId, let artId):
      WatchAlbumArtView(albumId: albumId, artId: artId, size: size)
        .clipShape(RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius, style: .continuous))
    case .glyph(let systemImage, let round):
      Image(systemName: systemImage)
        .font(.system(size: 16))
        .foregroundStyle(Color.floLilac)
        .frame(width: size, height: size)
        .background(
          (round
            ? AnyShape(Circle())
            : AnyShape(
              RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius, style: .continuous)))
            .fill(Color.floTile))
    }
  }
}

/// A row with a small cover or glyph tile, two lines and an optional
/// trailing mark.
struct CoverRow<Trailing: View>: View {
  let tile: CoverTile
  let title: String
  let subtitle: String
  /// Nil: two lines without a subtitle, else one.
  var titleLineLimit: Int? = nil
  var tileSize = FloLayout.thumbnail
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: FloLayout.tileSpacing) {
      tile.view(size: tileSize)
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.floRowTitle)
          // Without a subtitle there is room for a long name.
          .lineLimit(titleLineLimit ?? (subtitle.isEmpty ? 2 : 1))
        if !subtitle.isEmpty {
          Text(subtitle)
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
            .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
      trailing
    }
    .frame(minHeight: FloLayout.coverRowHeight(tile: tileSize))
  }
}

extension CoverRow where Trailing == EmptyView {
  init(
    tile: CoverTile, title: String, subtitle: String, titleLineLimit: Int? = nil,
    tileSize: CGFloat = FloLayout.thumbnail
  ) {
    self.init(
      tile: tile, title: title, subtitle: subtitle, titleLineLimit: titleLineLimit,
      tileSize: tileSize
    ) {
      EmptyView()
    }
  }
}

/// A mono small caps label: "NOW PLAYING" on Home's card, "NEXT · 14 SONGS"
/// over Up Next, the sign-in field labels.
struct CapsLabel: View {
  let text: String
  var tint: Color = .floSecondary

  init(_ text: String, tint: Color = .floSecondary) {
    self.text = text
    self.tint = tint
  }

  var body: some View {
    Text(text.uppercased())
      .font(.floCaps)
      .tracking(1)
      .foregroundStyle(tint)
      .lineLimit(1)
  }
}

/// The trailing mark of a row that opens a screen.
struct Chevron: View {
  var body: some View {
    Image(systemName: "chevron.right")
      .font(.system(size: 12, weight: .semibold))
      .foregroundStyle(Color.floSecondary)
  }
}

/// A row's title after its icon, with an optional detail under it:
/// Settings, the hold menu's list, the download control.
struct IconRowLabel: View {
  let title: String
  var detail = ""
  var systemImage: String?
  var tint: Color = .floLilac
  var label: Color = .floText

  private static let iconWidth: CGFloat = 22
  private static let spacing: CGFloat = 8
  /// Where the title starts after an icon, for hairlines and values under
  /// it.
  static let titleInset = iconWidth + spacing

  var body: some View {
    HStack(spacing: Self.spacing) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 17))
          .foregroundStyle(tint)
          .frame(width: Self.iconWidth)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.floRow)
          .foregroundStyle(label)
        if !detail.isEmpty {
          Text(detail)
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
        }
      }
    }
  }
}

/// A small dot in a status color: a live stream, a reachable server, a
/// legend's key.
struct StatusDot: View {
  let color: Color

  var body: some View {
    Circle().fill(color).frame(width: 6, height: 6)
  }
}

/// The title above a list section.
struct FloSectionHeader: View {
  let title: String

  init(_ title: String) {
    self.title = title
  }

  var body: some View {
    Text(title)
      .font(.floSection)
      .foregroundStyle(Color.floSecondary)
      .textCase(nil)
  }
}

/// Shown on Home and in Settings while Core Data runs in memory only.
struct StorageWarningRow: View {
  var body: some View {
    Label(
      "Storage unavailable: history, downloads and queued scrobbles are not saved until the app restarts.",
      systemImage: "exclamationmark.triangle"
    )
    .font(.floMeta)
    .foregroundStyle(Color.floWarningText)
    .padding(.vertical, 8)
    .floJoinedRow(.alone)
  }
}

/// A label over its value: settings and diagnostics.
struct FloInfoRow: View {
  let label: String
  let value: String

  init(_ label: String, _ value: String) {
    self.label = label
    self.value = value
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.floMeta)
        .foregroundStyle(Color.floSecondary)
      Text(value)
        .font(.floMeta.weight(.medium))
    }
    .padding(.vertical, 2)
  }
}

/// One state vocabulary for rows and headers.
struct Badge: View {
  enum Kind {
    case live, offline
  }

  let kind: Kind

  var body: some View {
    HStack(spacing: 4) {
      switch kind {
      case .live:
        StatusDot(color: .floLiked)
        Text("LIVE").fontWeight(.bold).tracking(0.4)
      case .offline:
        Image(systemName: "wifi.slash").font(.system(size: 10, weight: .semibold))
        Text("Offline")
      }
    }
    .font(.floCaption)
    .foregroundStyle(foreground)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(background))
  }

  private var foreground: Color {
    switch kind {
    case .live: .floDestructive
    case .offline: .floWarningText
    }
  }

  private var background: Color {
    switch kind {
    case .live: .floLiked.opacity(0.22)
    case .offline: .floWarning.opacity(0.22)
    }
  }
}

/// What a whole list shows while it has nothing to list.
struct StateView: View {
  enum Kind {
    case loading
    case empty(systemImage: String, tint: Color, title: String, message: String)
    case error(retry: () -> Void)
  }

  let kind: Kind

  var body: some View {
    switch kind {
    case .loading:
      VStack(spacing: 5) {
        ForEach(0..<3, id: \.self) { index in
          skeletonRow.opacity([1, 0.7, 0.45][index])
        }
      }
    case .empty(let systemImage, let tint, let title, let message):
      messageView(
        systemImage: systemImage, tint: tint, circle: .floSurface, title: title, text: message)
    case .error(let retry):
      VStack(spacing: 6) {
        messageView(
          systemImage: "icloud.slash", tint: .floWarning, circle: .floWarning.opacity(0.18),
          title: "Can't reach server", text: "Downloads still play offline.")
        Button("Try Again", action: retry)
          .buttonStyle(FloTintedButtonStyle(height: 40))
          .padding(.top, 6)
      }
    }
  }

  private func messageView(
    systemImage: String, tint: Color, circle: Color, title: String, text: String
  ) -> some View {
    VStack(spacing: 6) {
      Image(systemName: systemImage)
        .font(.system(size: 24))
        .foregroundStyle(tint)
        .frame(width: 52, height: 52)
        .background(Circle().fill(circle))
        .padding(.bottom, 4)
      Text(title)
        .font(.floSong)
        .multilineTextAlignment(.center)
      Text(text)
        .font(.floMeta)
        .foregroundStyle(Color.floSecondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
  }

  private var skeletonRow: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius).fill(Color.floSkeleton)
        .frame(width: FloLayout.thumbnail, height: FloLayout.thumbnail)
      VStack(alignment: .leading, spacing: 6) {
        Capsule().fill(Color.floSkeleton).frame(height: 9).frame(maxWidth: 110)
        Capsule().fill(Color.floSkeleton.opacity(0.8)).frame(height: 8).frame(maxWidth: 70)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(minHeight: FloLayout.coverRowHeight)
    .background(
      RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous).fill(Color.floSurface)
    )
  }
}

/// Picks one of a few values on a screen of its own, since the watch has no
/// menus; picking one returns.
struct ChoiceList<Value: Hashable>: View {
  let title: String
  let options: [(Value, String)]
  @Binding var selection: Value
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      ForEach(Array(options.enumerated()), id: \.element.0) { index, option in
        let (value, label) = option
        Button {
          selection = value
          dismiss()
        } label: {
          HStack {
            Text(label).font(.floRow)
            Spacer(minLength: 4)
            if value == selection {
              Image(systemName: "checkmark").foregroundStyle(Color.floLilac)
            }
          }
          .frame(minHeight: FloLayout.rowHeight)
        }
        .accessibilityAddTraits(value == selection ? .isSelected : [])
        .floJoinedRow(
          RowPosition(index: index, count: options.count),
          hairlineInset: FloLayout.joinedRowInsets.leading)
      }
    }
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 1)
    .floNavigationTitle(title)
  }
}
