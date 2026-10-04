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

    func entities(matching string: String) async throws -> [ArtistAppEntity] {
      let artists = await Self.artists()
      return (LibrarySearch.search(string, artists: artists, albums: [], songs: [])?.artists ?? [])
        .map(ArtistAppEntity.init)
    }

    func suggestedEntities() async throws -> [ArtistAppEntity] {
      await Self.artists().map(ArtistAppEntity.init)
    }

    private static func artists() async -> [Artist] {
      await AlbumViewModel.cached(.artists)
    }
  }
}
