//
//  Handoff+Debug.swift
//  Ownwave
//

#if DEBUG
  import Foundation

  extension Link.Handoff {
    /// The album's songs as the other device would hand them over, 30 s into
    /// the first, for the link hooks (the simulators cannot pair).
    @MainActor static func debug(albumId: String) async -> Link.Handoff? {
      guard let account = AuthService.shared.accountKey,
        let songs = try? await LibraryAPI.getSongFromAlbum(id: albumId), let first = songs.first
      else { return nil }
      let snapshot = QueueSnapshot(
        entries: songs.sorted(by: Song.albumOrder).map {
          QueueEntry(song: $0, contextName: first.albumName, isFromPlaylist: false)
        },
        activeIndex: 0, position: 30, qualified: false, listened: 12,
        playbackMode: PlaybackMode.defaultPlayback)
      return Link.Handoff(id: UUID(), accountKey: account, snapshot: snapshot)
    }

    /// Feeds the handoff to `take` as the link would and logs the reply;
    /// `ready` pauses right after the adoption, so the start ends silent.
    @MainActor func runDebug(
      ready: Bool, player: PlayerViewModel,
      take: (Link.Handoff, @escaping ([String: Any]) -> Void) -> Void
    ) {
      take(self) { reply in
        debugLog(
          "handoff debug: reply \(String(describing: Link.decode(Link.Reply.self, from: reply)))")
        if ready { player.pause() }
      }
    }
  }
#endif
