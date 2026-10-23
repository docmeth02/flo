//
//  CarPlayNowPlaying.swift
//  Ownwave
//

import CarPlay
import Combine

/// What Now Playing's buttons and album button show; they are rebuilt only
/// when it changes.
private struct NowPlayingButtons: Equatable {
  /// A song plays: neither live radio nor an empty queue.
  var isSong = false
  var hasAlbum = false
  var isStarred = false
  /// Rated 4 or 5.
  var isBoosted = false
}

/// The car's sheets and alerts, kept in the template's `userInfo` so one is
/// found again while it is presented.
private enum Modal {
  case rate, signedOut, streamingBlocked
}

// Now Playing's buttons, the Rate sheet and the alerts. CarPlay calls the
// observer on the main thread.
extension CarPlayController: @preconcurrency CPNowPlayingTemplateObserver {
  func startNowPlaying() {
    let template = CPNowPlayingTemplate.shared
    template.isUpNextButtonEnabled = true
    template.upNextTitle = "Up Next"
    template.add(self)
    // @Published sends before the value is set, so the state is read one
    // main-queue turn later.
    player.$isStarred.map { _ in () }
      .merge(
        with:
          RatingStore.shared.$ratings.map { _ in () },
        player.$queue.map { _ in () },
        player.$activeQueueIdx.map { _ in () }
      )
      .receive(on: DispatchQueue.main)
      .compactMap { [weak self] in self?.nowPlayingButtons }
      .removeDuplicates()
      .sink { [weak self] in self?.apply($0) }
      .store(in: &subscriptions)
  }

  func stopNowPlaying() {
    CPNowPlayingTemplate.shared.remove(self)
  }

