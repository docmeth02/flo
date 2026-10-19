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
