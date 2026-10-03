//
//  FloComponents.swift
//  flo Watch App
//

import SwiftUI

/// "1 song", "3 songs".
func counted(_ count: Int, _ noun: String) -> String {
  "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// A navigation row on the home screen: tinted glyph and a label.
struct FloNavRow: View {
  let title: String
  let systemImage: String
  var tint: Color = .floLavender

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: systemImage)
        .font(.system(size: 18))
        .foregroundStyle(tint)
        .frame(width: 22)
      Text(title)
        .font(.floRow)
        .lineLimit(1)
    }
    .frame(minHeight: FloLayout.rowHeight)
  }
}

/// A row with a small cover or glyph tile, two lines and an optional
/// trailing mark.
struct CoverRow<Trailing: View>: View {
  enum Tile {
    case cover(url: String, albumId: String)
    /// A lavender glyph, round for an artist or a station.
    case glyph(String, round: Bool = false)
  }

  let tile: Tile
  let title: String
  let subtitle: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 10) {
      tileView
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.floRowTitle)
          // Without a subtitle there is room for a long name.
          .lineLimit(subtitle.isEmpty ? 2 : 1)
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
    .frame(minHeight: FloLayout.coverRowHeight)
  }

  @ViewBuilder
  private var tileView: some View {
    switch tile {
    case .cover(let url, let albumId):
      WatchAlbumArtView(url: url, size: FloLayout.thumbnail, albumId: albumId)
        .clipShape(RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius, style: .continuous))
    case .glyph(let systemImage, let round):
      Image(systemName: systemImage)
        .font(.system(size: 16))
        .foregroundStyle(Color.floLavender)
        .frame(width: FloLayout.thumbnail, height: FloLayout.thumbnail)
        .background(
          (round
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius, style: .continuous)))
            .fill(Color.floTile))
    }
  }
}

extension CoverRow where Trailing == EmptyView {
  init(tile: Tile, title: String, subtitle: String) {
    self.init(tile: tile, title: title, subtitle: subtitle) {
      EmptyView()
    }
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
        Circle().fill(Color.floLiked).frame(width: 6, height: 6)
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
      RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous).fill(Color.floSurface))
  }
}

/// Download, progress, missing songs and removal of an album or playlist.
struct DownloadControl: View {
  enum State: Equatable {
    case none
    case downloading(percent: Int)
    case partial(missing: Int)
    case done
  }

  let state: State
  var onDownload: () -> Void
  var onCancel: () -> Void
  var onRemove: () -> Void

  var body: some View {
    VStack(spacing: 6) {
      switch state {
      case .none:
        row("Download", systemImage: "arrow.down.circle", tint: .floLavender, action: onDownload)
      case .downloading(let percent):
        VStack(spacing: 6) {
          HStack(alignment: .firstTextBaseline) {
            Text("Downloading").font(.floRow)
            Spacer()
            Text("\(percent)%")
              .font(.system(.footnote, weight: .semibold).monospacedDigit())
              .foregroundStyle(Color.floLavender)
          }
          ProgressView(value: Double(percent), total: 100)
            .tint(.floLavender)
          Button("Cancel", action: onCancel)
            .buttonStyle(
              FloTintedButtonStyle(tint: .floDestructive, height: 36))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
          RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous)
            .fill(Color.floSurface))
      case .partial(let missing):
        status(
          "\(counted(missing, "song")) missing", systemImage: "exclamationmark.circle.fill",
          tint: .floWarning, text: .floWarningText)
        row(
          "Download \(missing) missing", systemImage: "arrow.down.circle", tint: .floLavender,
          action: onDownload)
        row(
          "Remove Download", systemImage: "trash", tint: .floDestructive, label: .floDestructive,
          action: onRemove)
      case .done:
        status(
          "Downloaded", systemImage: "checkmark.circle.fill", tint: .floDownloaded,
          text: .floDownloadedText)
        row(
          "Remove Download", systemImage: "trash", tint: .floDestructive, label: .floDestructive,
          action: onRemove)
      }
    }
  }

  private func status(_ title: String, systemImage: String, tint: Color, text: Color) -> some View {
    HStack(spacing: 6) {
      Image(systemName: systemImage).font(.system(size: 14)).foregroundStyle(tint)
      Text(title).font(.floSection).foregroundStyle(text)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 6)
    .padding(.top, 4)
  }

  private func row(
    _ title: String, systemImage: String, tint: Color, label: Color = .white,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: systemImage).font(.system(size: 18)).foregroundStyle(tint)
        Text(title).font(.floRow).foregroundStyle(label)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .frame(minHeight: FloLayout.rowHeight)
      .background(
        RoundedRectangle(cornerRadius: FloLayout.rowRadius, style: .continuous)
          .fill(Color.floSurface))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
