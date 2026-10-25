//
//  WatchSettingsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchSettingsView: View {
  @EnvironmentObject var authViewModel: AuthViewModel
  @EnvironmentObject var floooViewModel: FloooViewModel
  @EnvironmentObject var downloads: DownloadSession
  @ObservedObject private var connectivity = ConnectivityMonitor.shared

  // Stored values, so settings the iPhone applies refresh the rows. A bitrate
  // is read through offeredBitRate, as UserDefaultsManager reads it.
  @AppStorage(UserDefaultsKeys.keepPlaying) private var keepPlaying = false
  @AppStorage(UserDefaultsKeys.enableMaxBitRate) private var maxBitRate: String?
  @AppStorage(UserDefaultsKeys.downloadBitRate) private var downloadBitRate: String?
  @AppStorage(UserDefaultsKeys.downloadOverCellular) private var downloadOverCellular = false
  @AppStorage(UserDefaultsKeys.settingsFollowPhone) private var settingsFollowPhone = false
  @AppStorage(UserDefaultsKeys.streamCacheMaxSize)
  private var cacheLimit = Int(UserDefaultsManager.streamCacheMaxSize)

  @State private var storage = StorageUsage()
  @State private var storageChanges = 0
  @State private var showLogoutAlert = false
  @State private var showClearAlert = false
  @State private var showClearCacheAlert = false
  @State private var showRebuildHistoryAlert = false

  private static let bitRates = TranscodingSettings.bitRates.map {
    ($0, $0 == TranscodingSettings.sourceBitRate ? "Original" : "\($0) kbps")
  }
  private static let cacheLimits = StreamCacheManager.cacheLimits.map { (Int($0.bytes), $0.label) }

  var body: some View {
    List {
      server
        .padding(.vertical, 8)
        .floJoinedRow(.alone)

      Section {
        Group {
          Toggle(isOn: $keepPlaying) {
            SettingLabel("Keep Playing", systemImage: "infinity")
          }
          .joined(.first)
          ChoiceRow(
            title: "Streaming", systemImage: "wifi", options: Self.bitRates,
            selection: offered($maxBitRate)
          )
          .joined(.middle)
          ChoiceRow(
            title: "Downloads", systemImage: "arrow.down.circle", options: Self.bitRates,
            selection: offered($downloadBitRate)
          )
          .joined(.middle)
          Toggle(isOn: $downloadOverCellular) {
            SettingLabel("Cellular downloads", systemImage: "cellularbars")
          }
          .joined(.last)
        }
        .tint(.floLilac)
        .disabled(settingsFollowPhone)
        // A value the iPhone applies restarts the downloads there.
        .onChange(of: downloadOverCellular) {
          if !settingsFollowPhone { DownloadSession.shared.cellularAccessChanged() }
        }
        footer(
          settingsFollowPhone
            ? "Follows your iPhone"
            : "Keep Playing continues with Smart Shuffle when the queue ends. Cellular is used only without Wi-Fi or iPhone."
        )
      } header: {
        FloSectionHeader("Playback")
      }

      Section {
        storageBar
          .padding(.top, 9)
          .padding(.bottom, 6)
          .floJoinedRow(.first)
        Group {
          ChoiceRow(title: "Cache limit", options: Self.cacheLimits, selection: $cacheLimit)
            .floJoinedRow(.middle, hairlineInset: FloLayout.joinedRowInsets.leading)
            .onChange(of: cacheLimit) {
              // Trims the cache at once.
              StreamCacheManager.shared.setLimit(Int64(cacheLimit))
              storageChanges += 1
            }
          actionRow("Clear Cache") { showClearCacheAlert = true }
            .floJoinedRow(.middle, hairlineInset: FloLayout.joinedRowInsets.leading)
          actionRow("Clear Downloads") { showClearAlert = true }
            .floJoinedRow(.last, hairlineInset: FloLayout.joinedRowInsets.leading)
        }
        if CoreDataManager.shared.isUsingVolatileStore {
          StorageWarningRow()
        }
      } header: {
        FloSectionHeader("Storage")
      }

      Section {
        NavigationLink(destination: WatchDiagnosticsView()) {
          HStack {
            SettingLabel("Diagnostics", systemImage: "waveform.path.ecg")
            Spacer(minLength: 4)
            Chevron()
          }
        }
        .joined(.first)
        Button {
          showRebuildHistoryAlert = true
        } label: {
          SettingLabel("Rebuild History", systemImage: "clock.arrow.circlepath")
        }
        .joined(.last)
      }

      Section {
        Button(role: .destructive) {
          showLogoutAlert = true
        } label: {
          SettingLabel(
            "Log Out", systemImage: "rectangle.portrait.and.arrow.right", tint: .floDestructive)
        }
        .joined(.alone)
      }
    }
    .listStyle(.plain)
    // Not 0, at which watchOS leaves the list's last row undrawn.
    .environment(\.defaultMinListRowHeight, 1)
    .floNavigationTitle("Settings")
    .measuresStorage($storage, trigger: storageChanges)
    // Deleting the downloads finishes later.
    .onReceive(downloads.downloadsRemoved) { storageChanges += 1 }
    .alert("Log Out?", isPresented: $showLogoutAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Log Out", role: .destructive) {
        authViewModel.logout()
      }
    } message: {
      Text("You will need to sign in again.")
    }
    .alert("Clear Cache?", isPresented: $showClearCacheAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        StreamCacheManager.shared.clearCache()
        storageChanges += 1
      }
    } message: {
      Text("All cached streams will be removed.")
    }
    .alert("Rebuild History?", isPresented: $showRebuildHistoryAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Rebuild", role: .destructive) {
        Task { await ListeningHistoryStore.shared.rebuild() }
      }
    } message: {
      Text("Your listening history is imported from the server again.")
    }
    .alert("Clear Downloads?", isPresented: $showClearAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        floooViewModel.deleteAllDownloads()
      }
    } message: {
      Text("All downloaded music will be removed.")
    }
  }

  /// The server's address, with a dot for whether it answers.
  private var server: some View {
    let status = connectivity.isServerReachable ? "Reachable" : "Not reachable"
    return HStack(spacing: 8) {
      Image(systemName: "server.rack")
        .font(.system(size: 14))
        .foregroundStyle(Color.floLilac)
        .frame(width: FloLayout.smallThumbnail, height: FloLayout.smallThumbnail)
        .background(
          RoundedRectangle(cornerRadius: FloLayout.thumbnailRadius, style: .continuous)
            .fill(Color.floTile))
      VStack(alignment: .leading, spacing: 1) {
        Text(ServerAccount.authority)
          .font(.floRowTitle)
        HStack(spacing: 4) {
          Circle()
            .fill(connectivity.isServerReachable ? Color.floDownloaded : Color.floSecondary)
            .frame(width: 6, height: 6)
          // A server at the root of its host has no path to show.
          Text(ServerAccount.path.isEmpty ? status : ServerAccount.path)
        }
        .font(.floMeta)
        .foregroundStyle(Color.floSecondary)
      }
      .lineLimit(1)
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
    .accessibilityValue(status)
  }

  /// The cache and the downloads against the room left, with a legend.
  private var storageBar: some View {
    VStack(alignment: .leading, spacing: 6) {
      StorageBar(
        usage: storage,
        parts: [
          .init(color: .floLilac, bytes: storage.cache),
          .init(color: .floDownloaded, bytes: storage.downloads),
        ])
      // One key under the other when they do not fit side by side.
      ViewThatFits(in: .horizontal) {
        HStack(alignment: .firstTextBaseline, spacing: 8) { legend }
        VStack(alignment: .leading, spacing: 2) { legend }
      }
      .font(.floMeta)
      .foregroundStyle(Color.floSecondary)
    }
    .accessibilityElement(children: .combine)
  }

  @ViewBuilder private var legend: some View {
    key("Cache", storage.cache, .floLilac)
    key("Downloads", storage.downloads, .floDownloaded)
  }

  private func key(_ title: String, _ bytes: Int64, _ color: Color) -> some View {
    HStack(spacing: 4) {
      Circle().fill(color).frame(width: 6, height: 6)
      Text("\(title) \(bytes.fileSize)")
    }
  }

  private func footer(_ text: String) -> some View {
    Text(text)
      .font(.caption2)
      .foregroundStyle(Color.floSecondary)
      .listRowBackground(Color.clear)
      .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
  }

  /// A stored bitrate as its choices show it, as UserDefaultsManager reads it.
  private func offered(_ stored: Binding<String?>) -> Binding<String> {
    Binding(
      get: { TranscodingSettings.offeredBitRate(stored.wrappedValue) },
      set: { stored.wrappedValue = $0 })
  }

  private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
    Button(role: .destructive, action: action) {
      SettingLabel(title, tint: .floDestructive)
    }
  }
}

