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
      Section("Server") {
        VStack(alignment: .leading, spacing: 2) {
          Text("URL")
            .customFont(.caption2)
            .foregroundColor(.secondary)
          Text(UserDefaultsManager.serverBaseURL)
            .customFont(.caption1)
            .lineLimit(2)
        }
      }

      Section("Playback") {
        Toggle(
          "Keep Playing",
          isOn: Binding(
            get: { UserDefaultsManager.keepPlaying },
            set: { UserDefaultsManager.keepPlaying = $0 }
          ))
      }

      Section("Streaming") {
        Picker("Bitrate", selection: $selectedBitRate) {
          ForEach(watchBitRates, id: \.self) { rate in
            Text(bitRateLabels[rate] ?? rate)
              .tag(rate)
          }
        }
        .onChange(of: selectedBitRate) { newValue in
          UserDefaultsManager.maxBitRate = newValue
        }
      }

      Section("Streaming Cache") {
        Picker("Limit", selection: $selectedCacheSize) {
          Text("Off").tag(Int64(0))
          Text("250 MB").tag(Int64(262_144_000))
          Text("500 MB").tag(Int64(524_288_000))
          Text("1 GB").tag(Int64(1_073_741_824))
        }
        .onChange(of: selectedCacheSize) { newValue in
          UserDefaultsManager.streamCacheMaxSize = newValue
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("Cache Used")
            .customFont(.caption2)
            .foregroundColor(.secondary)
          Text(floooViewModel.streamCacheSize)
            .customFont(.caption1)
        }

        Button(role: .destructive, action: {
          showClearCacheAlert = true
        }) {
          Label("Clear Cache", systemImage: "trash")
        }
      }

      Section("Storage") {
        VStack(alignment: .leading, spacing: 2) {
          Text("Downloaded")
            .customFont(.caption2)
            .foregroundColor(.secondary)
          Text(
            "\(floooViewModel.downloadedAlbums) albums, \(floooViewModel.downloadedSongs) songs"
          )
          .customFont(.caption1)
        }

        VStack(alignment: .leading, spacing: 2) {
          Text("Storage Used")
            .customFont(.caption2)
            .foregroundColor(.secondary)
          Text(floooViewModel.localDirectorySize)
            .customFont(.caption1)
        }

        Button(role: .destructive, action: {
          showClearAlert = true
        }) {
          Label("Clear Downloads", systemImage: "trash")
        }
      }

      Section {
        Button(role: .destructive, action: {
          showLogoutAlert = true
        }) {
          Label("Logout", systemImage: "rectangle.portrait.and.arrow.right")
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
    .alert("Clear Downloads?", isPresented: $showClearAlert) {
      Button("Cancel", role: .cancel) {}
      Button("Clear", role: .destructive) {
        floooViewModel.optimizeLocalStorage()
      }
    } message: {
      Text("All downloaded music will be removed.")
    }
  }
}
