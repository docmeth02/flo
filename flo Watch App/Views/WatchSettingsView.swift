//
//  WatchSettingsView.swift
//  flo Watch App
//

import SwiftUI

struct WatchSettingsView: View {
  @EnvironmentObject var authViewModel: AuthViewModel
  @EnvironmentObject var floooViewModel: FloooViewModel

  @State private var selectedBitRate: String = UserDefaultsManager.maxBitRate
  @State private var showLogoutAlert = false
  @State private var showClearAlert = false
  @State private var showClearCacheAlert = false
  @State private var showRebuildHistoryAlert = false
  @State private var selectedCacheSize: Int64 = UserDefaultsManager.streamCacheMaxSize

  private let watchBitRates = ["0", "32", "64", "96", "128"]
  private let bitRateLabels = [
    "0": "Source",
    "32": "32 kbps",
    "64": "64 kbps",
    "96": "96 kbps",
    "128": "128 kbps",
  ]

  var body: some View {
    List {
      Section {
        infoRow("URL", UserDefaultsManager.serverBaseURL)
      } header: {
        FloSectionHeader("Server")
      }

      Section {
        Toggle(
          isOn: Binding(
            get: { UserDefaultsManager.keepPlaying },
            set: { UserDefaultsManager.keepPlaying = $0 }
          )
        ) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Keep Playing")
              .font(.floRow)
            Text("Smart Shuffle continues when the queue ends")
              .font(.caption2)
              .foregroundStyle(Color.floSecondary)
          }
        }
        .tint(.floToggle)
        .floRow()
      } header: {
        FloSectionHeader("Playback")
      }

      Section {
        Picker("Bitrate", selection: $selectedBitRate) {
          ForEach(watchBitRates, id: \.self) { rate in
            Text(bitRateLabels[rate] ?? rate)
              .tag(rate)
          }
        }
        .tint(.floLavender)
        .floRow()
        .onChange(of: selectedBitRate) { newValue in
          UserDefaultsManager.maxBitRate = newValue
        }
      } header: {
        FloSectionHeader("Streaming")
      }

      Section {
        Picker("Limit", selection: $selectedCacheSize) {
          Text("Off").tag(Int64(0))
          Text("250 MB").tag(Int64(262_144_000))
          Text("500 MB").tag(Int64(524_288_000))
          Text("1 GB").tag(Int64(1_073_741_824))
        }
        .tint(.floLavender)
        .floRow()
        .onChange(of: selectedCacheSize) { newValue in
          UserDefaultsManager.streamCacheMaxSize = newValue
          // Eviction only trims an enabled cache; turning it off frees it all.
          if newValue == 0 {
            StreamCacheManager.shared.clearCache()
            floooViewModel.getLocalStorageInformation()
          }
        }

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
          "\(floooViewModel.downloadedAlbums) albums, \(floooViewModel.downloadedSongs) songs")

        infoRow("Storage Used", floooViewModel.localDirectorySize)

        actionRow("Clear Downloads", systemImage: "trash") {
          showClearAlert = true
        }
      } header: {
        FloSectionHeader("Storage")
      }

      if CoreDataManager.shared.isUsingVolatileStore {
        Section {
          Label(
            "Storage unavailable: history, downloads and queued scrobbles are not saved until the app restarts.",
            systemImage: "exclamationmark.triangle"
          )
          .font(.floMeta)
          .foregroundStyle(Color.floWarningText)
          .floRow()
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
    .navigationTitle("Settings")
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
        floooViewModel.optimizeLocalStorage()
      }
    } message: {
      Text("All downloaded music will be removed.")
    }
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
