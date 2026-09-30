//
//  AuthViewModel.swift
//  flo
//
//  Created by rizaldy on 06/06/24.
//

import Foundation
import KeychainAccess

class AuthViewModel: ObservableObject {
  @Published var user: UserAuth?

  @Published var serverUrl: String = ""
  @Published var username: String = ""
  @Published var password: String = ""

  @Published var showAlert: Bool = false
  @Published var alertMessage: String = ""
  @Published var experimentalSaveLoginInfo: Bool = false

  @Published var isSubmitting: Bool = false
  @Published var isLoggedIn: Bool = false

  // Bumped by every interactive login and logout; a background re-login only
  // persists its result while the generation is unchanged.
  private var sessionGeneration: Int = 0
  private var isReauthenticating = false
  // Set while the session could not be renewed for lack of a connection, so
  // the next time the network comes back triggers another attempt.
  private var needsReauthentication = false

  init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleSessionExpired(_:)), name: .sessionExpired, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleNetworkBecameOnline), name: .networkBecameOnline,
      object: nil)

    // Keychain items outlive an uninstall while the stored server URL does
    // not; credentials without a server are unusable and would leave the app
    // "logged in" with every request going nowhere.
    if Self.storedAuth() != nil, UserDefaultsManager.serverBaseURL.isEmpty {
      try? KeychainManager.removeAuthCreds()
      try? KeychainManager.removeAuthPassword()
    }

    if let data = Self.storedAuth() {
      // Trust cached creds immediately; a cold launch must never block on a
      // login that can only time out while offline. AuthService already loaded
      // them from the Keychain. Navidrome tokens expire, so renew the session
      // once the first connectivity verdict is online, or later when the
      // network comes back.
      user = UserAuth(
        id: data.id, username: data.username, name: data.name, isAdmin: data.isAdmin,
        lastFMApiKey: data.lastFMApiKey)
      isLoggedIn = true
      needsReauthentication = true

      ConnectivityMonitor.shared.onFirstVerdict { [weak self] online in
        if online { self?.reauthenticate() }
      }
    }

    #if DEBUG
      applyDebugLaunchOptions()
    #endif
  }

  private static func storedAuth() -> UserAuth? {
    guard let json = try? KeychainManager.getAuthCreds(), let data = json.data(using: .utf8)
    else { return nil }
    return try? JSONDecoder().decode(UserAuth.self, from: data)
  }

  private static func storedPassword() -> String? {
    guard let password = try? KeychainManager.getAuthPassword(), !password.isEmpty else {
      return nil
    }
    return password
  }

  /// Silent re-login with the stored server, username and saved password. Only
  /// a rejected password logs out; any other failure keeps the session and
  /// retries once the network comes back.
  private func reauthenticate() {
    let serverUrl = UserDefaultsManager.serverBaseURL
    guard isLoggedIn, !isReauthenticating, !serverUrl.isEmpty,
      let stored = Self.storedAuth(), let password = Self.storedPassword()
    else { return }

    isReauthenticating = true
    let generation = sessionGeneration

    AuthService.shared.login(serverUrl: serverUrl, username: stored.username, password: password) {
      [weak self] result in
      DispatchQueue.main.async {
        guard let self = self else { return }
        self.isReauthenticating = false

        // A logout or an interactive login into another account while this was
        // in flight must never be overwritten by the stale completion.
        guard self.isLoggedIn, self.sessionGeneration == generation else { return }

        switch result {
        case .success(let data):
          self.needsReauthentication = false
          self.persistAuthData(data, serverUrl: serverUrl)
        case .failure(.invalidCredentials):
          self.logout()
        case .failure:
          self.needsReauthentication = true
        }
      }
    }
  }

  @objc private func handleSessionExpired(_ notification: Notification) {
    guard let requestSession = notification.object as? AuthSessionSnapshot,
      AuthService.shared.isCurrentSession(requestSession)
    else { return }

    if Self.storedPassword() != nil {
      reauthenticate()
    } else {
      logout()
    }
  }

  @objc private func handleNetworkBecameOnline() {
    if needsReauthentication {
      reauthenticate()
    }
  }

  func login() {
    sessionGeneration += 1
    isSubmitting = true

    // Watch text input often adds a trailing space, and a trailing slash
    // would double up with every endpoint path.
    serverUrl = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
    while serverUrl.hasSuffix("/") { serverUrl.removeLast() }

    AuthService.shared.login(serverUrl: serverUrl, username: username, password: password) {
      result in
      switch result {
      case .success(let data):
        // persistAuthData mutates @Published state ("user"), so make sure the
        // whole success path runs on the main actor regardless of which queue
        // Alamofire delivered the response on.
        DispatchQueue.main.async {
          self.persistAuthData(data, serverUrl: self.serverUrl)
          self.needsReauthentication = false

          if self.experimentalSaveLoginInfo {
            do {
              try KeychainManager.setAuthPassword(newValue: self.password)
              UserDefaultsManager.saveLoginInfo = true

              self.experimentalSaveLoginInfo = false
            } catch {
              print("error saving password to Keychain: \(error)")
            }
          }

          self.isSubmitting = false
          self.isLoggedIn = true
          self.username = ""
          self.password = ""
          self.serverUrl = ""
        }

      case .failure(let error):
        DispatchQueue.main.async {
          self.isSubmitting = false

          switch error {
          case .server(let message), .invalidCredentials(let message):
            self.alertMessage = message

          case .sessionExpired:
            self.alertMessage = "Session expired. Please log in again."

          case .unknown:
            self.alertMessage = "Unknown error ocurred"
          }

          self.showAlert = true
        }
      }
    }
  }

  // TODO: how to deal with "last playing" data?
  func logout() {
    sessionGeneration += 1

    do {
      try KeychainManager.removeAuthCreds()
      AuthService.shared.clearCreds()

      destroySavedPassword()

      UserDefaultsManager.removeObject(key: UserDefaultsKeys.serverURL)

      // The library caches feed smart shuffle; the next account must not
      // inherit this account's songs, albums or starred list. Queued scrobbles
      // would be submitted with the next account's credentials.
      LibraryCacheManager.shared.clearCache()
      ScrobbleQueueManager.shared.clearAll()

      user = nil
      isLoggedIn = false
      needsReauthentication = false

      NotificationCenter.default.post(name: .didLogout, object: nil)
    } catch {
      print("error>>>>> \(error)")
    }
  }

  func destroySavedPassword() {
    do {
      try KeychainManager.removeAuthPassword()

      UserDefaultsManager.saveLoginInfo = false
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.saveLoginInfo)
    } catch {
      print("error>>>>> \(error)")
    }
  }

  func persistAuthData(_ data: UserAuth, serverUrl: String) {
    do {
      let jsonData = try JSONEncoder().encode(data)
      let jsonString = String(data: jsonData, encoding: .utf8)!

      do {
        try KeychainManager.setAuthCreds(newValue: jsonString)
      } catch {
        print("Error saving auth creds to Keychain: \(error)")
      }

      AuthService.shared.setCreds(data)
      UserDefaultsManager.serverBaseURL = serverUrl

      user = UserAuth(
        id: data.id, username: data.username, name: data.name, isAdmin: data.isAdmin,
        lastFMApiKey: data.lastFMApiKey
      )
    } catch {
      print("Error encoding auth data: \(error)")
    }
  }

}

#if DEBUG
  // Simulator verification only. FLO_DEBUG_LOGIN="url|user|password" signs in
  // when nobody is logged in; FLO_DEBUG_EXPIRE_TOKEN=1 expires the Navidrome
  // token ten seconds after launch, provokes a 401 and logs whether the
  // session recovered; FLO_DEBUG_LOGOUT_AFTER=<seconds> logs out.
  extension AuthViewModel {
    fileprivate func applyDebugLaunchOptions() {
      let env = ProcessInfo.processInfo.environment

      if !isLoggedIn, let debugLogin = env["FLO_DEBUG_LOGIN"] {
        let parts = debugLogin.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return }
        serverUrl = parts[0]
        username = parts[1]
        password = parts[2]
        experimentalSaveLoginInfo = true
        login()
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
          print("[flo-debug] loggedIn=\(self?.isLoggedIn ?? false) tokenRenewed=\(renewed)")
        }
      }
    }
  }
#endif
