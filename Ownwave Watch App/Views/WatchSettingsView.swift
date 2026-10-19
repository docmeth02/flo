//
//  WatchSettingsView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchSettingsView: View {
  @EnvironmentObject var authViewModel: AuthViewModel
  @EnvironmentObject var floooViewModel: FloooViewModel

  // Stored values, so settings the iPhone applies refresh the rows. A bitrate
  // is read through offeredBitRate, as UserDefaultsManager reads it.
  @AppStorage(UserDefaultsKeys.keepPlaying) private var keepPlaying = false
  @AppStorage(UserDefaultsKeys.enableMaxBitRate) private var maxBitRate: String?
  @AppStorage(UserDefaultsKeys.downloadBitRate) private var downloadBitRate: String?
  @AppStorage(UserDefaultsKeys.downloadOverCellular) private var downloadOverCellular = false
  @AppStorage(UserDefaultsKeys.settingsFollowPhone) private var settingsFollowPhone = false

  @State private var showLogoutAlert = false
  @State private var showClearAlert = false
  @State private var showClearCacheAlert = false
  @State private var showRebuildHistoryAlert = false

  var body: some View {
    List {
      Section {
        infoRow("URL", UserDefaultsManager.serverBaseURL)
      } header: {
        FloSectionHeader("Server")
      }

      Section {
        Toggle(isOn: $keepPlaying) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Keep Playing")
              .font(.floRow)
            Text("Smart Shuffle continues when the queue ends")
              .font(.caption2)
              .foregroundStyle(Color.floSecondary)
          }
        }
        .tint(.floLilac)
        .floRow()
        .disabled(settingsFollowPhone)
      } header: {
        FloSectionHeader("Playback")
      } footer: {
        followsPhone
      }

      Section {
        Group {
          bitRatePicker("Streaming", stored: $maxBitRate)
          bitRatePicker("Downloads", stored: $downloadBitRate)
        }
        .disabled(settingsFollowPhone)
        Toggle(isOn: $downloadOverCellular) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Cellular Downloads")
              .font(.floRow)
            Text("Wi-Fi and iPhone are used first")
              .font(.caption2)
              .foregroundStyle(Color.floSecondary)
          }
        }
        .tint(.floLilac)
        .floRow()
        .onChange(of: downloadOverCellular) { DownloadSession.shared.cellularAccessChanged() }
      } header: {
        FloSectionHeader("Bitrate & Data")
      } footer: {
        followsPhone
      }

      Section {
        Picker("Limit", selection: cacheLimit) {
          ForEach(StreamCacheManager.cacheLimits, id: \.bytes) { Text($0.label).tag($0.bytes) }
        }
        .tint(.floLilac)
        .floRow()

        infoRow("Cache Used", floooViewModel.streamCacheSize)

        actionRow("Clear Cache", systemImage: "trash") {
          showClearCacheAlert = true
        }
      } header: {
        FloSectionHeader("Streaming Cache")
      }

      Section {
        infoRow(
          "Downloaded",
          counted(floooViewModel.downloadedAlbums, "album") + ", "
            + counted(floooViewModel.downloadedSongs, "song"))

        infoRow("Storage Used", floooViewModel.localDirectorySize)

        actionRow("Clear Downloads", systemImage: "trash") {
          showClearAlert = true
        }
      } header: {
        FloSectionHeader("Storage")
      }

      if CoreDataManager.shared.isUsingVolatileStore {
        Section {
          StorageWarningRow()
        }
      }

      Section {
        NavigationLink(destination: WatchDiagnosticsView()) {
          Label {
            Text("Diagnostics").font(.floRow)
          } icon: {
            Image(systemName: "waveform.path.ecg").foregroundStyle(Color.floSecondary)
          }
        }
        .floRow()

        actionRow("Rebuild History", systemImage: "arrow.clockwise") {
          showRebuildHistoryAlert = true
        }
      }

      Section {
        actionRow("Logout", systemImage: "rectangle.portrait.and.arrow.right") {
          showLogoutAlert = true
        }
      }
    }
    .floNavigationTitle("Settings")
    .onAppear {
      floooViewModel.getLocalStorageInformation()
    }
    .alert("Logout?", isPresented: $showLogoutAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Logout", role: .destructive) {
        authViewModel.logout()
      }
    } message: {
      Text("You will need to sign in again.")
    }
    .alert("Clear Cache?", isPresented: $showClearCacheAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        StreamCacheManager.shared.clearCache()
        floooViewModel.getLocalStorageInformation()
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

  /// Setting it trims the cache at once; the storage figures follow, and
  /// their update redraws the picker.
  private var cacheLimit: Binding<Int64> {
    Binding(
      get: { UserDefaultsManager.streamCacheMaxSize },
      set: {
        StreamCacheManager.shared.setLimit($0)
        floooViewModel.getLocalStorageInformation()
      })
  }

  @ViewBuilder private var followsPhone: some View {
    if settingsFollowPhone {
      Text("Follows your iPhone")
        .font(.caption2)
        .foregroundStyle(Color.floSecondary)
    }
  }

  private func bitRatePicker(_ title: String, stored: Binding<String?>) -> some View {
    let selection = Binding(
      get: { TranscodingSettings.offeredBitRate(stored.wrappedValue) },
      set: { stored.wrappedValue = $0 })
    return Picker(title, selection: selection) {
      ForEach(TranscodingSettings.bitRates, id: \.self) { rate in
        Text(rate == TranscodingSettings.sourceBitRate ? "Original" : "\(rate) kbps")
          .tag(rate)
      }
    }
    .tint(.floLilac)
    .floRow()
  }

  private func infoRow(_ label: String, _ value: String) -> some View {
    FloInfoRow(label, value).floRow()
  }

  private func actionRow(
    _ title: String, systemImage: String, action: @escaping () -> Void
  ) -> some View {
    Button(role: .destructive, action: action) {
      Label(title, systemImage: systemImage)
        .font(.floRow)
        .foregroundStyle(Color.floDestructive)
    }
    .floRow()
  }
}
