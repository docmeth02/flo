//
//  StreamSources.swift
//  Ownwave
//

import Alamofire
import Foundation

/// Where a remote song streams from: a server-decided direct play or
/// transcode (getTranscodeStream).
struct StreamSource {
  let endpoint: String
  let parameters: [String: Any]
  let suffix: String
  /// A decided transcode, which starts at the requested offset. A direct play
  /// starts at 0 and is seeked by the client.
  let isTranscoded: Bool

  var url: String { subsonicURL(endpoint: endpoint, parameters: parameters) }
}

/// Why no stream could be set up for a song.
enum StreamSourceFailure: Error, Equatable {
  /// The network or the server is away for now; the song itself may be fine.
  case unavailable
  /// The server says this song cannot be streamed.
  case unplayable
  /// Streaming is switched off on this network.
  case blocked
}

/// How a failed transcode decision request is handled.
enum DecisionFailure: Error, Equatable {
  /// A hiccup on the way to the server: asked once more, then `.unavailable`.
  case transient
  case unavailable
  case unplayable

  /// Sorts a failed request by its HTTP status (nil without an answer), the
  /// URL loading error and whether the body carried a Subsonic error.
  static func classify(status: Int?, error: Error?, subsonicError: Bool) -> DecisionFailure {
    if subsonicError { return .unplayable }
    if let status {
      return [408, 429, 500, 502, 503, 504].contains(status) ? .transient : .unavailable
    }
    return ConnectivityMonitor.isConnectionError(error) ? .transient : .unavailable
  }

  var streamFailure: StreamSourceFailure { self == .unplayable ? .unplayable : .unavailable }
}

/// How remote songs stream, as the server decides it per song and bitrate.
class StreamSources {
  static let shared = StreamSources()

  // Usable transcode decisions per song and bitrate setting. The Task is
  // cached so the player, the prefetch and the pre-cache share one request
  // and its retry. Main actor only.
  private var transcodeDecisions:
    [String: (task: Task<Result<TranscodeDecision, DecisionFailure>, Never>, at: Date)] = [:]
  // The token is signed for 48 hours.
  private static let decisionLifetime: TimeInterval = 24 * 3600

  private init() {
    NotificationCenter.default.addObserver(
      forName: .didLogout, object: nil, queue: .main
    ) { [weak self] _ in
      // A pending request must not retry for the next account.
      self?.transcodeDecisions.values.forEach { $0.task.cancel() }
      self?.transcodeDecisions = [:]
    }
  }

  /// How to stream a song from the server, as the server decides it.
  /// `offset` (seconds) only applies to a transcode.
  @MainActor func resolveStreamSource(songId: String, originalSuffix: String?, offset: Int) async
    -> Result<StreamSource, StreamSourceFailure>
  {
    guard let bitRate = TranscodingSettings.streamingBitRate else { return .failure(.blocked) }
    let kbps = Int(bitRate) ?? 0
    // Asked even while the monitor says the server is away: its verdict can
    // be stale, and the request is bounded.
    switch await transcodeDecision(songId: songId, kbps: kbps) {
    case .failure(let failure):
      return .failure(failure.streamFailure)
    case .success(let decision):
      guard
        let source = Self.streamSource(
          decision, songId: songId, originalSuffix: originalSuffix, offset: offset)
      else { return .failure(.unplayable) }
      return .success(source)
    }
  }

  /// Asks for the next song's decision ahead of time. Main thread.
  func prefetchTranscodeDecision(songId: String) {
    guard ConnectivityMonitor.shared.isServerReachable,
      DownloadStore.localFileURL(mediaFileId: songId) == nil,
      let bitRate = TranscodingSettings.streamingBitRate
    else { return }
    let kbps = Int(bitRate) ?? 0
    Task { @MainActor in _ = await transcodeDecision(songId: songId, kbps: kbps) }
  }

  /// Drops a song's decision, whose token the server may no longer accept.
  /// Main thread.
  func forgetTranscodeDecision(songId: String) {
    transcodeDecisions = transcodeDecisions.filter { !$0.key.hasPrefix("\(songId)_") }
  }

