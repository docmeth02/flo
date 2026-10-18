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

  /// Downloads an album to the phone, fetching its songs first when it was
  /// listed without them.
  func download(_ album: Album) {
    var album = album
    Task {
      if album.songs.isEmpty {
        album.songs = await withCheckedContinuation { continuation in
          AlbumService.shared.getSongFromAlbum(id: album.id) {
            continuation.resume(returning: (try? $0.get()) ?? [])
          }
        }
      }
      guard !album.songs.isEmpty else { return show("Not available offline") }
      albums.downloadAlbum(album)
      downloads.addItem(album)
      show("Downloading at \(UserDefaultsManager.downloadBitRate) kbps")
    }
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
