//
//  AuthViewModel+Debug.swift
//  flo Watch App
//

#if DEBUG
  import Foundation

  // Simulator verification only. FLO_DEBUG_LOGIN="url|user|password" signs in
  // when nobody is logged in; FLO_DEBUG_EXPIRE_TOKEN=1 expires the Navidrome
  // token ten seconds after launch, provokes a 401 and logs whether the
  // session recovered (=launch expires it right away);
  // FLO_DEBUG_LOGOUT_AFTER=<seconds> logs out.
  extension AuthViewModel {
    func applyDebugLaunchOptions() {
      let env = ProcessInfo.processInfo.environment

      if !isLoggedIn, let debugLogin = env["FLO_DEBUG_LOGIN"] {
        let parts = debugLogin.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        serverUrl = parts[0]
        username = parts[1]
        password = parts[2]
        login()
      } else if isLoggedIn, env["FLO_DEBUG_EXPIRE_TOKEN"] == "launch" {
        // Cold start with an expired Navidrome token: the first library
        // requests must 401, wait for the re-login and still deliver.
        AuthService.shared.invalidateNDTokenForTesting()
        debugLog("token invalidated at launch")
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
          let renewed = AuthService.shared.getCreds(key: "NDToken") != "expired"
          debugLog("loggedIn=\(self?.isLoggedIn ?? false) tokenRenewed=\(renewed)")
        }
      } else if isLoggedIn, let delay = env["FLO_DEBUG_LOGOUT_AFTER"].flatMap(Double.init) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
          self?.logout()
          debugLog("logged out")
        }
      } else if isLoggedIn, env["FLO_DEBUG_EXPIRE_TOKEN"] == "1" {
        // After the launch-time re-login has settled, expire the token and
        // make one authenticated request to provoke the 401.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
          AuthService.shared.invalidateNDTokenForTesting()
          AlbumService.shared.isStarred(songId: "debug") { _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
          let renewed = AuthService.shared.getCreds(key: "NDToken") != "expired"
          debugLog("loggedIn=\(self?.isLoggedIn ?? false) tokenRenewed=\(renewed)")
        }
      }
    }
  }
#endif
