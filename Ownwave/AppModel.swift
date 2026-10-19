//
//  AppModel.swift
//  Ownwave
//

import SwiftUI

/// Owns the view models for the app's whole life, so intents and widgets can
/// reach the player without a view, and the state every screen shares: the
/// Now Playing cover, the toast and the first-run tour.
@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  let auth = AuthViewModel()
  let player = PlayerViewModel()
  let albums = AlbumViewModel()

  @Published var isNowPlayingPresented = false
  @Published private(set) var toast: Toast?
  /// The first-run tour's step on screen; nil while no tour runs. The tabs
  /// take the tour to each step's screen.
  @Published var tour: TourStep?

  struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let undo: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
  }

  private var toastDismissal: Task<Void, Never>?

  private init() {
    // A logout ends a tour; `tourSeen` is only set at its end, so it starts
    // over after the next login instead of halfway.
    Self.onLogout { AppModel.shared.tour = nil }
  }

  /// Runs `action` on the main actor after every logout.
  static func onLogout(_ action: @escaping @MainActor () -> Void) {
    NotificationCenter.default.addObserver(forName: .didLogout, object: nil, queue: .main) { _ in
      Task { @MainActor in action() }
    }
  }

  /// Shows `text` at the bottom for a few seconds, with Undo when given.
  func show(_ text: String, undo: (() -> Void)? = nil) {
    let toast = Toast(text: text, undo: undo)
    self.toast = toast
    toastDismissal?.cancel()
    toastDismissal = Task {
      try? await Task.sleep(for: .seconds(3.8))
      guard !Task.isCancelled, self.toast == toast else { return }
      self.toast = nil
    }
  }

  func dismissToast() {
    toastDismissal?.cancel()
    toast = nil
  }

  /// The liked songs as last listed, less those unliked since, which leave
  /// at once. Views showing them observe StarStore for those changes.
  var likedSongs: [Song] { albums.starredSongs.filter { player.isStarred($0) } }

  /// The album's whole track list from the server: an album screen may show
  /// only the songs downloaded here. Without the server, the songs known.
  func songs(of album: Album) async -> [Song] {
    guard ConnectivityMonitor.shared.canReachServer else { return album.songs }
    let fetched = await withCheckedContinuation { continuation in
      AlbumService.shared.getSongFromAlbum(id: album.id) { continuation.resume(returning: $0) }
    }
    return (try? fetched.get()) ?? album.songs
  }

  /// Downloads the songs of an album the phone does not have yet.
  func download(_ album: Album) {
    var album = album
    let account = AuthService.shared.accountKey
    Task {
      album.songs = await songs(of: album)
      // A logout meanwhile: these are the previous account's songs.
      guard AuthService.shared.accountKey == account else { return }
      guard !album.songs.isEmpty else { return show("Not available offline") }
      let onPhone = AlbumService.shared.downloadedMediaFileIds(collectionId: album.id)
      guard album.songs.contains(where: { !onPhone.contains($0.playbackID) }) else {
        return show("Already on this iPhone")
      }
      DownloadSession.shared.enqueue(album)
      let bitRate = UserDefaultsManager.downloadBitRate
      if AppPlatform.isOnCellular, !UserDefaultsManager.downloadOverCellular {
        show("Downloads when on Wi-Fi")
      } else {
        show(
          bitRate == TranscodingSettings.sourceBitRate
            ? "Downloading in original quality" : "Downloading at \(bitRate) kbps")
      }
    }
  }

  // MARK: - Playing

  // Each shows the player once something plays.

  func play(_ item: some Playable, startingAt index: Int = 0) {
    if player.playItem(item: item, startingAt: index) { isNowPlayingPresented = true }
  }

  func shuffle(_ item: some Playable) {
    if player.shuffleItem(item: item) { isNowPlayingPresented = true }
  }

  func playSomething() async {
    if await player.playSomething() { isNowPlayingPresented = true }
  }

  /// Top songs online, else the artist's songs on the phone.
  func playArtist(id: String, name: String) async {
    if await player.playArtist(id: id, name: name) { isNowPlayingPresented = true }
  }

  /// A station is a live stream, so nothing plays while streaming is off on
  /// cellular.
  func play(_ radio: Radio) {
    guard TranscodingSettings.streamingBitRate != nil else {
      return show("Streaming on cellular is off")
    }
    if player.playRadioItem(radio: radio) { isNowPlayingPresented = true }
  }

  /// Plays what Siri, Shortcuts or the Action Button asked for. Logged out,
  /// the request is dropped.
  func takePlayRequest() {
    guard let request = PlayRequest.take(), auth.isLoggedIn else { return }
    Task {
      switch request {
      case .something: await playSomething()
      case .artist(let id, let name): await playArtist(id: id, name: name)
      }
    }
  }
}
