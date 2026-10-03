//
//  FloComponents.swift
//  flo Watch App
//

import SwiftUI

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
    .frame(minHeight: 44)
  }
}

/// A row with a small cover, two lines and an optional trailing mark.
struct CoverRow<Trailing: View>: View {
  let coverURL: String
  let albumId: String
  let title: String
  let subtitle: String
  @ViewBuilder var trailing: Trailing

  var body: some View {
    HStack(spacing: 10) {
      WatchAlbumArtView(url: coverURL, size: 36, albumId: albumId)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
          .font(.floRowTitle)
          .lineLimit(1)
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
    .frame(minHeight: 52)
  }
}

extension CoverRow where Trailing == EmptyView {
  init(coverURL: String, albumId: String, title: String, subtitle: String) {
    self.init(coverURL: coverURL, albumId: albumId, title: title, subtitle: subtitle) {
      EmptyView()
    }
  }
}

/// One state vocabulary for rows and headers.
struct Badge: View {
  enum Kind {
    case live, offline, downloaded, boosted, avoided
    case progress(Int)
  }

  let kind: Kind

  var body: some View {
    HStack(spacing: 4) {
      switch kind {
      case .live:
        Circle().fill(Color.floLiked).frame(width: 6, height: 6)
        Text("LIVE").font(.system(size: 11, weight: .bold)).tracking(0.4)
      case .offline:
        Image(systemName: "wifi.slash").font(.system(size: 10, weight: .semibold))
        Text("Offline")
      case .downloaded:
        Image(systemName: "checkmark.circle.fill").font(.system(size: 11))
        Text("Downloaded")
      case .boosted:
        Image(systemName: "sparkle").font(.system(size: 10, weight: .bold))
        Text("Boosted")
      case .avoided:
        Image(systemName: "hand.thumbsdown.fill").font(.system(size: 10))
        Text("Avoided")
      case .progress(let percent):
        Image(systemName: "arrow.down.circle").font(.system(size: 11))
        Text("\(percent)%").monospacedDigit()
      }
    }
    .font(.system(size: 11, weight: .semibold))
    .foregroundStyle(foreground)
    .padding(.horizontal, 8)
    .padding(.vertical, 3)
    .background(Capsule().fill(background))
  }

  private var foreground: Color {
    switch kind {
    case .live: .floDestructive
    case .offline: .floWarningText
    case .downloaded: .floDownloadedText
    case .boosted, .progress: .floLavender
    case .avoided: .floSecondary
    }
  }

  private var background: Color {
    switch kind {
    case .live: .floLiked.opacity(0.22)
    case .offline: .floWarning.opacity(0.22)
    case .downloaded: .floDownloaded.opacity(0.18)
    case .boosted, .progress: .floLavender.opacity(0.2)
    case .avoided: .white.opacity(0.12)
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
      RoundedRectangle(cornerRadius: 6).fill(Color.floSkeleton).frame(width: 36, height: 36)
      VStack(alignment: .leading, spacing: 6) {
        Capsule().fill(Color.floSkeleton).frame(height: 9).frame(maxWidth: 110)
        Capsule().fill(Color.floSkeleton.opacity(0.8)).frame(height: 8).frame(maxWidth: 70)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
    .frame(minHeight: 52)
    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.floSurface))
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
            Text("Downloading").font(.system(size: 14, weight: .medium))
            Spacer()
            Text("\(percent)%")
              .font(.system(size: 13, weight: .semibold).monospacedDigit())
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
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.floSurface))
      case .partial(let missing):
        status(
          "\(missing) song\(missing == 1 ? "" : "s") missing", systemImage: "exclamationmark.circle.fill",
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
      Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(text)
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
      .frame(minHeight: 44)
      .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.floSurface))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
