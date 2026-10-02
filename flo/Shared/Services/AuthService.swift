//
//  AuthService.swift
//  flo
//
//  Created by rizaldy on 08/06/24.
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

  private var NDToken: String?
  private var subsonicParams: String?
  private var credentialGeneration: UInt64 = 0
  private let credentialsLock = NSLock()
  // Requests held back until a rejected Navidrome token is replaced.
  private var sessionWaiters: [SessionWaiter] = []

  private struct SessionWaiter {
    let id: UUID
    let completion: (Bool) -> Void
    let timeout: DispatchWorkItem
  }

  private init() {
    if let jsonString = try? KeychainManager.getAuthCreds(),
      let jsonData = jsonString.data(using: .utf8)
    {
      if let data: UserAuth = try? JSONDecoder().decode(UserAuth.self, from: jsonData) {
        NDToken = data.token
        subsonicParams = Self.subsonicQuery(for: data)
        credentialGeneration = 1
      }
    }
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

  func getCreds(key: String = "") -> String {
    let snapshot = sessionSnapshot()
    if key == "NDToken" {
      return snapshot.ndToken
    }

    if key == "subsonicToken" {
      return snapshot.subsonicCredentials
    }

    return ""
  }

  func sessionSnapshot() -> AuthSessionSnapshot {
    credentialsLock.lock()
    defer { credentialsLock.unlock() }
    return AuthSessionSnapshot(
      generation: credentialGeneration,
      ndToken: NDToken ?? "",
      subsonicCredentials: subsonicParams ?? ""
    )
  }

  /// Whether `snapshot` belongs to the login in use. The token itself moves
  /// with every renewal, so only the generation counts.
  func isCurrentSession(_ snapshot: AuthSessionSnapshot) -> Bool {
    sessionSnapshot().generation == snapshot.generation
  }

  func setCreds(_ data: UserAuth) {
    let subsonicParams = Self.subsonicQuery(for: data)

    credentialsLock.lock()
    credentialGeneration &+= 1
    self.NDToken = data.token
    self.subsonicParams = subsonicParams
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
    let token = NDToken ?? ""
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
  /// Kept in memory only: the launch re-login stores a fresh one anyway.
  func adoptRefreshedToken(_ token: String, from snapshot: AuthSessionSnapshot) {
    var token = token.trimmingCharacters(in: .whitespaces)
    if token.hasPrefix("Bearer ") {
      token = String(token.dropFirst("Bearer ".count)).trimmingCharacters(in: .whitespaces)
    }

    credentialsLock.lock()
    // An answer to a request of an earlier login must not replace a newer one.
    guard !token.isEmpty, credentialGeneration == snapshot.generation, NDToken != token else {
      credentialsLock.unlock()
      return
    }
    NDToken = token
    let waiters = drainWaiters()
    credentialsLock.unlock()
    debugLog("navidrome token refreshed")
    Self.resume(waiters, renewed: true)
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
      NDToken = "expired"
    }
  #endif

  func clearCreds() {
    credentialsLock.lock()
    credentialGeneration &+= 1
    NDToken = nil
    subsonicParams = nil
    let waiters = drainWaiters()
    credentialsLock.unlock()
    Self.resume(waiters, renewed: false)
  }

  func login(
    serverUrl: String, username: String, password: String,
    completion: @escaping (AuthResult<UserAuth>) -> Void
  ) {
    // The server the user typed wins over a stored one.
    let baseUrl = serverUrl.isEmpty ? UserDefaultsManager.serverBaseURL : serverUrl
    let url = "\(baseUrl)\(API.NDEndpoint.login)"

    let parameters: [String: Any] = ["username": username, "password": password]

    APIManager.shared.login(endpoint: url, parameters: parameters) {
      (response: DataResponse<UserAuth, AFError>) in
      switch response.result {
      case .success(let authResponse):
        completion(.success(authResponse))
      case .failure(let afError):
        ErrorHandler.handleFailure(afError, response: response) { result in
          let authResult = AuthResult(result: result)

          // A 401/403 carrying Navidrome's own error body is a rejected
          // password; callers must tell it apart from an unreachable server.
          // A bare 401/403 from a reverse proxy (expired proxy session, bot
          // challenge) stays a transient failure and keeps the session.
          guard ErrorHandler.isSessionExpired(error: afError),
            case .failure(.server(let message)) = authResult
          else {
            completion(authResult)
            return
          }

          completion(.failure(.invalidCredentials(message: message)))
        }
      }
    }
  }
}
