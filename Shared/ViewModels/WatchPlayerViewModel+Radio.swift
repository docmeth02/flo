//
//  WatchPlayerViewModel+Radio.swift
//  flo
//

import AVFoundation

// Live radio stations.
extension WatchPlayerViewModel {
  /// Reconnects a failed radio station to its own stream URL; the song
  /// stream endpoint knows nothing about stations.
  func reloadRadioItem() {
    guard let radioURL = radioURL else { return }
    tearDownItemObservers()
    attachRadioItem(radioURL)
  }

  private func attachRadioItem(_ url: URL) {
    replacePlayerIfFailed()
    playerItem = AVPlayerItem(url: url)
    player?.replaceCurrentItem(with: playerItem)
    observeItemStatus(trackId: nowPlayingId)
    addPeriodicTimeObserver()
  }

  @discardableResult
  func playRadioItem(radio: Radio) -> Bool {
    guard let radioUrl = Self.normalizedRadioURL(from: radio.streamUrl) else {
      return false
    }
    beginUserStart()
    endConnectionWait(because: "radio")

    let item = radio.toPlayable()
    let queue = PlaybackService.shared.addToQueue(item: item)
    guard !queue.isEmpty else { return false }

    self.activeQueueIdx = 0
    self.queue = queue
    self.hasQualified = false

    // A queued end notification from the previous track must not advance the
    // radio queue; live streams have no track end.
    detachItem()

    self.radioURL = radioUrl
    attachRadioItem(radioUrl)

    self.isMediaLoading = true
    self.isMediaFailed = false
    self.totalDuration = self.nowPlaying.duration
    self.progress = 0.0
    self.currentTimeString = "00:00"

    self.play()

    self.publishNowPlaying(title: item.name, artist: nowPlaying.artistName ?? "", duration: 0)
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.nowPlayingProgress)
    return true
  }

  /// The station's URL as given, else percent-encoded, else either with https
  /// in front; a stream needs a scheme and a host.
  private static func normalizedRadioURL(from streamUrl: String) -> URL? {
    let trimmed = streamUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    for base in [trimmed, "https://\(trimmed)"] {
      let encoded = base.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed)
      for text in [base, encoded].compactMap({ $0 }) {
        if let url = URL(string: text), url.scheme != nil, url.host != nil { return url }
      }
    }
    return nil
  }
}
