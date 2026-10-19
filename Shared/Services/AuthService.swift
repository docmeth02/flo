//
//  AuthService.swift
//  flo
//

import Alamofire
import Foundation

struct AuthSessionSnapshot: Equatable {
  let generation: UInt64
  let ndToken: String
  let subsonicCredentials: String
}

class AuthService {
  static let shared = AuthService()

  private var ndToken: String?
  private var subsonicParams: String?
  private var userId: String?
  private var credentialGeneration: UInt64 = 0
  private let credentialsLock = NSLock()
  // A token renewed by the server since the stored login was last written.
  private var tokenNeedsPersisting = false
  // Requests held back until a rejected Navidrome token is replaced.
  private var sessionWaiters: [SessionWaiter] = []

  private struct SessionWaiter {
    let id: UUID
    let completion: (Bool) -> Void
    let timeout: DispatchWorkItem
  }

  /// What the read of the stored login at launch found.
  private(set) var launchLogin: KeychainRead<UserAuth> = .missing

  private init() {
    launchLogin = loadStoredLogin()
  }

  /// Reads the stored login and uses it when found. Anything else leaves the
  /// session as it is, so an unreadable Keychain never ends one.
  @discardableResult
  func loadStoredLogin() -> KeychainRead<UserAuth> {
    let read = KeychainManager.loadAuth()
    if case .found(let data) = read {
      setCreds(data)
    }
    return read
  }

  /// Subsonic token authentication as a query string. Values are percent
  /// encoded so usernames with spaces, "&" or "+" reach the server intact;
  /// URLComponents leaves "+" alone, which servers read as a space.
  private static func subsonicQuery(for data: UserAuth) -> String {
    var components = URLComponents()
    components.queryItems = [
      URLQueryItem(name: "u", value: data.username),
      URLQueryItem(name: "t", value: data.subsonicToken),
      URLQueryItem(name: "s", value: data.subsonicSalt),
      URLQueryItem(name: "v", value: AppMeta.subsonicApiVersion),
      URLQueryItem(name: "c", value: AppMeta.name),
      URLQueryItem(name: "f", value: "json"),
    ]
    let query = components.percentEncodedQuery ?? ""
    return "?" + query.replacingOccurrences(of: "+", with: "%2B")
  }

  func sessionSnapshot() -> AuthSessionSnapshot {
    credentialsLock.lock()
    defer { credentialsLock.unlock() }
    return AuthSessionSnapshot(
      generation: credentialGeneration,
      ndToken: ndToken ?? "",
      subsonicCredentials: subsonicParams ?? ""
    )
  }

  /// Whether `snapshot` belongs to the login in use. The token itself moves
  /// with every renewal, so only the generation counts.
  func isCurrentSession(_ snapshot: AuthSessionSnapshot) -> Bool {
    sessionSnapshot().generation == snapshot.generation
  }

  /// Server and user the locally stored history belongs to, nil when logged
  /// out. Built from the stored login, never from a token, so it survives
  /// token renewals.
  var accountKey: String? {
    Self.accountKey(
      serverURL: UserDefaultsManager.serverBaseURL, userId: credentialsLock.withLock { userId })
  }

  /// "host[:port]/path|userId", the server part lowercased and without a
  /// trailing slash; nil without a user or a host.
  static func accountKey(serverURL: String, userId: String?) -> String? {
    guard let id = userId, !id.isEmpty, let url = URLComponents(string: serverURL),
      let host = url.host, !host.isEmpty
    else { return nil }
    var server = host + (url.port.map { ":\($0)" } ?? "") + url.path
    while server.hasSuffix("/") { server.removeLast() }
    return "\(server.lowercased())|\(id)"
  }

  func setCreds(_ data: UserAuth) {
    let subsonicParams = Self.subsonicQuery(for: data)

    credentialsLock.lock()
    credentialGeneration &+= 1
    self.ndToken = data.token
    self.subsonicParams = subsonicParams
    self.userId = data.id
    tokenNeedsPersisting = false
    let waiters = drainWaiters()
    credentialsLock.unlock()
    Self.resume(waiters, renewed: true)
  }

