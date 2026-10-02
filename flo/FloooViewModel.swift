//
//  FloooViewModel.swift
//  flo
//
//  Created by rizaldy on 11/01/25.
//

import SwiftUI

class FloooViewModel: ObservableObject {
  @Published var downloadedAlbums: Int = 0
  @Published var downloadedSongs: Int = 0

  @Published var localDirectorySize: String = "0 MB"
  @Published var streamCacheSize: String = "0 MB"

  static let shared = FloooViewModel()

  func getLocalStorageInformation() {
    self.downloadedAlbums = ScanStatusService.shared.getDownloadedAlbumsCount()
    self.downloadedSongs = ScanStatusService.shared.getDownloadedSongsCount()

    Task {
      do {
        let calculateDirectorySize = try await LocalFileManager.shared.calculateDirectorySize()
        let cacheSize = await StreamCacheManager.shared.calculateCacheSize()

        await MainActor.run {
          self.localDirectorySize = calculateDirectorySize
          self.streamCacheSize = bytesToMBOrGB(cacheSize)
        }
      } catch {
        print("Error: \(error)")
      }
    }
  }

  func optimizeLocalStorage() {
    LocalFileManager.shared.deleteDownloadedAlbums { result in
      switch result {
      case .success:
        // Records go even when the media folder was already missing.
        CoreDataManager.shared.clearDownloads()

        self.getLocalStorageInformation()

      case .failure(let error):
        print("error in optimizeLocalStorage>>>", error)
      }
    }
  }

  func setNowPlayingToScrobbleServer(nowPlaying: QueueEntity) {
    processScrobble(submission: false, nowPlaying: nowPlaying)
  }

  func logSkip(nowPlaying: QueueEntity) {
    FloooService.shared.saveListeningHistory(payload: nowPlaying, skipped: true)
  }

  func scrobble(submission: Bool, nowPlaying: QueueEntity) {
    FloooService.shared.saveListeningHistory(payload: nowPlaying)
    processScrobble(submission: submission, nowPlaying: nowPlaying)
  }

  private func processScrobble(submission: Bool, nowPlaying: QueueEntity) {
    guard let payload = ScrobblePayload(nowPlaying: nowPlaying) else { return }

    // Navidrome records every scrobble for its own play counts and forwards it
    // to Last.fm or ListenBrainz when the user linked them there, so the watch
    // always scrobbles to the server and queues submissions while it is away.
    let connectivity = ConnectivityMonitor.shared
    guard connectivity.isOnline, connectivity.isServerReachable else {
      if submission {
        ScrobbleQueueManager.shared.enqueue(payload)
      }
      return
    }

    FloooService.shared.scrobbleToBuiltinEndpoint(
      submission: submission, songId: payload.songId, time: payload.listenTime
    ) { result in
      switch result {
      case .success:
        debugLog("scrobble delivered: \(payload.songId) submission=\(submission)")
        if submission { ListeningHistoryStore.shared.scrobbleDelivered() }

      case .failure(let error):
        if submission && !FloooService.shared.isPermanentScrobbleFailure(error) {
          DispatchQueue.main.async { ScrobbleQueueManager.shared.enqueue(payload) }
        }
      }
    }
  }
}
