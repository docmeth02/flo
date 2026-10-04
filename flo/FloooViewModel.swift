//
//  FloooViewModel.swift
//  flo
//
//  Created by rizaldy on 11/01/25.
//

import Alamofire
import SwiftUI

class FloooViewModel: ObservableObject {
  @Published var downloadedAlbums: Int = 0
  @Published var downloadedSongs: Int = 0

  @Published var localDirectorySize: String = "0 MB"
  @Published var streamCacheSize: String = "0 MB"

  static let shared = FloooViewModel()

  private struct PlaybackReport {
    let state: PlaybackReportState
    let positionMs: Int
    let payload: ScrobblePayload
  }

  // Reports go out one at a time, so an older state never lands after a
  // newer one. Main thread.
  private var reportInFlight = false
  private var waitingReports: [PlaybackReport] = []
  private var lastPlayingReport: (songId: String, at: Date)?
  // A server without reportPlayback is asked once per launch, or per login.
  private var reportPlaybackUnsupported = false

  init() {
    NotificationCenter.default.addObserver(
      forName: .didLogout, object: nil, queue: .main
    ) { [weak self] _ in
      self?.waitingReports = []
      self?.lastPlayingReport = nil
      self?.reportPlaybackUnsupported = false
    }
  }

  func getLocalStorageInformation() {
    self.downloadedAlbums = CoreDataManager.shared.countRecords(entity: PlaylistEntity.self)
    self.downloadedSongs = CoreDataManager.shared.countRecords(entity: SongEntity.self)

    Task {
      do {
        let calculateDirectorySize = try await LocalFileManager.shared.calculateDirectorySize()
        let cacheSize = await StreamCacheManager.shared.calculateCacheSize()

        await MainActor.run {
          self.localDirectorySize = calculateDirectorySize
          self.streamCacheSize = bytesToMBOrGB(cacheSize)
        }
      } catch {
        debugLog("storage size failed: \(error)")
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
        debugLog("optimizeLocalStorage failed: \(error)")
      }
    }
  }

  func scrobble(submission: Bool, nowPlaying: QueueEntity) {
    guard let payload = ScrobblePayload(nowPlaying: nowPlaying) else { return }
    processScrobble(submission: submission, payload: payload)
  }

  /// Reports the song's playback state to the server's now playing list.
  /// Reports are never queued offline, a waiting one is replaced by a newer
  /// state of the same song, and playing is sent at most every 30 seconds.
  /// A server without reportPlayback gets a now playing scrobble for
  /// starting instead. Main thread.
  func reportPlayback(state: PlaybackReportState, nowPlaying: QueueEntity, positionSeconds: Double) {
    guard AuthService.shared.accountKey != nil,
      let payload = ScrobblePayload(nowPlaying: nowPlaying)
    else { return }
    guard !reportPlaybackUnsupported else {
      if state == .starting { processScrobble(submission: false, payload: payload) }
      return
    }

    guard ConnectivityMonitor.shared.canReachServer else { return }

    let now = Date()
    if state == .playing, let last = lastPlayingReport, last.songId == payload.songId,
      now.timeIntervalSince(last.at) < 30
    {
      return
    }
    lastPlayingReport = state == .starting || state == .playing ? (payload.songId, now) : nil

    let positionMs = positionSeconds.isFinite ? Int(max(0, positionSeconds) * 1000) : 0
    waitingReports.removeAll { $0.payload.songId == payload.songId }
    waitingReports.append(
      PlaybackReport(state: state, positionMs: positionMs, payload: payload))
    sendNextReport()
  }

  private static func saysUnsupported(_ error: Error) -> Bool {
    guard let error = error as? SubsonicError, error.code == 0 else { return false }
    let message = error.message?.lowercased() ?? ""
    return message.contains("not supported") || message.contains("not implemented")
      || message.contains("unknown")
  }

  private func sendNextReport() {
    guard !reportInFlight, !waitingReports.isEmpty else { return }
    // Nothing waits out a dead link: a report describes this moment only.
    guard ConnectivityMonitor.shared.canReachServer else {
      waitingReports = []
      return
    }
    let report = waitingReports.removeFirst()
    reportInFlight = true

    FloooService.shared.reportPlayback(
      mediaId: report.payload.songId, positionMs: report.positionMs, state: report.state
    ) { [weak self] result in
      guard let self else { return }
      self.reportInFlight = false

      // A server without the route answers 404, or a generic Subsonic error
      // saying so; Navidrome's own code 0 is an internal error and code 70
      // means this song is unknown to it.
      if case .failure(let error) = result, !self.reportPlaybackUnsupported,
        (error as? AFError)?.responseCode == 404 || Self.saysUnsupported(error)
      {
        debugLog("reportPlayback unsupported, now playing falls back to scrobble")
        self.reportPlaybackUnsupported = true
        self.waitingReports = []
        if report.state == .starting {
          self.processScrobble(submission: false, payload: report.payload)
        }
        return
      }
      if case .failure(let error) = result, (error as? SubsonicError)?.code == 70 {
        self.waitingReports.removeAll { $0.payload.songId == report.payload.songId }
      } else if case .failure(let error) = result, !(error is SubsonicError) {
        // The link is gone; the reports behind this one are stale already.
        self.waitingReports = []
      }
      self.sendNextReport()
    }
  }

  private func processScrobble(submission: Bool, payload: ScrobblePayload) {
    // Navidrome records every scrobble for its own play counts and forwards it
    // to Last.fm or ListenBrainz when the user linked them there, so the watch
    // always scrobbles to the server. A submission goes through the outbox, so
    // it survives the app being killed while the request is in flight.
    if submission {
      ScrobbleQueueManager.shared.enqueue(payload)
      return
    }

    guard ConnectivityMonitor.shared.canReachServer else { return }

    FloooService.shared.scrobbleToBuiltinEndpoint(
      submission: false, songId: payload.songId, time: payload.listenTime
    ) { result in
      if case .success = result {
        debugLog("scrobble delivered: \(payload.songId) submission=false")
      }
    }
  }
}
