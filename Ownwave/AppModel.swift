//
//  AppModel.swift
//  Ownwave
//

import SwiftUI

/// Owns the view models for the app's whole life, so intents and widgets can
/// reach the player without a view, and the state every screen shares: the
/// Now Playing cover and the toast.
@MainActor
final class AppModel: ObservableObject {
  static let shared = AppModel()

  let auth = AuthViewModel()
  let player = PlayerViewModel()
  let albums = AlbumViewModel()
  let downloads = DownloadViewModel()

  @Published var isNowPlayingPresented = false
  @Published private(set) var toast: Toast?

  struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let undo: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
  }

  private var toastDismissal: Task<Void, Never>?

  private init() {}

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

  /// The album's songs; an album listed without them asks the server.
  func songs(of album: Album) async -> [Song] {
    guard album.songs.isEmpty else { return album.songs }
    return await withCheckedContinuation { continuation in
      AlbumService.shared.getSongFromAlbum(id: album.id) {
        continuation.resume(returning: (try? $0.get()) ?? [])
      }
    }
  }

  /// Downloads an album to the phone, fetching its songs first when it was
  /// listed without them.
  func download(_ album: Album) {
    var album = album
    Task {
      album.songs = await songs(of: album)
      guard !album.songs.isEmpty else { return show("Not available offline") }
      let onPhone = AlbumService.shared.downloadedMediaFileIds(collectionId: album.id)
      guard album.songs.contains(where: { !onPhone.contains($0.playbackID) }) else {
        return show("Already on this iPhone")
      }
      albums.downloadAlbum(album)
      downloads.addItem(album)
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

  /// Plays a station and shows the player; a station is a live stream, so
  /// nothing plays while streaming is off on cellular.
  func play(_ radio: Radio) {
    guard TranscodingSettings.streamingBitRate != nil else {
      return show("Streaming on cellular is off")
    }
    if player.playRadioItem(radio: radio) { isNowPlayingPresented = true }
  }

  /// Plays what Siri, Shortcuts or the Action Button asked for and shows the
  /// player. Logged out, the request is dropped.
  func takePlayRequest() {
    guard let request = PlayRequest.take(), auth.isLoggedIn else { return }
    Task {
      let played =
        switch request {
        case .something: await player.playSomething()
        case .artist(let id, let name): await player.playArtist(id: id, name: name)
        }
      if played { isNowPlayingPresented = true }
    }
  }
}
