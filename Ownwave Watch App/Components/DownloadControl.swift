//
//  DownloadControl.swift
//  Ownwave Watch App
//

import SwiftUI

/// Download, progress, missing songs and removal of an album or playlist.
struct DownloadControl: View {
  enum State: Equatable {
    case none
    case downloading(percent: Int)
    /// Sent by the iPhone, which alone can stop it, so it has no Cancel.
    case receiving(percent: Int)
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
        row("Download", systemImage: "arrow.down.circle", tint: .floLilac, action: onDownload)
      case .downloading(let percent), .receiving(let percent):
        VStack(spacing: 6) {
          HStack(alignment: .firstTextBaseline) {
            Text("Downloading").font(.floRow)
            Spacer()
            Text("\(percent)%")
              .font(.system(.footnote, weight: .semibold).monospacedDigit())
              .foregroundStyle(Color.floLilac)
          }
          ProgressView(value: Double(percent), total: 100)
            .tint(.floLilac)
          if case .downloading = state {
            Button("Cancel", action: onCancel)
              .buttonStyle(
                FloTintedButtonStyle(tint: .floDestructive, height: 36))
          }
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
          "Download \(missing) missing", systemImage: "arrow.down.circle", tint: .floLilac,
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
          .fill(Color.floSurface)
      )
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
