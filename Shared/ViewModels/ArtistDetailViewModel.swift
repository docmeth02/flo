//    flo

import Foundation

@MainActor
final class ArtistDetailViewModel: ObservableObject {
  @Published private(set) var isLoadingRadio = false

  /// What the artist screens say when Artist Radio has nothing to play.
  static let noRadioMessage = "No similar songs found for this artist."

  /// Songs similar to the artist's for Artist Radio; none when the server
  /// has none or did not answer.
  func fetchArtistRadio(artist: Artist) async -> [Song] {
    isLoadingRadio = true
    defer { isLoadingRadio = false }
    let result = await withCheckedContinuation { continuation in
      RadioService.shared.getSimilarSongs(id: artist.id) { continuation.resume(returning: $0) }
    }
    return (try? result.get()) ?? []
  }
}
