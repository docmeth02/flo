//
//  ArtistDetailViewModel.swift
//  flo
//

import Foundation

@MainActor
final class ArtistDetailViewModel: ObservableObject {
  @Published private(set) var isLoadingRadio = false

  /// Songs similar to the artist's for Artist Radio, nil when the server did
  /// not answer.
  func fetchArtistRadio(artist: Artist) async -> [Song]? {
    isLoadingRadio = true
    defer { isLoadingRadio = false }
    let result = await withCheckedContinuation { continuation in
      RadioService.shared.getSimilarSongs(id: artist.id) { continuation.resume(returning: $0) }
    }
    return try? result.get()
  }

  /// What the artist screens say when Artist Radio has nothing to play.
  static func noRadioMessage(failed: Bool) -> String {
    failed
      ? "Failed to load Artist Radio. Please try again."
      : "No similar songs found for this artist."
  }
}