  private static func rawSuffix(_ originalSuffix: String?) -> String {
    guard let originalSuffix, !originalSuffix.isEmpty else {
      return TranscodingSettings.sourceFormat
    }
    return originalSuffix
  }

  /// The stream a decision allows, the original file first; nil when it
  /// allows none.
  private static func streamSource(
    _ decision: TranscodeDecision, songId: String, originalSuffix: String?, offset: Int
  ) -> StreamSource? {
    guard let token = decision.transcodeParams, !token.isEmpty else { return nil }
    // Never estimateContentLength: the estimate ignores the offset.
    var parameters: [String: Any] = [
      "mediaId": songId, "mediaType": "song", "transcodeParams": token,
    ]
    if decision.canDirectPlay == true {
      return StreamSource(
        endpoint: API.SubsonicEndpoint.getTranscodeStream, parameters: parameters,
        suffix: decision.sourceStream?.container ?? rawSuffix(originalSuffix),
        isTranscoded: false)
    }
    guard decision.canTranscode == true, let stream = decision.transcodeStream else { return nil }
    if offset > 0 { parameters["offset"] = offset }
    return StreamSource(
      endpoint: API.SubsonicEndpoint.getTranscodeStream, parameters: parameters,
      suffix: stream.container ?? TranscodingSettings.targetFormat, isTranscoded: true)
  }

  @MainActor private func transcodeDecision(songId: String, kbps: Int) async
    -> Result<TranscodeDecision, DecisionFailure>
  {
    guard !songId.isEmpty else { return .failure(.unplayable) }
    let key = "\(songId)_\(kbps)"

    if let cached = transcodeDecisions[key],
      Date().timeIntervalSince(cached.at) < Self.decisionLifetime
    {
      return await cached.task.value
    }

    let task = Task { () -> Result<TranscodeDecision, DecisionFailure> in
      let first = await self.fetchTranscodeDecision(songId: songId, kbps: kbps)
      guard case .failure(.transient) = first else { return first }
      // Once more after a short pause, unless a logout cancelled the task.
      guard (try? await Task.sleep(for: .seconds(1))) != nil else { return first }
      RequestLog.shared.note("transcode decision retry \(songId)")
      return await self.fetchTranscodeDecision(songId: songId, kbps: kbps)
    }
    transcodeDecisions[key] = (task, Date())
    let result = await task.value
    // A failed request is asked again next time.
    if case .failure = result, transcodeDecisions[key]?.task == task {
      transcodeDecisions[key] = nil
    }
    return result
  }

  /// One decision request of at most 10 s. A decision that allows no stream
  /// counts as `.unplayable`.
  @MainActor private func fetchTranscodeDecision(songId: String, kbps: Int) async
    -> Result<TranscodeDecision, DecisionFailure>
  {
    let url = subsonicURL(
      endpoint: API.SubsonicEndpoint.getTranscodeDecision,
      parameters: ["mediaId": songId, "mediaType": "song"])

    let response = await APIManager.shared.session.request(
      url, method: .post, parameters: TranscodeClientInfo(maxBitRateKbps: kbps),
      encoder: JSONParameterEncoder.default, requestModifier: { $0.timeoutInterval = 10 }
    )
    .validate(statusCode: 200..<300)
    .serializingDecodable(SubsonicEnvelope<TranscodeDecision>.self).response

    let underlyingError = response.error?.underlyingError
    ConnectivityMonitor.shared.record(response: response.response, error: underlyingError)

    let subsonicError = response.value?.subsonicResponse.error
    if let error = subsonicError {
      // A failed decision (ffprobe on a damaged file, a database hiccup)
      // concerns this song only.
      debugLog("transcode decision for \(songId) failed: \(error.code) \(error.message ?? "")")
    }
    guard let decision = response.value?.subsonicResponse.data, subsonicError == nil else {
      return .failure(
        DecisionFailure.classify(
          status: response.response?.statusCode, error: underlyingError,
          subsonicError: subsonicError != nil))
    }
    guard
      Self.streamSource(decision, songId: songId, originalSuffix: nil, offset: 0) != nil
    else {
      debugLog("transcode decision for \(songId) allows no stream: \(decision.errorReason ?? "")")
      return .failure(.unplayable)
    }
    return .success(decision)
  }
}
