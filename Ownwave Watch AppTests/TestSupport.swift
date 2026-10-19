import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

extension XCTestCase {
  /// A fresh defaults suite, removed when the test ends.
  func makeDefaults() -> UserDefaults {
    let name = "\(type(of: self)).\(UUID().uuidString)"
    addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
    return UserDefaults(suiteName: name)!
  }

  /// Lets an answer's hop to the main actor run.
  func settle() async {
    for _ in 0..<5 { await Task.yield() }
  }
}

extension Song {
  /// A 200 s MP3 at 320 kbps, track 1 of disc 1; a test sets what it looks at.
  static func fixture(
    _ id: String, title: String? = nil, artist: String = "Artist", album: String = "al",
    albumName: String = "Album", mediaFileId: String = ""
  ) -> Song {
    Song(
      id: id, title: title ?? "Song \(id)", albumId: album, albumName: albumName, artist: artist,
      trackNumber: 1, discNumber: 1, bitRate: 320, sampleRate: 44100, suffix: "mp3",
      duration: 200, mediaFileId: mediaFileId)
  }
}
