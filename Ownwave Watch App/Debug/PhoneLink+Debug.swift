//
//  PhoneLink+Debug.swift
//  Ownwave Watch App
//

#if DEBUG
  import Foundation

  // Simulator verification only; the simulators' WatchConnectivity cannot
  // pair here, so these feed the link what the phone would send.
  // FLO_DEBUG_PHONE=settings:on|settings:off applies shared settings (160 kbps
  // streaming, 256 kbps downloads, Keep Playing on); signin:url|user|password
  // asks for a sign-in; file:<albumId> delivers the album's first two songs
  // at 192 kbps as the phone would.
  extension PhoneLink {
    func runDebugLaunchActions() {
      guard let action = ProcessInfo.processInfo.environment["FLO_DEBUG_PHONE"] else { return }
      Task { @MainActor in
        try? await Task.sleep(for: .seconds(4))
        if action.hasPrefix("settings:") {
          apply(
            Link.encode(
              Link.Settings(
                share: action == "settings:on", streamingBitRate: "160", downloadBitRate: "256",
                keepPlaying: true)))
          debugLog(
            "phone link: follows=\(UserDefaultsManager.settingsFollowPhone) "
              + "streaming=\(UserDefaultsManager.maxBitRate) "
              + "downloads=\(UserDefaultsManager.downloadBitRate) keep=\(UserDefaultsManager.keepPlaying)")
        } else if action.hasPrefix("signin:") {
          let parts = action.dropFirst(7).split(separator: "|", maxSplits: 2).map(String.init)
          guard parts.count == 3 else { return }
          requestSignIn(Link.SignIn(server: parts[0], user: parts[1], password: parts[2]))
        } else if action.hasPrefix("file:") {
          await deliverDebugFiles(albumId: String(action.dropFirst(5)))
        }
      }
    }

    private func deliverDebugFiles(albumId: String) async {
      let songs = await withCheckedContinuation { continuation in
        AlbumService.shared.getSongFromAlbum(id: albumId) {
          continuation.resume(returning: (try? $0.get()) ?? [])
        }
      }
      guard let key = AuthService.shared.accountKey, let first = songs.first else {
        return debugLog("phone link: no songs or no account")
      }
      var album = Album()
      album.id = albumId
      album.name = first.albumName
      album.albumArtist = first.artist
      for song in songs.prefix(2) {
        guard let request = AlbumService.shared.downloadRequest(mediaFileId: song.id, kbps: 192),
          let (file, _) = try? await URLSession.shared.download(for: request)
        else { return debugLog("phone link: download failed") }
        let info = Link.FileInfo(
          kind: .song, accountKey: key, collectionId: albumId, songCount: songs.count,
          album: album, song: song, suffix: TranscodingSettings.targetFormat, kbps: 192)
        receiver.receive(file, metadata: Link.encode(info))
        try? await Task.sleep(for: .seconds(1))
        debugLog("phone link: delivered \(song.title), incoming=\(incoming)")
      }
    }
  }
#endif
