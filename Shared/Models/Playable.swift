//
//  Playable.swift
//  flo
//

protocol Playable {
  var id: String { get }
  var name: String { get }
  var songs: [Song] { get set }
  /// Its songs keep the playlist as their origin.
  var isPlaylist: Bool { get }
}

struct SongCollection: Playable {
  let id: String
  let name: String
  var songs: [Song]
  var isPlaylist = false
}

// The queues the app puts together itself, the same on both platforms.
extension SongCollection {
  /// The names of the queues whose songs have an origin of their own; the
  /// queue keeps only the name (`QueueEntity.playbackOrigin`).
  enum Name {
    static let smartShuffle = "Smart Shuffle"
    static let keepPlaying = "Auto Play"
    static let liked = "Liked Songs"
    static let cached = "Cached"
  }

  static func smartShuffle(_ songs: [Song]) -> SongCollection {
    SongCollection(id: "smart-shuffle", name: Name.smartShuffle, songs: songs)
  }

  static func keepPlaying(_ songs: [Song]) -> SongCollection {
    SongCollection(id: "auto-play", name: Name.keepPlaying, songs: songs)
  }

  static func liked(_ songs: [Song]) -> SongCollection {
    SongCollection(id: "starred-songs", name: Name.liked, songs: songs)
  }

  static func cached(_ songs: [Song]) -> SongCollection {
    SongCollection(id: "cached-songs", name: Name.cached, songs: songs)
  }

  /// One song picked from the search results.
  static func search(_ song: Song) -> SongCollection {
    SongCollection(id: "search", name: "Search", songs: [song])
  }

  /// The artist's top songs, or its songs from the library.
  static func artist(id: String, name: String, songs: [Song]) -> SongCollection {
    SongCollection(id: "artist-\(id)", name: name, songs: songs)
  }

  static func artistRadio(id: String, name: String, songs: [Song]) -> SongCollection {
    SongCollection(id: id, name: "\(name) Radio", songs: songs)
  }
}
