//
//  WatchDiagnosticsView.swift
//  Ownwave Watch App
//

import SwiftUI
import WatchKit

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
        ShareLink(item: Self.exportText(), subject: Text("Ownwave log")) {
          Label("Share log", systemImage: "square.and.arrow.up")
            .font(.floRow)
            .foregroundStyle(Color.floLilac)
        }
        .floRow()
      }

      Section {
        ForEach(DiagnosticsReport.connectionLines(), id: \.0) { row($0.0, $0.1) }
      }

      Section {
        ForEach(DiagnosticsReport.historyLines(history.state), id: \.0) { row($0.0, $0.1) }
      } header: {
        FloSectionHeader("History")
      }

      Section {
        if let mix = recommendations.mixes.first {
          Text(DiagnosticsReport.summary(of: mix))
            .font(.floMeta)
            .floRow()
          ForEach(Array(mix.picks.enumerated()), id: \.offset) { _, pick in
            row("\(pick.slot) · \(pick.reason)", "\(pick.title) — \(pick.artist)")
          }
        } else {
          Text("No mix yet")
            .font(.floMeta)
            .foregroundStyle(Color.floSecondary)
            .floRow()
        }
      } header: {
        FloSectionHeader("Last mix")
      }

      Section {
        ForEach(log.entries) { entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.text)
              .font(.caption2)
              .foregroundStyle(Color.floSecondary)
              .lineLimit(2)
            Text(DiagnosticsReport.details(of: entry))
              .font(.floMeta)
              .foregroundStyle(entry.isFailure ? Color.floDestructive : .white)
              .lineLimit(2)
          }
          .floRow()
        }
      } header: {
        FloSectionHeader("Requests")
      }
    }
    .floNavigationTitle("Diagnostics")
    .task { await ListeningHistoryStore.shared.publishStoredState() }
  }

  /// The report as plain text, for Share log and the debug dump.
  static func exportText() -> String {
    let device = WKInterfaceDevice.current()
    return DiagnosticsReport.text(system: "\(device.systemName) \(device.systemVersion)")
  }

  private func row(_ title: String, _ value: String) -> some View {
    FloInfoRow(title, value).floRow()
  }
}
