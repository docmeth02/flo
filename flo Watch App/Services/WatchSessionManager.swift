//
//  WatchSessionManager.swift
//  flo Watch App
//

import Foundation
import WatchKit

class WatchSessionManager: NSObject, ObservableObject, WKExtendedRuntimeSessionDelegate {
  static let shared = WatchSessionManager()

  private var session: WKExtendedRuntimeSession?

  @Published var isSessionActive = false

  func startSession() {
    guard session == nil || session?.state == .invalid else { return }

    session = WKExtendedRuntimeSession()
    session?.delegate = self
    session?.start()
  }

  func invalidateSession() {
    session?.invalidate()
    session = nil
    isSessionActive = false
  }

  // MARK: - WKExtendedRuntimeSessionDelegate

  func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
    DispatchQueue.main.async {
      self.isSessionActive = true
    }
  }

  func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
    // Session is about to expire, restart it if still playing
    DispatchQueue.main.async {
      self.session = nil
      self.startSession()
    }
  }

  func extendedRuntimeSession(
    _ extendedRuntimeSession: WKExtendedRuntimeSession,
    didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?
  ) {
    DispatchQueue.main.async {
      self.isSessionActive = false
      self.session = nil
    }
  }
}
