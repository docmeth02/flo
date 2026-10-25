//
//  Errors.swift
//  flo
//

import Alamofire
import Foundation

enum AuthError: Error, Equatable {
  case server(message: String)
  // The server rejected the username or password.
  case invalidCredentials(message: String)
  case sessionExpired
  case unknown
}

struct ErrorResponse: Decodable {
  let error: String
}

extension AuthError {
  /// A failed login. Navidrome's own error body on a 401/403 is a rejected
  /// password and on any other status a server message; a bare 401/403 from
  /// a reverse proxy (expired proxy session, bot challenge) stays a transient
  /// failure that keeps the session.
  init(login error: AFError, body: Data?) {
    let rejected = error.responseCode == 401 || error.responseCode == 403
    if let body, let message = try? JSONDecoder().decode(ErrorResponse.self, from: body).error {
      self = rejected ? .invalidCredentials(message: message) : .server(message: message)
    } else if rejected {
      self = .sessionExpired
    } else if let urlError = error.underlyingError as? URLError {
      self = .server(message: urlError.localizedDescription)
    } else {
      self = .unknown
    }
  }
}

extension AuthError {
  /// What a sign-in screen says. Only a rejected login reads as a wrong
  /// password; a server or network failure says what happened.
  var loginMessage: String {
    switch self {
    case .invalidCredentials: "Wrong username or password."
    case .server(let message): message
    // A bare 401/403 without Navidrome's error body, e.g. from a reverse
    // proxy in front of the server.
    case .sessionExpired: "The server refused the request. Please try again."
    case .unknown: "Unknown error occurred"
    }
  }

  /// A rejected username or password, which marks the password field.
  var isCredentialError: Bool {
    if case .invalidCredentials = self { return true }
    return false
  }
}

extension Result where Failure == Error {
  /// The outcome of an async call, for code that handles both ends in one
  /// place. Runs on the caller's actor, so it adds no hop of its own.
  init(
    isolation: isolated (any Actor)? = #isolation, catching body: () async throws -> Success
  ) async {
    do {
      self = .success(try await body())
    } catch {
      self = .failure(error)
    }
  }
}
