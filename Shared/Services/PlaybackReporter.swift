//
//  PlaybackReporter.swift
//  Ownwave
//

import Alamofire
import Foundation

/// Tells the server what plays: playback states for its now playing list and
/// scrobbles, which a submission hands to the outbox.
final class PlaybackReporter {
  static let shared = PlaybackReporter()

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

  /// Hands a counted play to the outbox, so it survives the app being killed
  /// before the server has it. Navidrome records every scrobble for its own
  /// play counts and forwards it to Last.fm or ListenBrainz when the user
  /// linked them there. Main thread.
  func submit(_ nowPlaying: QueueEntity) {
    MainActor.assumeIsolated {
      guard let payload = ScrobblePayload(nowPlaying: nowPlaying) else { return }
      ScrobbleQueueManager.shared.enqueue(payload)
    }
  }

  /// Reports the song's playback state to the server's now playing list.
  /// Reports are never queued offline, a waiting one is replaced by a newer
  /// state of the same song, and playing is sent at most every 30 seconds.
  /// A server without reportPlayback gets a now playing scrobble for
  /// starting instead. Main thread.
  func reportPlayback(state: PlaybackReportState, nowPlaying: QueueEntity, positionSeconds: Double)
  {
    guard AuthService.shared.accountKey != nil,
      let payload = MainActor.assumeIsolated({ ScrobblePayload(nowPlaying: nowPlaying) })
    else { return }
    guard !reportPlaybackUnsupported else {
      if state == .starting { scrobbleNowPlaying(payload) }
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

    Task { @MainActor [weak self] in
      let result = await Result {
        try await ScrobbleAPI.shared.reportPlayback(
          mediaId: report.payload.songId, positionMs: report.positionMs, state: report.state)
      }
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
          self.scrobbleNowPlaying(report.payload)
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

  /// The now playing scrobble a server without reportPlayback gets instead;
  /// never queued.
  private func scrobbleNowPlaying(_ payload: ScrobblePayload) {
    guard ConnectivityMonitor.shared.canReachServer else { return }

    Task {
      if (try? await ScrobbleAPI.shared.scrobbleToBuiltinEndpoint(
        submission: false, songId: payload.songId, time: payload.listenTime)) != nil
      {
        debugLog("scrobble delivered: \(payload.songId) submission=false")
      }
    }
  }
}
