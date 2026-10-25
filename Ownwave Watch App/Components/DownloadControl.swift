//
//  DownloadControl.swift
//  Ownwave Watch App
//

import SwiftUI

/// Download, progress, missing songs, a failed download and removal of an
/// album or playlist.
struct DownloadControl: View {
  enum State: Equatable {
    case none
    case downloading(percent: Int)
    /// Sent by the iPhone, which alone can stop it, so it has no Cancel.
    case receiving(percent: Int)
    case partial(missing: Int)
    /// Songs the server would not deliver after their retries; Download
    /// queues them again.
    case failed
    case done
  }

  let state: State
  var onDownload: () -> Void
  var onCancel: () -> Void
  var onRemove: () -> Void

  private var remove: PlatterRows.Row {
    PlatterRows.Row(
      title: "Remove Download", systemImage: "trash", tint: .floDestructive,
      label: .floDestructive, action: onRemove)
  }

  var body: some View {
    switch state {
    case .none:
      PlatterRows([
        PlatterRows.Row(title: "Download", systemImage: "arrow.down.circle", action: onDownload)
      ])
    case .downloading(let percent), .receiving(let percent):
      VStack(spacing: 6) {
        HStack(alignment: .firstTextBaseline) {
          Text("Downloading").font(.floRow)
          Spacer()
          Text("\(percent)%")
            .font(.counter)
            .foregroundStyle(Color.floLilac)
        }
        ProgressView(value: Double(percent), total: 100)
          .tint(.floLilac)
        if case .downloading = state {
          Button("Cancel", action: onCancel)
            .buttonStyle(
              FloTintedButtonStyle(tint: .floDestructive, platter: .floSurface2, height: 36))
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 9)
      .background(
        RoundedRectangle(cornerRadius: FloLayout.platterRadius, style: .continuous)
          .fill(Color.floSurface))
    case .partial(let missing):
      PlatterRows([
        PlatterRows.Row(
          title: "\(counted(missing, "song")) missing", systemImage: "exclamationmark.circle.fill",
          tint: .floWarning, label: .floWarningText),
        PlatterRows.Row(
          title: "Download Missing", systemImage: "arrow.down.circle", action: onDownload),
        remove,
      ])
    case .failed:
      PlatterRows([
        PlatterRows.Row(
          title: "Download failed", detail: "Try again", systemImage: "xmark.circle.fill",
          tint: .floDestructive, action: onDownload),
        remove,
      ])
    case .done:
      PlatterRows([
        PlatterRows.Row(
          title: "Downloaded", systemImage: "checkmark.circle.fill", tint: .floDownloaded,
          label: .floDownloadedText),
        remove,
      ])
    }
  }
}
