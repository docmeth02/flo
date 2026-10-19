//
//  PlayerViewModel+NowPlayingInfo.swift
//  flo
//

import MediaPlayer
import UIKit

// The heart, the system's Now Playing info and the remote commands.
extension PlayerViewModel {
  /// Asks the server whether the current song is starred; a refresh asks
  /// again only when the song change's lookup failed.
  @MainActor func loadStarred(refresh: Bool = false) {
    if !refresh {
      serverStarred = false
      starLookupFailed = false
      updateHeart()
    } else if !starLookupFailed {
      return
    }
    guard hasNowPlaying(), let songId = nowPlaying.id, !songId.isEmpty else { return }
    starLookup += 1
    let lookup = starLookup
    // Offline the lookup could only time out; it counts as failed, so the
    // next play() asks again. Until the first verdict the monitor assumes the
    // server answers.
    ConnectivityMonitor.shared.onFirstVerdict { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.starLookup == lookup, self.isCurrentTrack(songId) else { return }
        guard ConnectivityMonitor.shared.canReachServer else {
          self.starLookupFailed = true
          return
        }
        self.requestStarred(songId, lookup: lookup)
      }
    }
  }

  @MainActor private func requestStarred(_ songId: String, lookup: Int) {
    // Adopted only if no edit was waiting or made meanwhile: an edit being
    // sent can reach the server after it answered this lookup.
    let canAdopt = !StarStore.shared.isPending(songId)
    let edits = StarStore.shared.editCount
    AlbumService.shared.isStarred(songId: songId) { [weak self] starred in
      Task { @MainActor in
        // A newer lookup, another song or a cleared queue (logout) meanwhile.
        guard let self, self.starLookup == lookup, self.isCurrentTrack(songId) else { return }
        self.serverStarred = starred ?? false
        self.starLookupFailed = starred == nil
        if let starred, canAdopt, StarStore.shared.editCount == edits {
          StarStore.shared.adoptServerState(starred, id: songId)
        }
        self.updateHeart()
      }
    }
  }

  /// Runs on every StarStore change, also with an empty queue.
  @MainActor func updateHeart() {
    let songId = nowPlayingId ?? ""
    let starred = !songId.isEmpty && StarStore.shared.isStarred(songId, listed: serverStarred)
    if starred != isStarred { isStarred = starred }
  }

  /// Publishes the current song's cover for the player, and its title,
  /// artist, duration and artwork for the system's Now Playing.
  func publishNowPlaying(title: String, artist: String, duration: Double) {
    // The text goes out at once; the artwork may have to be fetched.
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
    nowPlayingInfo[MPMediaItemPropertyTitle] = title
    nowPlayingInfo[MPMediaItemPropertyArtist] = artist
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
    MainActor.assumeIsolated {
      updateRatingCommands()
      // A song change after something played; play() sets the first one.
      if NowPlayingTarget.current != nil { publishSiriTarget() }
    }

    coverArt = AlbumService.shared.coverURL(albumId: nowPlayingAlbumId)
    if coverArt.hasPrefix("/") {
      if let image = UIImage(contentsOfFile: coverArt) { Self.setArtwork(image) }
    } else if let albumId = nowPlaying.albumId {
      let trackId = nowPlaying.id
      Task { @MainActor [weak self] in
        // Shares the cover cache's single download with the album art views,
        // and only for the song still playing.
        guard let path = await CoverArtCacheManager.shared.coverPath(albumId: albumId),
          let image = UIImage(contentsOfFile: path), let self, self.isCurrentTrack(trackId)
        else { return }
        Self.setArtwork(image)
      }
    }
  }

  /// What "this song" means to Siri: the song in the player, nil for none.
  @MainActor func publishSiriTarget() {
    NowPlayingTarget.publish(hasNowPlaying() ? nowPlaying : nil, isLiveRadio: isLiveRadio)
  }

  private static func setArtwork(_ image: UIImage) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()
    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  func updateNowPlayingInfo(progress: TimeInterval, rate: Float) {
    var nowPlayingInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [String: Any]()

    // A station has no length to show a position in.
    let isFinite = totalDuration.isFinite
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] =
      isFinite ? progress * totalDuration : nil
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = isFinite ? totalDuration : nil
    nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = rate

    MPNowPlayingInfoCenter.default().nowPlayingInfo = nowPlayingInfo
  }

  func setupRemoteCommandCenter() {
    let commandCenter = MPRemoteCommandCenter.shared()

    // Remote commands can arrive off the main thread; every handler hops to
    // main before touching playback or published state.
    commandCenter.playCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      Task { @MainActor in
        RequestLog.shared.note("audio remote play playing=\(self.isPlaying)")
        self.play()
      }
      return .success
    }

    commandCenter.pauseCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      Task { @MainActor in
        RequestLog.shared.note("audio remote pause playing=\(self.isPlaying)")
        self.pause()
      }
      return .success
    }

    commandCenter.nextTrackCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      Task { @MainActor in self.nextSong(userInitiated: true) }
      return .success
    }

    commandCenter.previousTrackCommand.addTarget { [weak self] _ in
      guard let self = self else { return .commandFailed }
      Task { @MainActor in self.prevSong() }
      return .success
    }

    commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent
      else { return .commandFailed }
      let positionTime = event.positionTime
      Task { @MainActor in
        guard !self.isLiveRadio, self.totalDuration > 0 else { return }
        self.seek(to: positionTime / self.totalDuration)
      }
      return .success
    }

    // Like and dislike stand for Boost and Avoid; pressing the active one
    // clears the rating.
    commandCenter.likeCommand.localizedTitle = "Boost"
    commandCenter.likeCommand.localizedShortTitle = "Boost"
    commandCenter.likeCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self, self.hasNowPlaying() else { return }
        let rating = RatingStore.shared.rating(for: self.nowPlaying.id ?? "")
        self.rateNowPlaying(rating >= 4 ? 0 : 5)
      }
      return .success
    }

    commandCenter.dislikeCommand.localizedTitle = "Avoid in Smart Shuffle"
    commandCenter.dislikeCommand.localizedShortTitle = "Avoid"
    commandCenter.dislikeCommand.addTarget { [weak self] _ in
      Task { @MainActor in
        guard let self, self.hasNowPlaying() else { return }
        let rating = RatingStore.shared.rating(for: self.nowPlaying.id ?? "")
        self.rateNowPlaying((1...2).contains(rating) ? 0 : 1)
      }
      return .success
    }
  }

  /// Rates the now playing song, from the player's stars or the remote like
  /// and dislike; 0 clears the rating.
  @MainActor func rateNowPlaying(_ rating: Int) {
    guard hasNowPlaying(), !isLiveRadio else { return }
    RatingStore.shared.set(rating, for: nowPlaying)
  }

  @MainActor func updateRatingCommands() {
    let commandCenter = MPRemoteCommandCenter.shared()
    let isRateable = hasNowPlaying() && !isLiveRadio
    let rating = isRateable ? RatingStore.shared.rating(for: nowPlaying.id ?? "") : 0
    commandCenter.likeCommand.isEnabled = isRateable
    commandCenter.dislikeCommand.isEnabled = isRateable
    commandCenter.likeCommand.isActive = rating >= 4
    commandCenter.dislikeCommand.isActive = (1...2).contains(rating)
    debugLog(
      "rating commands: rating=\(rating) like=\(commandCenter.likeCommand.isActive) "
        + "dislike=\(commandCenter.dislikeCommand.isActive)")
  }

  @MainActor func toggleStar() {
    guard hasNowPlaying(), let songId = nowPlaying.id, !songId.isEmpty else { return }
    StarStore.shared.setSong(!isStarred, id: songId)
  }

  /// Whether a listed song is liked: the heart for the song playing, else
  /// StarStore over the state it was listed with.
  @MainActor func isStarred(_ song: Song) -> Bool {
    if isCurrent(song) { return isStarred }
    return StarStore.shared.isStarred(
      song.playbackID, listed: song.starred || song.starredAt != nil)
  }
}
