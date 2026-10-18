//
//  PlayerViewModel+AudioSession.swift
//  flo
//

import AVFoundation
import Combine

// Interruptions, route changes and the start the output setup may interrupt.
extension PlayerViewModel {
  func observeInterruptionNotifications() {
    NotificationCenter.default
      .publisher(for: AVAudioSession.interruptionNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        self?.handleInterruptionNotification(notification)
      }
      .store(in: &interruptionObservation)

    // The system pauses the player when the headphones go away; the controls
    // and the server have to follow, or the next tap pauses again.
    NotificationCenter.default
      .publisher(for: AVAudioSession.routeChangeNotification)
      .receive(on: DispatchQueue.main)
      .sink { [weak self] notification in
        guard let self,
          let value = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: value)
        else { return }
        let previous = (notification.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
          as? AVAudioSessionRouteDescription)?.outputs.map(\.portType.rawValue)
          .joined(separator: ",") ?? "-"
        RequestLog.shared.note(
          "audio route \(reason.rawValue) outputs=\(Self.routeOutputs) previous=\(previous)")

        // Part of the output setup that interrupted the start, the speaker
        // giving way to the headphones included. Headphones taken off end it.
        if self.settleWork != nil, reason != .oldDeviceUnavailable {
          self.armSettle()
          return
        }
        guard reason == .oldDeviceUnavailable else { return }
        // Headphones lost during a call: its end must not restart music
        // nobody hears.
        self.resumeAfterInterruption = false
        guard self.isPlaying else { return }
        self.pause()
      }
      .store(in: &interruptionObservation)
  }

  static var routeOutputs: String {
    AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType.rawValue)
      .joined(separator: ",")
  }

  private static var hasOutput: Bool {
    !AVAudioSession.sharedInstance().currentRoute.outputs.isEmpty
  }

  /// (Re)starts the wait for the output setup to go quiet.
  func armSettle() {
    settleWork?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.resumeAfterSettle() }
    settleWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
  }

  /// Starts an interrupted start again once nothing changed for
  /// `settleDelay`, if there is an output to play to and no activation is
  /// still under way. Without an output it waits another round, as often as
  /// it may resume, then shows Play.
  private func resumeAfterSettle() {
    settleWork = nil
    // An activation still under way answers first; a second one on top of it
    // would discard it. Not logged: the wait can last as long as the device
    // list is up.
    if pendingStart?.isActivating == true, resumeAfterInterruption {
      armSettle()
      return
    }
    RequestLog.shared.note(
      "audio settled resume=\(resumeAfterInterruption) playing=\(isPlaying)"
        + " outputs=\(Self.routeOutputs)")
    guard resumeAfterInterruption, let start = pendingStart,
      isPlaying || start.interruptedWhileActivating, player?.timeControlStatus != .playing
    else { return }
    guard start.resumes < Self.maxSettleResumes else {
      pause()
      // Like the cap in .began: a real interruption's end may still resume it.
      resumeAfterInterruption = true
      return
    }
    pendingStart?.resumes += 1
    guard Self.hasOutput else {
      armSettle()
      return
    }
    // play() begins a fresh start; this one carries on with its count and
    // its interruption, only its activation is new.
    let carried = pendingStart
    play()
    pendingStart = carried
    pendingStart?.isActivating = true
  }

  /// A pause, or a logout, ends a start and anything waiting to resume it.
  func endStart() {
    pendingStart = nil
    cancelSettle()
    resumeAfterInterruption = false
  }

  func cancelSettle() {
    settleWork?.cancel()
    settleWork = nil
  }

  /// Counts what a start has played; once it was heard, interruptions are
  /// treated as calls again.
  func countStartPlayed(_ step: Double) {
    guard pendingStart != nil else { return }
    pendingStart?.played += step
    guard let start = pendingStart, start.played >= Self.startHeardAfter, Self.hasOutput
    else { return }
    RequestLog.shared.note(
      "audio start heard resumes=\(start.resumes) outputs=\(Self.routeOutputs)")
    pendingStart = nil
  }

  private func handleInterruptionNotification(_ notification: Notification) {
    guard let userInfo = notification.userInfo,
      let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? Int,
      let type = AVAudioSession.InterruptionType(rawValue: UInt(typeValue))
    else {
      return
    }

    switch type {
    case .began:
      let session = AVAudioSession.sharedInstance()
      let reason = (userInfo[AVAudioSessionInterruptionReasonKey] as? UInt).map(String.init) ?? "-"
      let options = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt).map(String.init) ?? "-"
      RequestLog.shared.note(
        "audio interruption began reason=\(reason) options=\(options) playing=\(isPlaying)"
          + " start=\(pendingStart.map { "\($0.resumes)" } ?? "none") outputs=\(Self.routeOutputs)"
          + " otherAudio=\(session.isOtherAudioPlaying)"
          + " silenceHint=\(session.secondaryAudioShouldBeSilencedHint)")
      // The system already paused the player; the start stays wanted.
      if AppPlatform.keepsStartThroughInterruptions, let start = pendingStart,
        isPlaying || start.isActivating, start.resumes < Self.maxSettleResumes
      {
        if !isPlaying { pendingStart?.interruptedWhileActivating = true }
        loadWatchdog?.cancel()
        resumeAfterInterruption = true
        armSettle()
        return
      }
      // Through pause() so a pending skip or Keep Playing mix does not start
      // playback during the call.
      let wasPlaying = isPlaying
      pause()
      resumeAfterInterruption = wasPlaying
    case .ended:
      RequestLog.shared.note("audio interruption ended resume=\(resumeAfterInterruption)")
      // Music the user had paused before the call stays paused.
      let wasPlaying = self.resumeAfterInterruption
      self.resumeAfterInterruption = false
      if wasPlaying, let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? Int {
        let options = AVAudioSession.InterruptionOptions(rawValue: UInt(optionsValue))
        if options.contains(.shouldResume) {
          self.play()
          return
        }
      }
      // A start kept through the interruption stays paused when its end asks
      // not to resume, one kept while still activating too.
      if (isPlaying && player?.timeControlStatus != .playing)
        || (wasPlaying && pendingStart?.isActivating == true)
      {
        pause()
      }
    @unknown default:
      break
    }
  }
}
