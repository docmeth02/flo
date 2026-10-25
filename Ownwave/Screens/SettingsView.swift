//
//  SettingsView.swift
//  Ownwave
//

import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var flooo: FloooViewModel
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @Environment(\.palette) private var palette

  @AppStorage("appearance") private var appearance = Appearance.system
  @AppStorage("tourSeen") private var tourSeen = false
  // UserDefaultsManager's settings, with its defaults. The bitrates are
  // shown through `offered`, which reads a retired value as it does.
  @AppStorage(UserDefaultsKeys.keepPlaying)
  private var keepPlaying = UserDefaultsManager.keepPlaying
  @AppStorage(UserDefaultsKeys.showMixReasons)
  private var showMixReasons = UserDefaultsManager.showMixReasons
  @AppStorage(UserDefaultsKeys.streamOnCellular)
  private var streamOnCellular = UserDefaultsManager.streamOnCellular
  @AppStorage(UserDefaultsKeys.downloadOverCellular)
  private var downloadOverCellular = UserDefaultsManager.downloadOverCellular
  @AppStorage(UserDefaultsKeys.enableMaxBitRate) private var wifiBitRate: String?
  @AppStorage(UserDefaultsKeys.cellularBitRate) private var cellularBitRate: String?
  @AppStorage(UserDefaultsKeys.downloadBitRate) private var downloadBitRate: String?
  // A number, which UserDefaultsManager reads as Int64.
  @AppStorage(UserDefaultsKeys.streamCacheMaxSize)
  private var cacheLimit = Int(UserDefaultsManager.streamCacheMaxSize)
  @State private var username = ""
  @State private var serverVersion: String?
  @State private var storage = StorageUsage()
  /// Bumped by each refresh; only the newest measurement is shown.
  @State private var storageRefreshes = 0
  @State private var confirmsClearCache = false
  @State private var confirmsDeleteDownloads = false

  /// The offered limits, highest first.
  private static let limits: [(value: String, label: String)] = TranscodingSettings.bitRates
    .filter { $0 != TranscodingSettings.sourceBitRate }.reversed().map { ($0, "\($0) kbps") }
  private static let limitsWithOriginal = [(TranscodingSettings.sourceBitRate, "Original")] + limits
  private static let cacheLimits = StreamCacheManager.cacheLimits.map { (Int($0.bytes), $0.label) }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        PageTitle("Settings")
        NavigationLink(value: Route.server) { server }
          .buttonStyle(.plain)
          .padding(.top, 14)

        caption("Playback")
        SettingsGroup {
          SettingsRow("Keep Playing", systemImage: "infinity") {
            Toggle("Keep Playing", isOn: $keepPlaying)
          }
          SettingsRow("Why this song", systemImage: "questionmark.circle") {
            Toggle("Why this song", isOn: $showMixReasons)
          }
        }
        Text(
          "Smart Shuffle continues when the queue ends. Show the reason in Now Playing and Up Next."
        )
        .font(.meta)
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 6)

        caption("Quality")
        SettingsGroup {
          SettingsRow("Streaming on Wi-Fi", systemImage: "wifi") {
            picker("Streaming on Wi-Fi", Self.limitsWithOriginal, offered($wifiBitRate))
          }
          SettingsRow("Stream on cellular", systemImage: "cellularbars") {
            Toggle("Stream on cellular", isOn: $streamOnCellular)
          }
          SettingsRow("Cellular bitrate") {
            picker("Cellular bitrate", Self.limits, offered($cellularBitRate))
          }
          .disabled(!streamOnCellular)
          // Original as on the watch: the phone has room for lossless files.
          SettingsRow("Downloads", systemImage: "arrow.down.circle") {
            picker("Downloads", Self.limitsWithOriginal, offered($downloadBitRate))
          }
          SettingsRow("Download on cellular") {
            Toggle("Download on cellular", isOn: $downloadOverCellular)
          }
        }

        caption("Storage")
        storageCard

        caption("General")
        SettingsGroup {
          SettingsRow("Appearance", systemImage: "circle.lefthalf.filled") {
            picker(
              "Appearance", Appearance.allCases.map { ($0, $0.rawValue.capitalized) }, $appearance)
          }
          Button {
            tourSeen = false
            app.tour = .play
          } label: {
            SettingsRow("Show the tour again", systemImage: "flag") { Chevron() }
          }
          .buttonStyle(.plain)
          NavigationLink {
            DiagnosticsView()
          } label: {
            SettingsRow("Diagnostics", systemImage: "stethoscope") { Chevron() }
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
    // Keep Playing, Why this song and the cellular and download bitrates are
    // what the watch follows.
    .onChange(of: keepPlaying) { WatchLink.shared.updateWatch() }
    .onChange(of: showMixReasons) { WatchLink.shared.updateWatch() }
    .onChange(of: cellularBitRate) { WatchLink.shared.updateWatch() }
    .onChange(of: downloadBitRate) { WatchLink.shared.updateWatch() }
    .onChange(of: downloadOverCellular) {
      DownloadSession.shared.cellularAccessChanged()
      WatchSend.shared.cellularAccessChanged()
      WatchLink.shared.updateWatch()
    }
    .onChange(of: cacheLimit) {
      StreamCacheManager.shared.setLimit(Int64(cacheLimit))
      refreshStorage()
    }
    // Deleting the downloads finishes later.
    .onReceive(DownloadSession.shared.downloadsRemoved) { refreshStorage() }
    .task { serverVersion = await ServerAccount.version() }
    .onAppear {
      username = ServerAccount.username
      refreshStorage()
    }
    .confirmationDialog("Clear cached songs", isPresented: $confirmsClearCache) {
      Button("Clear Cached Songs", role: .destructive) {
        StreamCacheManager.shared.clearCache()
        refreshStorage()
      }
    } message: {
      Text("Cached songs come back as you listen.")
    }
    .confirmationDialog("Delete downloads", isPresented: $confirmsDeleteDownloads) {
      Button("Delete All Downloads", role: .destructive) { flooo.deleteAllDownloads() }
    } message: {
      Text("Downloaded albums have to be downloaded again.")
    }
  }

  /// The server, its version and the user; opens the Server screen.
  private var server: some View {
    HStack(spacing: 12) {
      GlyphTile(systemImage: "server.rack", radius: 12).frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 1) {
        Text(ServerAccount.host).font(.rowTitle.weight(.semibold))
        HStack(spacing: 6) {
          StatusDot(isOn: connectivity.isServerReachable)
          Text(ServerAccount.line(version: serverVersion, username: username))
        }
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
      Chevron()
    }
    .padding(.vertical, 12)
    .padding(.horizontal, 14)
    .onPlatter()
    .contentShape(Rectangle())
  }

  /// What the cache and the downloads take of the room left, the cache
  /// limit, and the buttons that clear them.
  private var storageCard: some View {
    VStack(spacing: 0) {
      StorageBar(sizes: storage)
      palette.hairline.frame(height: 1).padding(.top, 14)
      HStack {
        Text("Cache limit")
        Spacer(minLength: 8)
        picker("Cache limit", Self.cacheLimits, $cacheLimit).labelsHidden()
      }
      .frame(minHeight: 50)
      HStack(spacing: 8) {
        clearButton("Clear cache") { confirmsClearCache = true }
        clearButton("Delete downloads") { confirmsDeleteDownloads = true }
      }
      .padding(.top, 4)
    }
    .padding(14)
    .onPlatter()
  }

  private func clearButton(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.rowSubtitle.weight(.semibold))
        .foregroundStyle(Color.floDestructive)
        .frame(maxWidth: .infinity, minHeight: 36)
        .background(palette.surface2, in: Capsule())
        .contentShape(Capsule())
    }
    .buttonStyle(.plain)
  }

  private func refreshStorage() {
    storageRefreshes += 1
    let refresh = storageRefreshes
    Task {
      let sizes = await StorageUsage.measure()
      if refresh == storageRefreshes { storage = sizes }
    }
  }

  /// A stored bitrate as its picker shows it.
  private func offered(_ stored: Binding<String?>) -> Binding<String> {
    Binding {
      TranscodingSettings.offeredBitRate(stored.wrappedValue)
    } set: {
      stored.wrappedValue = $0
    }
  }

  /// A menu of `options` that shows the chosen one: "Original ⌃⌄".
  private func picker<Value: Hashable>(
    _ title: String, _ options: [(value: Value, label: String)], _ selection: Binding<Value>
  ) -> some View {
    Picker(title, selection: selection) {
      ForEach(options, id: \.value) { Text($0.label).tag($0.value) }
    }
    .pickerStyle(.menu)
    .tint(palette.secondary)
  }

  private func caption(_ title: String) -> some View {
    Text(title)
      .font(.meta)
      .foregroundStyle(palette.secondary)
      .padding(.horizontal, 14)
      .padding(.top, 20)
      .padding(.bottom, 6)
  }
}