  /// Calls `completion` once the session differs from `snapshot` (true), or
  /// with false after `timeout` or a logout. Completes right away when it
  /// already differs. The completion runs on an arbitrary queue.
  func waitForRenewedSession(
    after snapshot: AuthSessionSnapshot, timeout: TimeInterval,
    completion: @escaping (Bool) -> Void
  ) {
    credentialsLock.lock()
    let token = ndToken ?? ""
    if token.isEmpty {
      credentialsLock.unlock()
      completion(false)
      return
    }
    if credentialGeneration != snapshot.generation || token != snapshot.ndToken {
      credentialsLock.unlock()
      completion(true)
      return
    }
    let id = UUID()
    let timeoutWork = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.credentialsLock.lock()
      let index = self.sessionWaiters.firstIndex { $0.id == id }
      let waiter = index.map { self.sessionWaiters.remove(at: $0) }
      self.credentialsLock.unlock()
      waiter?.completion(false)
    }
    sessionWaiters.append(SessionWaiter(id: id, completion: completion, timeout: timeoutWork))
    credentialsLock.unlock()
    DispatchQueue.global(qos: .utility).asyncAfter(
      deadline: .now() + timeout, execute: timeoutWork)
  }

  /// Navidrome sends a renewed token with every authenticated /api answer.
  /// Written to the Keychain by persistRenewedToken when the app leaves the
  /// foreground.
  func adoptRefreshedToken(_ token: String, from snapshot: AuthSessionSnapshot) {
    var token = token.trimmingCharacters(in: .whitespaces)
    if token.hasPrefix("Bearer ") {
      token = String(token.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    credentialsLock.lock()
    // An answer to a request of an earlier login must not replace a newer one.
    guard !token.isEmpty, credentialGeneration == snapshot.generation, ndToken != token else {
      credentialsLock.unlock()
      return
    }
    ndToken = token
    tokenNeedsPersisting = true
    let waiters = drainWaiters()
    credentialsLock.unlock()
    debugLog("navidrome token refreshed")
    Self.resume(waiters, renewed: true)
  }

  /// Writes a renewed token back to the stored login, so a launch without a
  /// connection starts with it rather than one that may have expired. Called
  /// on the main queue, like the logins and the logout that write the stored
  /// login. The Keychain is read and written outside the lock, which every
  /// request takes.
  func persistRenewedToken() {
    let session = credentialsLock.withLock { () -> (token: String, userId: String?)? in
      guard tokenNeedsPersisting, let token = ndToken, !token.isEmpty else { return nil }
      return (token, userId)
    }
    guard let session, case .found(let stored) = KeychainManager.loadAuth(),
      stored.id == session.userId
    else { return }

    let renewed = UserAuth(
      id: stored.id, username: stored.username, name: stored.name, isAdmin: stored.isAdmin,
      lastFMApiKey: stored.lastFMApiKey, subsonicSalt: stored.subsonicSalt,
      subsonicToken: stored.subsonicToken, token: session.token)
    do {
      let jsonData = try JSONEncoder().encode(renewed)
      try KeychainManager.setAuthCreds(newValue: String(decoding: jsonData, as: UTF8.self))
      // A token renewed meanwhile still needs writing.
      credentialsLock.withLock {
        if ndToken == session.token { tokenNeedsPersisting = false }
      }
      debugLog("navidrome token persisted")
    } catch {
      debugLog("Error saving renewed token to Keychain: \(error)")
    }
  }

  /// A re-login failed: the requests waiting for its token give up now rather
  /// than at their timeout.
  func abandonRenewal() {
    credentialsLock.lock()
    let waiters = drainWaiters()
    credentialsLock.unlock()
    Self.resume(waiters, renewed: false)
  }

  /// credentialsLock must be held.
  private func drainWaiters() -> [SessionWaiter] {
    let waiters = sessionWaiters
    sessionWaiters = []
    return waiters
  }

  private static func resume(_ waiters: [SessionWaiter], renewed: Bool) {
    for waiter in waiters {
      waiter.timeout.cancel()
      waiter.completion(renewed)
    }
  }

  #if DEBUG
    func invalidateNDTokenForTesting() {
      credentialsLock.lock()
      defer { credentialsLock.unlock() }
      ndToken = "expired"
    }
  #endif

  func clearCreds() {
    credentialsLock.lock()
    credentialGeneration &+= 1
    ndToken = nil
    subsonicParams = nil
    userId = nil
    tokenNeedsPersisting = false
    let waiters = drainWaiters()
    credentialsLock.unlock()
    Self.resume(waiters, renewed: false)
  }

  func login(
    serverUrl: String, username: String, password: String
  ) async throws(AuthError) -> UserAuth {
    let url = "\(serverUrl)\(API.NDEndpoint.login)"
    let parameters: [String: Any] = ["username": username, "password": password]

    let response: DataResponse<UserAuth, AFError> =
      await APIManager.shared.login(endpoint: url, parameters: parameters)
    return try response.result.mapError { AuthError(login: $0, body: response.data) }.get()
  }
}
