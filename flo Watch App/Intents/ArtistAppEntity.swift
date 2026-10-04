//
//  ArtistAppEntity.swift
//  flo Watch App
//

import AppIntents

/// An artist for Siri and Shortcuts. Siri only knows the names in the cached
/// artist list, which AlbumViewModel refreshes.
struct ArtistAppEntity: AppEntity {
  static var typeDisplayRepresentation: TypeDisplayRepresentation = "Artist"
  static var defaultQuery = Query()

  let id: String
  let name: String

  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(stringLiteral: name) }

  init(_ artist: Artist) {
    id = artist.id
    name = artist.name
  }

  struct Query: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [ArtistAppEntity] {
      let ids = Set(identifiers)
      return await Self.artists().filter { ids.contains($0.id) }.map(ArtistAppEntity.init)
    }

    /// An artist named exactly as spoken wins, so "Air" does not make Siri
    /// ask between Air, Air Supply and Airbourne.
    func entities(matching string: String) async throws -> [ArtistAppEntity] {
      let found = LibrarySearch.search(string, artists: await Self.artists(), albums: [], songs: [])?
        .artists ?? []
      let spoken = string.trimmingCharacters(in: .whitespacesAndNewlines)
      let exact = found.filter {
        $0.name.compare(spoken, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
      }
      return (exact.isEmpty ? found : exact).map(ArtistAppEntity.init)
    }

    func suggestedEntities() async throws -> [ArtistAppEntity] {
      await Self.artists().map(ArtistAppEntity.init)
    }

    private static func artists() async -> [Artist] {
      await AlbumViewModel.cached(.artists)
    }
  }
}