/// The sizes rows share, so hairlines and rows without an icon line up with
/// the titles.
private enum RowMetrics {
  static let icon: CGFloat = 30
  static let textInset = icon + 12
}

/// Settings rows on one platter with hairlines between them, inset past the
/// rows' icons.
struct SettingsGroup<Content: View>: View {
  var separatorInset = RowMetrics.textInset
  @ViewBuilder var content: Content

  @Environment(\.palette) private var palette

  var body: some View {
    VStack(spacing: 0) {
      Group(subviews: content) { rows in
        ForEach(rows) { row in
          if row.id != rows.first?.id {
            palette.hairline.frame(height: 1).padding(.leading, separatorInset)
          }
          row
        }
      }
    }
    .padding(.horizontal, 14)
    .onPlatter()
  }
}

/// A settings row: an icon tile, the title and a control. A row without an
/// icon keeps its title in line with the others, as a setting that belongs
/// to the row above. Toggles and pickers keep their title for VoiceOver.
struct SettingsRow<Control: View>: View {
  let title: String
  var systemImage: String?
  @ViewBuilder var control: Control

  @Environment(\.palette) private var palette
  @Environment(\.isEnabled) private var isEnabled

  init(_ title: String, systemImage: String? = nil, @ViewBuilder control: () -> Control) {
    self.title = title
    self.systemImage = systemImage
    self.control = control()
  }

