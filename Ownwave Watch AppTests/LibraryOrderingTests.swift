import XCTest

#if canImport(Ownwave_Watch_App)
  @testable import Ownwave_Watch_App
#endif

final class LibraryOrderingTests: XCTestCase {
  private func artist(_ name: String, albums: Int = 1) -> Artist {
    Artist(id: name, name: name, albumCount: albums, mbzArtistID: nil)
  }

  private func album(
    _ name: String, by artist: String = "A", year: Int = 0, added: String = ""
  ) -> Album {
    var album = Album(id: name, name: name, albumArtist: artist, minYear: year)
    album.createdAt = added
    return album
  }

  private func playlist(_ name: String, updated: String = "") -> Playlist {
    var playlist = Playlist(id: name, name: name)
    playlist.updatedAt = updated
    return playlist
  }

  func testAlbumOrdersAndTheirTies() {
    let albums = [
      album("b", by: "Zed", year: 2001, added: "2026-01-02"),
      album("a10", by: "Zed", year: 2001, added: ""),
      album("a2", by: "Abe", year: 1999, added: "2026-01-02"),
    ]
    // Numbers by value, ties by name, an album without a date last.
    XCTAssertEqual(AlbumOrder.name.sorted(albums).map(\.name), ["a2", "a10", "b"])
    XCTAssertEqual(AlbumOrder.added.sorted(albums).map(\.name), ["a2", "b", "a10"])
    XCTAssertEqual(AlbumOrder.artist.sorted(albums).map(\.name), ["a2", "a10", "b"])
    XCTAssertEqual(AlbumOrder.year.sorted(albums).map(\.name), ["a10", "b", "a2"])
  }

  func testArtistAndPlaylistOrders() {
    let artists = [
      artist("beta", albums: 2), artist("Alpha", albums: 2), artist("gamma", albums: 5),
    ]
    XCTAssertEqual(ArtistOrder.name.sorted(artists).map(\.name), ["Alpha", "beta", "gamma"])
    XCTAssertEqual(ArtistOrder.albums.sorted(artists).map(\.name), ["gamma", "Alpha", "beta"])

    let playlists = [playlist("b", updated: "2026-02"), playlist("a", updated: "2026-02")]
    XCTAssertEqual(PlaylistOrder.updated.sorted(playlists).map(\.name), ["a", "b"])
    XCTAssertEqual(PlaylistOrder.name.sorted(playlists.reversed()).map(\.name), ["a", "b"])
  }

  func testSortMemoSortsAgainOnlyWhenSomethingChanged() {
    let memo = SortMemo<PlaylistOrder>()
    let playlists = [playlist("b", updated: "1"), playlist("a", updated: "2")]
    XCTAssertEqual(memo.sorted(playlists, by: .name).map(\.name), ["a", "b"])
    XCTAssertEqual(memo.sorted(playlists, by: .updated).map(\.name), ["a", "b"])
    XCTAssertEqual(
      memo.sorted(playlists + [playlist("c", updated: "3")], by: .updated).map(\.name),
      ["c", "a", "b"])
  }

  func testMemoMakesAgainOnlyForANewInput() {
    let memo = Memo<[Int], Int>()
    var made = 0
    let sum: ([Int]) -> Int = {
      made += 1
      return $0.reduce(0, +)
    }
    XCTAssertEqual(memo.value(for: [1, 2], make: sum), 3)
    XCTAssertEqual(memo.value(for: [1, 2], make: sum), 3)
    XCTAssertEqual(made, 1)
    XCTAssertEqual(memo.value(for: [1, 2, 3], make: sum), 6)
    XCTAssertEqual(made, 2)
  }

  func testArtistSectionsFoldLettersAndCollectTheRest() {
    let artists = [
      "333-METAL", "[Unknown Artist]", "Ätna", "abba", "Ólafur Arnalds", "ＢＡＢＹＭＥＴＡＬ",
      "ジミー・ペンタトニック", " zeta", "",
    ].map { artist($0) }
    let sections = artistSections(artists)
    XCTAssertEqual(sections.map(\.letter), ["#", "A", "B", "O", "Z"])
    XCTAssertEqual(
      sections.first?.artists.map(\.name),
      ["333-METAL", "[Unknown Artist]", "ジミー・ペンタトニック", ""])
    // Each section keeps the order it was given.
    XCTAssertEqual(sections[1].artists.map(\.name), ["Ätna", "abba"])
    XCTAssertEqual(artistSections([]), [])
  }

  func testTopResultRanksMatchThenPinThenKind() {
    let artists = [artist("Love Songs"), artist("Lover")]
    let albums = [album("Love"), album("Glove")]
    let songs = [Song.fixture("s1", title: "love")]
    let results = LibrarySearch.Results(artists: artists, albums: albums, songs: songs)
    let none: (MenuTarget) -> Bool = { _ in false }

    // An exact name wins over a prefix; the album before the song.
    XCTAssertEqual(
      LibrarySearch.topResult("LOVE ", in: results, isPinned: none)?.id, "album-Love")
    // A pinned item wins a tie.
    XCTAssertEqual(
      LibrarySearch.topResult("love", in: results, isPinned: { $0.id == "song-s1" })?.id,
      "song-s1")
    // Among prefixes the artist comes first, then the search's order.
    XCTAssertEqual(
      LibrarySearch.topResult("lov", in: results, isPinned: none)?.id, "artist-Love Songs")
    XCTAssertNil(
      LibrarySearch.topResult(
        "x", in: LibrarySearch.Results(artists: [], albums: [], songs: []), isPinned: none))

    let targets = albums.map(MenuTarget.album)
    XCTAssertEqual(
      LibrarySearch.pinnedFirst(targets, isPinned: { $0.id == "album-Glove" }).map(\.id),
      ["album-Glove", "album-Love"])
  }

  func testSongsAndLength() {
    XCTAssertEqual(songsAndLength(12, seconds: 2880), "12 songs · 48 min")
    XCTAssertEqual(songsAndLength(1, seconds: 0), "1 song")
    XCTAssertEqual(songsAndLength(3, seconds: .nan), "3 songs")
    XCTAssertEqual(songsAndLength(3, seconds: .infinity), "3 songs")
    XCTAssertEqual([Song]().countAndLength, "")
    let unknown = Song(
      id: "s1", title: "T", albumId: "al", albumName: "A", artist: "A", trackNumber: 1,
      discNumber: 1, bitRate: 0, sampleRate: 0, suffix: "mp3", duration: .nan, mediaFileId: "")
    XCTAssertEqual([Song.fixture("s0"), unknown].countAndLength, "2 songs · 3 min")
  }
}
