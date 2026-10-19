//
//  OwnwaveWidgets.swift
//  OwnwaveWidgets
//

import AppIntents
import SwiftUI
import WidgetKit

@main
struct OwnwaveWidgets: WidgetBundle {
  var body: some Widget {
    PlaySomethingWidget()
    NowPlayingWidget()
    RecentlyPlayedWidget()
    LauncherWidget()
    PlaySomethingControl()
  }
}

struct SnapshotEntry: TimelineEntry {
  let date: Date
  let snapshot: WidgetSnapshot
}

/// Every widget reads the snapshot the app wrote; the app reloads them. The
/// widget gallery gets sample content, so it never asks to sign in.
struct SnapshotProvider: TimelineProvider {
  func placeholder(in context: Context) -> SnapshotEntry {
    SnapshotEntry(date: .now, snapshot: .sample)
  }

  func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
    completion(entry(context))
  }

  func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
    completion(Timeline(entries: [entry(context)], policy: .never))
  }

  private func entry(_ context: Context) -> SnapshotEntry {
    SnapshotEntry(date: .now, snapshot: context.isPreview ? .sample : .load())
  }
}

struct PlaySomethingWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetSnapshot.Kind.playSomething, provider: SnapshotProvider()) {
      PlaySomethingWidgetView(snapshot: $0.snapshot)
    }
    .configurationDisplayName("Play Something")
    .description("Starts a smart mix from your library.")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

struct NowPlayingWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetSnapshot.Kind.nowPlaying, provider: SnapshotProvider()) {
      NowPlayingEntryView(snapshot: $0.snapshot)
    }
    .configurationDisplayName("Now Playing")
    .description("The song playing in Ownwave.")
    .supportedFamilies([.systemSmall, .systemMedium])
    .contentMarginsDisabled()
  }
}

/// Hands the family to the view, which the app's gallery sets by hand.
private struct NowPlayingEntryView: View {
  let snapshot: WidgetSnapshot
  @Environment(\.widgetFamily) private var family

  var body: some View {
    NowPlayingWidgetView(snapshot: snapshot, family: family)
  }
}

struct RecentlyPlayedWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetSnapshot.Kind.recentlyPlayed, provider: SnapshotProvider()) {
      RecentlyPlayedWidgetView(snapshot: $0.snapshot)
    }
    .configurationDisplayName("Recently Played")
    .description("The albums you played last.")
    .supportedFamilies([.systemMedium])
    .contentMarginsDisabled()
  }
}

struct LauncherWidget: Widget {
  var body: some WidgetConfiguration {
    StaticConfiguration(kind: WidgetSnapshot.Kind.launcher, provider: SnapshotProvider()) { _ in
      LauncherWidgetView()
    }
    .configurationDisplayName("Ownwave")
    .description("Opens Ownwave.")
    .supportedFamilies([.systemSmall])
    .contentMarginsDisabled()
  }
}

/// Play Something in Control Center, on the Lock Screen or the Action button.
struct PlaySomethingControl: ControlWidget {
  var body: some ControlWidgetConfiguration {
    StaticControlConfiguration(kind: "PlaySomethingControl") {
      ControlWidgetButton(action: PlaySomethingNowIntent()) {
        Label("Play Something", systemImage: "sparkles")
      }
    }
    .displayName("Play Something")
    .description("Starts a smart mix from your library.")
  }
}