  var body: some View {
    HStack(spacing: 12) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .medium))
          .foregroundStyle(palette.accent)
          .frame(width: RowMetrics.icon, height: RowMetrics.icon)
          .background(palette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      }
      Text(title).frame(maxWidth: .infinity, alignment: .leading)
      control.labelsHidden().tint(palette.fill)
    }
    .padding(.leading, systemImage == nil ? RowMetrics.textInset : 0)
    .frame(minHeight: 50)
    .opacity(isEnabled ? 1 : 0.45)
    .contentShape(Rectangle())
  }
}

/// The cache and the downloads against the room left on the iPhone, as one
/// bar with a legend.
private struct StorageBar: View {
  let sizes: StorageUsage

  @Environment(\.palette) private var palette

  private static let height: CGFloat = 10
  private static let gap: CGFloat = 3

  var body: some View {
    VStack(spacing: 10) {
      GeometryReader { proxy in
        HStack(spacing: Self.gap) {
          ForEach(Array(parts(width: proxy.size.width).enumerated()), id: \.offset) {
            RoundedRectangle(cornerRadius: Self.height / 2)
              .fill($0.element.color)
              .frame(width: $0.element.width)
          }
        }
      }
      .frame(height: Self.height)
      // The free room goes under the legend when the line is too long.
      let free = Text("\(sizes.free.fileSize) free")
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 14) {
          legend
          Spacer(minLength: 0)
          free
        }
        VStack(alignment: .leading, spacing: 4) {
          legend
          free
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .font(.meta)
      .foregroundStyle(palette.secondary)
      .lineLimit(1)
    }
  }

  /// The parts that hold something, with their widths; a small one stays as
  /// wide as the bar is high, so it shows.
  private func parts(width: CGFloat) -> [(color: Color, width: CGFloat)] {
    let parts = [
      (color: palette.accent, bytes: sizes.cache),
      (color: Color.floDownloaded, bytes: sizes.downloads),
      (color: palette.surface2, bytes: sizes.free),
    ].filter { $0.bytes > 0 }
    let room = width - Self.gap * CGFloat(max(parts.count - 1, 0))
    var widths = parts.map { max(Self.height, room * sizes.share(of: $0.bytes)) }
    // A small part shows at least a dot; the widest gives up that room.
    if let widest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
      widths[widest] -= widths.reduce(0, +) - room
    }
    return zip(parts, widths).map { ($0.color, $1) }
  }

  private var legend: some View {
    HStack(spacing: 14) {
      key("Cache", sizes.cache, palette.accent)
      key("Downloads", sizes.downloads, Color.floDownloaded)
    }
  }

  private func key(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
    HStack(spacing: 6) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text("\(title) \(bytes.fileSize)")
    }
  }

}

/// The server's requests and the connection, to tell a slow or broken server
/// from an app problem. Shows no secrets, and neither does the shared log.
struct DiagnosticsView: View {
  @ObservedObject private var log = RequestLog.shared
  @ObservedObject private var connectivity = ConnectivityMonitor.shared
  @ObservedObject private var history = HistoryStatus.shared
  @Environment(\.palette) private var palette

  var body: some View {
    List {
      Section {
        ShareLink(item: DiagnosticsReport.text(), subject: Text("Ownwave log")) {
          Label("Share log", systemImage: "square.and.arrow.up").foregroundStyle(palette.accent)
        }
        ForEach(DiagnosticsReport.connectionLines(), id: \.0) { LabeledContent($0.0, value: $0.1) }
      }
      .listRowBackground(palette.surface)

      Section("History") {
        ForEach(DiagnosticsReport.historyLines(history.state), id: \.0) {
          LabeledContent($0.0, value: $0.1)
        }
      }
      .listRowBackground(palette.surface)

      Section("Requests") {
        ForEach(log.entries) { entry in
          VStack(alignment: .leading, spacing: 2) {
            Text(entry.text).font(.meta).foregroundStyle(palette.secondary).lineLimit(2)
            Text(DiagnosticsReport.details(of: entry))
              .font(.rowSubtitle)
              .foregroundStyle(entry.isFailure ? Color.floDestructive : palette.text)
              .lineLimit(2)
          }
        }
      }
      .listRowBackground(palette.surface)
    }
    .scrollContentBackground(.hidden)
    .containerBackground(palette.background, for: .navigation)
    .navigationTitle("Diagnostics")
    .navigationBarTitleDisplayMode(.inline)
    .task { await ListeningHistoryStore.shared.publishStoredState() }
  }
}
