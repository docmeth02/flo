//
//  OwnwaveWidgets.swift
//  OwnwaveWidgets
//

import SwiftUI
import WidgetKit

@main
struct OwnwaveWidgets: WidgetBundle {
  var body: some Widget {
    LauncherWidget()
  }
}

struct SnapshotEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot
}

/// Every widget reads the snapshot the app wrote; the app reloads them.
struct SnapshotProvider: TimelineProvider {
  func placeholder(in context: Context) -> SnapshotEntry {
    SnapshotEntry(date: .now, snapshot: WidgetSnapshot())
  }

  func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
    completion(SnapshotEntry(date: .now, snapshot: .load()))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
    completion(Timeline(entries: [SnapshotEntry(date: .now, snapshot: .load())], policy: .never))
  }
}

struct LauncherWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetSnapshot.Kind.launcher, provider: SnapshotProvider()) { _ in
      Text("Ownwave").containerBackground(.black, for: .widget)
    }
    .configurationDisplayName("Ownwave")
    .supportedFamilies([.systemSmall])
  }
}
