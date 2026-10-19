//
//  AuthViewModel.swift
//  flo
//

import Foundation

class AuthViewModel: ObservableObject {
  @Published var serverUrl: String = ""
  @Published var username: String = ""
  @Published var password: String = ""

  @Published var showAlert: Bool = false
  @Published var alertMessage: String = ""

  @Published var isSubmitting: Bool = false
  @Published var isLoggedIn: Bool = false

  // Bumped by every interactive login and logout; a background re-login only
  // persists its result while the generation is unchanged.
  private var sessionGeneration: Int = 0
  private var isReauthenticating = false
  // Set while the session could not be renewed for lack of a connection, so
  // the next time the network comes back triggers another attempt.
  private var needsReauthentication = false
  // Set while the stored login could not be read: the app stays logged in
  // without credentials and reads it again on every return to the app.
  private var storedLoginUnreadable = false

  init() {
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleSessionExpired(_:)), name: .sessionExpired, object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleNetworkBecameOnline), name: .networkBecameOnline,
      object: nil)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDidBecomeActive),
      name: AppPlatform.didBecomeActive, object: nil)

    // AuthService read the stored login when it was created.
    adopt(AuthService.shared.launchLogin)

    #if DEBUG
      applyDebugLaunchOptions()
    #endif
  }

  /// Found, the stored login is in use: trust it immediately, since a cold
  /// launch must never block on a login that can only time out while
  /// offline. Navidrome tokens expire, so the session is renewed once the
  /// first connectivity verdict reaches the server, or later when it comes
  /// back. Only a confirmed absence shows the login screen; an unreadable
  /// Keychain keeps the app logged in and never wipes anything.
  private func adopt(_ login: KeychainRead<UserAuth>) {
    switch login {
    case .found:
      storedLoginUnreadable = false
      guard Self.restoreServerURL() else {
        AuthService.shared.clearCreds()
        isLoggedIn = false
        return
      }
      isLoggedIn = true
      needsReauthentication = true

      // A request rejected before the verdict has already triggered it.
      renewWhenReachable()

    case .missing:
      storedLoginUnreadable = false
      isLoggedIn = false

    case .unreadable(let error):
      RequestLog.shared.note("stored login unreadable: \(error)")
      storedLoginUnreadable = true
      isLoggedIn = true
    }
  }

  /// Keychain items outlive an uninstall while the stored server URL does
  /// not, so the Keychain keeps a copy of it. Credentials without any server
  /// (stored before that copy existed) are unusable and would leave the app
  /// "logged in" with every request going nowhere: they are removed and the
  /// result is false. An unreadable Keychain URL leaves everything as it is.
  private static func restoreServerURL() -> Bool {
    guard let keychainURL = try? KeychainManager.getServerURL() ?? "" else { return true }
    if !UserDefaultsManager.serverBaseURL.isEmpty {
      if keychainURL.isEmpty {
        try? KeychainManager.setServerURL(newValue: UserDefaultsManager.serverBaseURL)
      }
    } else if !keychainURL.isEmpty {
      UserDefaultsManager.serverBaseURL = keychainURL
    } else {
      try? KeychainManager.removeAuthCreds()
      try? KeychainManager.removeAuthPassword()
      return false
    }
    return true
  }

  /// Silent re-login with the stored server, username and saved password. Only
  /// a rejected password logs out; any other failure, an unreadable Keychain
  /// included, keeps the session and retries once the network comes back.
  private func reauthenticate() {
    let serverUrl = UserDefaultsManager.serverBaseURL
    guard isLoggedIn, !isReauthenticating, !serverUrl.isEmpty else { return }

    let stored: UserAuth
    let password: String
    switch (KeychainManager.loadAuth(), KeychainManager.loadPassword()) {
    case (.found(let auth), .found(let found)):
      stored = auth
      password = found
    case (.unreadable(let error), _), (_, .unreadable(let error)):
      debugLog("error reading the stored login from Keychain: \(error)")
      needsReauthentication = true
      AuthService.shared.abandonRenewal()
      return
    default:
      return
    }

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
          AuthService.shared.abandonRenewal()
        }
      }
    }
  }

  @objc private func handleSessionExpired(_ notification: Notification) {
    // Without a readable login there is no session to renew or end.
    guard !storedLoginUnreadable,
      let requestSession = notification.object as? AuthSessionSnapshot,
      AuthService.shared.isCurrentSession(requestSession)
    else { return }

    if case .missing = KeychainManager.loadPassword() {
      logout()
    } else {
      reauthenticate()
    }
  }

  /// An unreadable login is read again; a renewal that could not read the
  /// Keychain (locked watch) is tried again.
  @objc private func handleDidBecomeActive() {
    if storedLoginUnreadable {
      adopt(AuthService.shared.loadStoredLogin())
    } else if needsReauthentication {
      renewWhenReachable()
    }
  }

  /// Renews once the server is known to answer: offline a login could only
  /// time out, and the probe that finds the server back posts
  /// `networkBecameOnline`.
  private func renewWhenReachable() {
    ConnectivityMonitor.shared.onFirstVerdict { [weak self] _ in
      guard let self, self.needsReauthentication, ConnectivityMonitor.shared.canReachServer
      else { return }
      self.reauthenticate()
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
        // The success path mutates @Published state, so make sure it runs on
        // the main actor regardless of which queue Alamofire delivered the
        // response on.
        DispatchQueue.main.async {
          self.persistAuthData(data, serverUrl: self.serverUrl)
          self.needsReauthentication = false

          // Without it the session cannot be renewed and ends with the token.
          do {
            try KeychainManager.setAuthPassword(newValue: self.password)
          } catch {
            debugLog("error saving password to Keychain: \(error)")
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
            // A bare 401/403 without Navidrome's error body, e.g. from a
            // reverse proxy in front of the server.
            self.alertMessage = "The server refused the request. Please try again."

          case .unknown:
            self.alertMessage = "Unknown error occurred"
          }

          self.showAlert = true
        }
      }
    }
  }

  func logout() {
    sessionGeneration += 1

    // A keychain error must not skip the rest: a half logout leaves this
    // account's data and requests behind for the next.
    do {
      try KeychainManager.removeAuthCreds()
    } catch {
      debugLog("error removing auth creds from Keychain: \(error)")
    }
    AuthService.shared.clearCreds()
    // Nothing of this account may be answered or retried under the next.
    APIManager.shared.session.cancelAllRequests()

    do {
      try KeychainManager.removeAuthPassword()
    } catch {
      debugLog("error removing password from Keychain: \(error)")
    }
    do {
      try KeychainManager.removeServerURL()
    } catch {
      debugLog("error removing server URL from Keychain: \(error)")
    }

    // Navidrome's nd-player cookie names this account's user.
    if let host = URL(string: UserDefaultsManager.serverBaseURL)?.host {
      let storage = HTTPCookieStorage.shared
      for cookie in storage.cookies ?? []
      where cookie.domain == host || cookie.domain == "." + host {
        storage.deleteCookie(cookie)
      }
    }
    UserDefaultsManager.removeObject(key: UserDefaultsKeys.serverURL)

    // The library caches feed smart shuffle; the next account must not
    // inherit this account's songs, albums or starred list. Queued scrobbles
    // would be submitted with the next account's credentials.
    LibraryCacheManager.shared.clearCache()
    StreamCacheManager.shared.clearCache()
    ScrobbleQueueManager.shared.clearAll()
    URLCache.shared.removeAllCachedResponses()
    CoverArtCacheManager.shared.clearCache()
    RequestLog.shared.clear()

    isLoggedIn = false
    needsReauthentication = false
    storedLoginUnreadable = false

    NotificationCenter.default.post(name: .didLogout, object: nil)
  }

  func persistAuthData(_ data: UserAuth, serverUrl: String) {
    do {
      let jsonData = try JSONEncoder().encode(data)
      let jsonString = String(data: jsonData, encoding: .utf8)!

      do {
        try KeychainManager.setAuthCreds(newValue: jsonString)
      } catch {
        debugLog("Error saving auth creds to Keychain: \(error)")
      }

      AuthService.shared.setCreds(data)
      UserDefaultsManager.serverBaseURL = serverUrl
      do {
        try KeychainManager.setServerURL(newValue: UserDefaultsManager.serverBaseURL)
      } catch {
        debugLog("Error saving server URL to Keychain: \(error)")
      }
    } catch {
      debugLog("Error encoding auth data: \(error)")
    }
  }

}
