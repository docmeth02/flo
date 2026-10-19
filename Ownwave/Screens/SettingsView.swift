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
  @State private var keepPlaying = UserDefaultsManager.keepPlaying
  @State private var showMixReasons = UserDefaultsManager.showMixReasons
  @State private var streamOnCellular = UserDefaultsManager.streamOnCellular
  @State private var wifiBitRate = UserDefaultsManager.maxBitRate
  @State private var cellularBitRate = UserDefaultsManager.cellularBitRate
  @State private var downloadBitRate = UserDefaultsManager.downloadBitRate
  @State private var downloadOverCellular = UserDefaultsManager.downloadOverCellular
  @State private var username = ""
  @State private var serverVersion: String?
  @State private var cachedSongs = 0
  @State private var confirmsLogout = false
  @State private var confirmsClear = false

  /// The offered limits, highest first as the design lists them.
  private static let limits: [(value: String, label: String)] = TranscodingSettings.bitRates
    .filter { $0 != TranscodingSettings.sourceBitRate }.reversed().map { ($0, $0) }
  private static let limitsWithOriginal = [(TranscodingSettings.sourceBitRate, "Original")] + limits

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
          Segmented(options: Self.limitsWithOriginal, selection: $wifiBitRate)
        }
        section("Streaming on cellular (kbps)") {
          Segmented(options: Self.limits, selection: $cellularBitRate)
        }
        section("Downloads (kbps)") {
          // Original as on the watch: the phone has room for lossless files.
          Segmented(options: Self.limitsWithOriginal, selection: $downloadBitRate)
          toggle(
            "Download on cellular", "Downloads wait for Wi-Fi when this is off",
            isOn: $downloadOverCellular)
        }
        storage
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
    .onChange(of: keepPlaying) {
      UserDefaultsManager.keepPlaying = $1
      WatchLink.shared.updateWatch()
    }
    .onChange(of: showMixReasons) { UserDefaultsManager.showMixReasons = $1 }
    .onChange(of: streamOnCellular) { UserDefaultsManager.streamOnCellular = $1 }
    .onChange(of: wifiBitRate) { UserDefaultsManager.maxBitRate = $1 }
    .onChange(of: cellularBitRate) {
      UserDefaultsManager.cellularBitRate = $1
      WatchLink.shared.updateWatch()
    }
    .onChange(of: downloadBitRate) {
      UserDefaultsManager.downloadBitRate = $1
      WatchLink.shared.updateWatch()
    }
    .onChange(of: downloadOverCellular) {
      UserDefaultsManager.downloadOverCellular = $1
      DownloadSession.shared.cellularAccessChanged()
      WatchSend.shared.cellularAccessChanged()
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
    .confirmationDialog("Clear storage", isPresented: $confirmsClear) {
      Button("Clear Cached Songs", role: .destructive) {
        StreamCacheManager.shared.clearCache()
        refreshStorage()
      }
      Button("Delete All Downloads", role: .destructive) {
        flooo.optimizeLocalStorage()
        refreshStorage()
      }
    } message: {
      Text("Cached songs come back as you listen. Downloaded albums have to be downloaded again.")
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

  private var storage: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("Downloads on this iPhone").font(.rowTitle.weight(.semibold))
        Text("\(flooo.localDirectorySize) · \(counted(cachedSongs, "cached song"))")
          .font(.rowSubtitle)
          .foregroundStyle(palette.secondary)
      }
      Spacer()
      Button("Clear") { confirmsClear = true }
        .font(.rowSubtitle.weight(.semibold))
        .foregroundStyle(Color.floDestructive)
    }
    .card(horizontal: 16, vertical: 14)
  }

  private func refreshStorage() {
    flooo.getLocalStorageInformation()
    cachedSongs = StreamCacheManager.shared.getCachedSongs().count
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

/// The design's segmented control: the chosen option on the fill with ink,
/// or, `filled` false, on the second platter color.
private struct Segmented<Value: Hashable>: View {
  let options: [(value: Value, label: String)]
  @Binding var selection: Value
  var filled = true

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.value) { option in
        let isOn = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(option.label)
            .font(.rowSubtitle.weight(.semibold))
            .foregroundStyle(
              isOn ? (filled ? palette.ink : palette.text) : (filled ? palette.text : palette.secondary)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
              isOn ? (filled ? palette.fill : palette.surface2) : .clear,
              in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
    .padding(3)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .animation(.snappy(duration: 0.2), value: selection)
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
        ShareLink(item: Self.exportText(), subject: Text("Ownwave log")) {
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

  private static func exportText() -> String {
    let device = UIDevice.current
    return DiagnosticsReport.text(system: "\(device.systemName) \(device.systemVersion)")
  }
}
