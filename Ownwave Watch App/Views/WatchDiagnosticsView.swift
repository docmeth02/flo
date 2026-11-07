//
//  WatchDiagnosticsView.swift
//  Ownwave Watch App
//

import SwiftUI

/// Connection state, the history import, the latest mix and server requests,
/// to tell a slow or broken server from an app problem on the device itself.
/// Shows no secrets, and neither does the shared log.
struct WatchDiagnosticsView: View {
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @ObservedObject private var log = RequestLog.shared
  @ObservedObject private var history = HistoryStatus.shared
  @ObservedObject private var ratings = RatingStore.shared
  @ObservedObject private var recommendations = RecommendationLog.shared

  var body: some View {
    List {
      Section {
        ShareLink(item: DiagnosticsReport.text(), subject: Text("Ownwave log")) {
          Label("Share log", systemImage: "square.and.arrow.up")
            .font(.row)
            .foregroundStyle(Dusk.fill)
            .frame(minHeight: FloLayout.rowHeight)
        }
        .joined(.alone)
      }

      Section {
        rows(DiagnosticsReport.connectionLines())
      }

      Section {
        rows(DiagnosticsReport.historyLines(history.state))
      } header: {
        FloSectionHeader("History")
      }

      Section {
        if let mix = recommendations.mixes.first {
          // The summary first, then one row per pick.
          let count = mix.picks.count + 1
          Text(DiagnosticsReport.summary(of: mix))
            .font(.meta)
            .padding(.vertical, 2)
            .joined(RowPosition(index: 0, count: count))
          ForEach(Array(mix.picks.enumerated()), id: \.offset) { index, pick in
            FloInfoRow("\(pick.slot) · \(pick.reason)", "\(pick.title) — \(pick.artist)")
              .joined(RowPosition(index: index + 1, count: count))
          }
        } else {
          Text("No mix yet")
            .font(.meta)
            .foregroundStyle(Dusk.secondary)
            .padding(.vertical, 2)
            .joined(.alone)
        }
      } header: {
        FloSectionHeader("Last mix")
      }

      Section {
        let entries = log.entries
        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
              .font(.caption2)
              .foregroundStyle(Dusk.secondary)
              .lineLimit(2)
            Text(DiagnosticsReport.details(of: entry))
              .font(.meta)
              .foregroundStyle(entry.isFailure ? Color.destructive : .white)
              .lineLimit(2)
          }
          .padding(.vertical, 2)
          .joined(RowPosition(index: index, count: entries.count))
        }
      } header: {
        FloSectionHeader("Requests")
      }
    }
    // Joined rows, as in Settings: plain, and as low as their content (at 0
    // watchOS skips a section's first or last row).
    .listStyle(.plain)
    .environment(\.defaultMinListRowHeight, 1)
    .floNavigationTitle("Diagnostics")
    .task { await ListeningHistoryStore.shared.publishStoredState() }
  }

  private func rows(_ lines: [(String, String)]) -> some View {
    ForEach(Array(lines.enumerated()), id: \.element.0) { index, line in
      FloInfoRow(line.0, line.1).joined(RowPosition(index: index, count: lines.count))
    }
  }
}

extension View {
  /// A row joined on its section's platter, its hairline from the text.
  fileprivate func joined(_ position: RowPosition) -> some View {
    floJoinedRow(position, hairlineInset: FloLayout.joinedRowInsets.leading)
  }
}
