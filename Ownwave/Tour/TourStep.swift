//
//  TourStep.swift
//  Ownwave
//

import Foundation

/// The first-run tour's six steps, each pointing at one element of the app.
enum TourStep: Int, CaseIterable {
  case play, rate, why, peek, taste, send

  var title: String {
    switch self {
    case .play: "Play Something"
    case .rate: "Rate as you listen"
    case .why: "Why this song"
    case .peek: "Up Next"
    case .taste: "Your Taste"
    case .send: "Send music to the watch"
    }
  }

  var text: String {
    switch self {
    case .play:
      "One tap starts a smart mix built from your listening history. Siri, the Action button and the watch start the same mix."
    case .rate:
      "One star keeps a song out of every mix. Five stars brings it up more often."
    case .why: "Each song in a smart mix shows why it was picked."
    case .peek: "Pull up past the player to see and edit the queue."
    case .taste:
      "What Play Something learns from: 60 days of plays, likes, ratings and skips. It lives on your server, so the watch uses the same taste. Anything here can be undone."
    case .send:
      "Albums download on this iPhone over fast Wi-Fi, then move to the watch in the background. You can sign the watch in from here too, without typing on the wrist."
    }
  }

  /// The steps whose element is on Now Playing, which covers the tabs.
  var isOnNowPlaying: Bool { self == .rate || self == .why || self == .peek }

  var next: TourStep? { TourStep(rawValue: rawValue + 1) }
}