  func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    openUpNext()
  }

  func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
    openAlbum(id: player.nowPlayingAlbumId)
  }

  private var nowPlayingButtons: NowPlayingButtons {
    guard let songId = player.nowPlayingId, !player.isLiveRadio else { return NowPlayingButtons() }
    return NowPlayingButtons(
      isSong: true,
      hasAlbum: !player.nowPlayingAlbumId.isEmpty,
      isStarred: player.isStarred,
      isBoosted: RatingStore.shared.rating(for: songId) >= 4)
  }

  /// Shuffle and repeat show what the player reports to the remote command
  /// center (the CPNowPlayingButton header): their `isSelected` is ignored,
  /// so only the image buttons set it. A tap that also arrives as a command
  /// would show as a `carplay: button` line next to an `audio remote` one.
  private func apply(_ state: NowPlayingButtons) {
    let template = CPNowPlayingTemplate.shared
    template.isAlbumArtistButtonEnabled = state.hasAlbum
    let player = player
    let playSomething = CPNowPlayingImageButton(image: symbol("sparkles")) { _ in
      Task { _ = await player.playSomething() }
    }
    guard state.isSong else { return template.updateNowPlayingButtons([playSomething]) }
    let heartImage = symbol(state.isStarred ? "heart.fill" : "heart")
    let heart = CPNowPlayingImageButton(image: heartImage) { _ in player.toggleStar() }
    heart.isSelected = state.isStarred
    let starImage = symbol(state.isBoosted ? "star.fill" : "star")
    let rate = CPNowPlayingImageButton(image: starImage) { [weak self] _ in self?.presentRate() }
    template.updateNowPlayingButtons([
      CPNowPlayingShuffleButton { _ in
        RequestLog.shared.note("carplay: button shuffle")
        player.setShuffle(!player.isShuffling)
      },
      CPNowPlayingRepeatButton { _ in
        RequestLog.shared.note("carplay: button repeat")
        player.cyclePlaybackMode()
      },
      heart, rate, playSomething,
    ])
  }

  /// The car recolors the symbol; an empty image shows its placeholder.
  private func symbol(_ name: String) -> UIImage {
    UIImage(systemName: name) ?? UIImage()
  }

  // MARK: - Sheets and alerts

  /// Boost, Avoid or clear the playing song's rating; nothing while no song
  /// plays. Avoid skips the song through the engine.
  func presentRate() {
    guard let song = player.nowPlaying, let songId = song.id, !player.isLiveRadio else { return }
    let player = player
    let rate = { [weak self] (title: String, style: CPAlertAction.Style, rating: Int) in
      CPAlertAction(title: title, style: style) { _ in
        // A song change while the sheet was open leaves the new song alone.
        if player.isCurrentTrack(songId) { player.rateNowPlaying(rating) }
        self?.dismiss(.rate)
      }
    }
    var actions = [rate("Boost", .default, 5), rate("Avoid", .destructive, 1)]
    if RatingStore.shared.rating(for: songId) > 0 {
      actions.append(rate("Clear Rating", .default, 0))
    }
    actions.append(
      CPAlertAction(title: "Cancel", style: .cancel) { [weak self] _ in
        self?.dismiss(.rate)
      })
    let sheet = CPActionSheetTemplate(
      title: "Rate \(song.songName ?? "")",
      message: "Boosted songs come up more often. Avoided songs stay out of every mix.",
      actions: actions)
    present(sheet, as: .rate)
  }

  /// The signed-out alert while the phone has no login, the cellular one
  /// whenever the player stops for blocked streaming. Each goes away by
  /// itself once its reason does.
  func observeSession() {
    app.auth.$isLoggedIn.removeDuplicates()
      .sink { [weak self] isLoggedIn in
        guard let self else { return }
        if isLoggedIn { return dismiss(.signedOut) }
        // The lists pushed and the stations were the previous account's.
        interfaceController.popToRootTemplate(animated: false, completion: nil)
        radios.radios = []
        presentSignedOut()
      }
      .store(in: &subscriptions)
    player.$isStreamingBlocked.removeDuplicates()
      .sink { [weak self] isBlocked in
        if isBlocked { self?.presentStreamingBlocked() } else { self?.dismiss(.streamingBlocked) }
      }
      .store(in: &subscriptions)
  }

  func presentSignedOut() {
    let ok = CPAlertAction(title: "OK", style: .default) { [weak self] _ in
      self?.dismiss(.signedOut)
    }
    let alert = CPAlertTemplate(
      titleVariants: [
        "Sign in on your iPhone to play your Navidrome library", "Sign in on your iPhone",
      ],
      actions: [ok])
    present(alert, as: .signedOut)
  }

  /// Offers the songs on the phone; the mix takes only those while streaming
  /// is blocked.
  func presentStreamingBlocked() {
    let playDownloads = CPAlertAction(title: "Play Downloads", style: .default) { [weak self] _ in
      self?.dismiss(.streamingBlocked)
      Task { [weak self] in
        guard await self?.player.playSomething() == true else { return }
        self?.showNowPlaying()
      }
    }
    let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
      self?.dismiss(.streamingBlocked)
    }
    // Past the limit the car keeps the last actions; Play Downloads matters
    // more than OK, since it closes the alert too.
    let actions = [playDownloads, ok].prefix(Int(CPAlertTemplate.maximumActionCount))
    let alert = CPAlertTemplate(
      titleVariants: ["Streaming on cellular is off"], actions: Array(actions))
    present(alert, as: .streamingBlocked)
  }

  /// The car shows one modal template at a time. The newest replaces the one
  /// presented, since it answers what just happened; the same kind again is
  /// left as it is.
  private func present(_ template: CPTemplate, as modal: Modal) {
    template.userInfo = modal
    let show: () -> Void = { [weak self] in
      self?.interfaceController.presentTemplate(template, animated: true) { _, error in
        if let error {
          RequestLog.shared.note("carplay: present failed: \(error.localizedDescription)")
        }
      }
    }
    guard let presented = interfaceController.presentedTemplate else { return show() }
    guard presented.userInfo as? Modal != modal else { return }
    interfaceController.dismissTemplate(animated: false) { _, _ in show() }
  }

  /// Dismisses `modal` while it is the presented template.
  private func dismiss(_ modal: Modal) {
    guard interfaceController.presentedTemplate?.userInfo as? Modal == modal else { return }
    interfaceController.dismissTemplate(animated: true, completion: nil)
  }
}