/// A setting with a few values: its title and the chosen value, opening the
/// list of values.
private struct ChoiceRow<Value: Hashable>: View {
  let title: String
  var systemImage: String?
  let options: [(Value, String)]
  @Binding var selection: Value

  var body: some View {
    NavigationLink {
      ChoiceList(title: title, options: options, selection: $selection)
    } label: {
      // The value goes under the title when both do not fit on one line.
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 4) {
          label.fixedSize()
          Spacer(minLength: 4)
          value.fixedSize()
          Chevron()
        }
        HStack(spacing: 4) {
          VStack(alignment: .leading, spacing: 1) {
            label
            value.padding(.leading, systemImage == nil ? 0 : SettingLabel.titleInset)
          }
          Spacer(minLength: 4)
          Chevron()
        }
      }
    }
  }

  private var label: some View { SettingLabel(title, systemImage: systemImage) }

  private var value: some View {
    Text(options.first { $0.0 == selection }?.1 ?? "")
      .font(.floMeta)
      .foregroundStyle(Color.floSecondary)
  }
}

private struct ChoiceList<Value: Hashable>: View {
  let title: String
  let options: [(Value, String)]
  @Binding var selection: Value
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    List {
      ForEach(options, id: \.0) { value, label in
        Button {
          selection = value
          dismiss()
        } label: {
          HStack {
            Text(label).font(.floRow)
            Spacer(minLength: 4)
            if value == selection {
              Image(systemName: "checkmark").foregroundStyle(Color.floLilac)
            }
          }
        }
        .accessibilityAddTraits(value == selection ? .isSelected : [])
        .floRow()
      }
    }
    .floNavigationTitle(title)
  }
}

/// A Settings row's title after its lilac icon; red for a destructive one.
private struct SettingLabel: View {
  let title: String
  var systemImage: String?
  var tint: Color?

  static let iconWidth: CGFloat = 20
  static let spacing: CGFloat = 8
  /// Where the title starts after an icon.
  static let titleInset = iconWidth + spacing

  init(_ title: String, systemImage: String? = nil, tint: Color? = nil) {
    self.title = title
    self.systemImage = systemImage
    self.tint = tint
  }

  var body: some View {
    HStack(spacing: Self.spacing) {
      if let systemImage {
        Image(systemName: systemImage)
          .font(.system(size: 16))
          .foregroundStyle(tint ?? .floLilac)
          .frame(width: Self.iconWidth)
      }
      Text(title)
        .font(.floRow)
        .foregroundStyle(tint ?? .floText)
    }
  }
}

extension View {
  /// A Settings row joined on its group's platter, its hairline under the
  /// title past the icon.
  fileprivate func joined(_ position: RowPosition) -> some View {
    floJoinedRow(
      position,
      hairlineInset: FloLayout.joinedRowInsets.leading + SettingLabel.titleInset)
  }
}
