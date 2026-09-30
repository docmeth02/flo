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

  private init() {
    if let jsonString = try? KeychainManager.getAuthCreds(),
      let jsonData = jsonString.data(using: .utf8)
    {
      if let data: UserAuth = try? JSONDecoder().decode(UserAuth.self, from: jsonData) {
        NDToken = data.token
        subsonicParams =
          "?u=\(data.username)&t=\(data.subsonicToken)&s=\(data.subsonicSalt)&v=\(AppMeta.subsonicApiVersion)&c=\(AppMeta.name)&f=json"
        credentialGeneration = 1
      }
    }
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

  func isCurrentSession(_ snapshot: AuthSessionSnapshot) -> Bool {
    sessionSnapshot() == snapshot
  }

  func setCreds(_ data: UserAuth) {
    let subsonicParams =
      "?u=\(data.username)&t=\(data.subsonicToken)&s=\(data.subsonicSalt)&v=\(AppMeta.subsonicApiVersion)&c=\(AppMeta.name)&f=json"

    credentialsLock.lock()
    defer { credentialsLock.unlock() }
    credentialGeneration &+= 1
    self.NDToken = data.token
    self.subsonicParams = subsonicParams
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
    defer { credentialsLock.unlock() }
    credentialGeneration &+= 1
    NDToken = nil
    subsonicParams = nil
  }

  func login(
    serverUrl: String, username: String, password: String,
    completion: @escaping (AuthResult<UserAuth>) -> Void
  ) {
    let serverBaseUrl = UserDefaultsManager.serverBaseURL
    let isServerBaseURLExist = serverBaseUrl != ""

    let url = "\(isServerBaseURLExist ? serverBaseUrl : serverUrl)\(API.NDEndpoint.login)"

    let parameters: [String: Any] = ["username": username, "password": password]

    APIManager.shared.login(endpoint: url, parameters: parameters) {
      (response: DataResponse<UserAuth, AFError>) in
      switch response.result {
      case .success(let authResponse):
        completion(.success(authResponse))
      case .failure(let afError):
        ErrorHandler.handleFailure(afError, response: response) { result in
          let authResult = AuthResult(result: result)

          // A 401/403 from the login endpoint itself is a rejected password;
          // callers must be able to tell it apart from an unreachable server.
          guard ErrorHandler.isSessionExpired(error: afError), case .failure(let error) = authResult
          else {
            completion(authResult)
            return
          }

          var message = "Invalid username or password."
          if case .server(let serverMessage) = error { message = serverMessage }
          completion(.failure(.invalidCredentials(message: message)))
        }
      }
    }
  }
}
