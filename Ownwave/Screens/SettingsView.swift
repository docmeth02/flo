//
//  SettingsView.swift
//  Ownwave
//

import SwiftUI

struct SettingsView: View {
  @EnvironmentObject private var app: AppModel
  @EnvironmentObject private var auth: AuthViewModel
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
  @State private var cachedSongs = 0
  @State private var confirmsLogout = false
  @State private var confirmsClearCache = false
  @State private var confirmsDeleteDownloads = false

  /// The offered limits, highest first as the design lists them.
  private static let limits: [(value: String, label: String)] = TranscodingSettings.bitRates
    .filter { $0 != TranscodingSettings.sourceBitRate }.reversed().map { ($0, $0) }
  private static let limitsWithOriginal = [(TranscodingSettings.sourceBitRate, "Original")] + limits
  private static let cacheLimits = StreamCacheManager.cacheLimits.map { (Int($0.bytes), $0.label) }

  var body: some View {
    ScrollView {
      VStack(spacing: 22) {
        PageTitle("Settings")
        section("Server") { server }
        section("Appearance") {
          Segmented(
            options: Appearance.allCases.map { ($0, $0.rawValue.capitalized) },
            selection: $appearance, filled: false)
        }
        Button {
          tourSeen = false
          app.tour = .play
        } label: {
          Text("Show the tour again")
            .font(.rowTitle.weight(.semibold))
            .foregroundStyle(palette.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .card(horizontal: 16, vertical: 14)
        }
        .buttonStyle(.plain)
        section("Playback") {
          toggle(
            "Keep Playing", "Smart Shuffle continues when the queue ends", isOn: $keepPlaying)
          toggle(
            "Why this song", "Show the reason in Now Playing and Up Next", isOn: $showMixReasons)
          toggle(
            "Stream on cellular", "Uses the cellular bitrate below", isOn: $streamOnCellular)
        }
        section("Streaming on Wi-Fi (kbps)") {
          Segmented(options: Self.limitsWithOriginal, selection: offered($wifiBitRate))
        }
        section("Streaming on cellular (kbps)") {
          Segmented(options: Self.limits, selection: offered($cellularBitRate))
        }
        section("Streaming cache") {
          Segmented(options: Self.cacheLimits, selection: $cacheLimit)
          storage("Cached songs", "\(flooo.streamCacheSize) · \(counted(cachedSongs, "song"))") {
            confirmsClearCache = true
          }
          Text(
            "Songs you stream are kept here and the next two are fetched ahead, so they play "
              + "again without a connection. The least recently played go first when it is full."
          )
          .font(.meta)
          .foregroundStyle(palette.secondary)
          .padding(.horizontal, 4)
        }
        section("Downloads (kbps)") {
          // Original as on the watch: the phone has room for lossless files.
          Segmented(options: Self.limitsWithOriginal, selection: offered($downloadBitRate))
          toggle(
            "Download on cellular", "Downloads wait for Wi-Fi when this is off",
            isOn: $downloadOverCellular)
        }
        storage("Downloads on this iPhone", flooo.localDirectorySize) {
          confirmsDeleteDownloads = true
        }
        NavigationLink {
          DiagnosticsView()
        } label: {
          HStack {
            Text("Diagnostics").font(.rowTitle.weight(.semibold))
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 14, weight: .semibold))
              .foregroundStyle(palette.secondary)
          }
          .card(horizontal: 16, vertical: 14)
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .navigationBarTitleDisplayMode(.inline)
    // Keep Playing and the cellular and download bitrates are what the watch
    // follows.
    .onChange(of: keepPlaying) { WatchLink.shared.updateWatch() }
    .onChange(of: cellularBitRate) { WatchLink.shared.updateWatch() }
    .onChange(of: downloadBitRate) { WatchLink.shared.updateWatch() }
    .onChange(of: downloadOverCellular) {
      DownloadSession.shared.cellularAccessChanged()
      WatchSend.shared.cellularAccessChanged()
    }
    .onChange(of: cacheLimit) {
      StreamCacheManager.shared.setLimit(Int64(cacheLimit))
      refreshStorage()
    }
    .onAppear {
      if case .found(let login) = KeychainManager.loadAuth() { username = login.username }
      AlbumService.shared.serverVersion { serverVersion = $0 }
      refreshStorage()
    }
    .alert("Change Server?", isPresented: $confirmsLogout) {
      Button("Cancel", role: .cancel) {}
      Button("Sign Out", role: .destructive) { auth.logout() }
    } message: {
      Text("You will need to sign in again. Downloads stay on this iPhone.")
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
      Button("Delete All Downloads", role: .destructive) {
        flooo.deleteAllDownloads()
        refreshStorage()
      }
    } message: {
      Text("Downloaded albums have to be downloaded again.")
    }
  }

  private var server: some View {
    HStack(spacing: 12) {
      Image(systemName: "server.rack")
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(palette.accent)
        .frame(width: 42, height: 42)
        .background(palette.surface2, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
      VStack(alignment: .leading, spacing: 1) {
        Text(serverName).font(.rowTitle.weight(.semibold)).lineLimit(1)
        HStack(spacing: 6) {
          Circle()
            .fill(connectivity.isServerReachable ? Color.floDownloaded : palette.secondary)
            .frame(width: 7, height: 7)
          Text(serverLine)
        }
        .font(.rowSubtitle)
        .foregroundStyle(palette.secondary)
      }
      Spacer(minLength: 0)
      Button("Change") { confirmsLogout = true }
        .font(.rowSubtitle)
        .foregroundStyle(palette.accent)
    }
    .card(horizontal: 16, vertical: 14)
  }

  /// "Navidrome 0.64.2 · anna"
  private var serverLine: String {
    // Navidrome appends its build, "0.64.2 (10114574)".
    let version = serverVersion?.split(separator: " ").first
    let name = version.map { "Navidrome \($0)" } ?? "Navidrome"
    return username.isEmpty ? name : "\(name) · \(username)"
  }

  /// The server without its scheme, e.g. "music.home.lan" or
  /// "example.com/navidrome".
  private var serverName: String {
    let url = UserDefaultsManager.serverBaseURL
    guard let components = URLComponents(string: url), let host = components.host else {
      return url
    }
    return host + (components.port.map { ":\($0)" } ?? "") + components.path
  }

  /// The room something takes on the phone, with Clear.
  private func storage(_ title: String, _ detail: String, clear: @escaping () -> Void)
    -> some View
  {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.rowTitle.weight(.semibold))
        Text(detail).font(.rowSubtitle).foregroundStyle(palette.secondary)
      }
      Spacer()
      Button("Clear", action: clear)
        .font(.rowSubtitle.weight(.semibold))
        .foregroundStyle(Color.floDestructive)
    }
    .card(horizontal: 16, vertical: 14)
  }

  private func refreshStorage() {
    flooo.getLocalStorageInformation()
    cachedSongs = StreamCacheManager.shared.getCachedSongs().count
  }

  /// A stored bitrate as its picker shows it.
  private func offered(_ stored: Binding<String?>) -> Binding<String> {
    Binding {
      TranscodingSettings.offeredBitRate(stored.wrappedValue)
    } set: {
      stored.wrappedValue = $0
    }
  }

  private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.rowSubtitle.weight(.semibold))
        .foregroundStyle(palette.secondary)
        .padding(.horizontal, 4)
      content()
    }
  }

  private func toggle(_ title: String, _ subtitle: String, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.rowTitle.weight(.semibold))
        Text(subtitle).font(.rowSubtitle).foregroundStyle(palette.secondary)
      }
    }
    .tint(palette.fill)
    .card(horizontal: 16, vertical: 14)
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
