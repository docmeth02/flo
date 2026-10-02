//
//  APIManager.swift
//  flo
//
//  Created by rizaldy on 08/06/24.
//

import Alamofire
import Foundation

class APIManager {
  static let shared = APIManager()

  private(set) var session: Alamofire.Session

  private init() {
    session = Self.createSession()
  }

  private static func createSession() -> Session {
    let configuration = URLSessionConfiguration.default
    configuration.timeoutIntervalForRequest = 30

    return Alamofire.Session(
      configuration: configuration, interceptor: NDSessionInterceptor())
  }

  func NDEndpointRequest<T: Decodable>(
    endpoint: String, method: HTTPMethod = .get, parameters: Parameters?,
    encoding: ParameterEncoding = URLEncoding.queryString, timeout: TimeInterval? = nil,
    completion: @escaping (DataResponse<T, AFError>) -> Void
  ) {
    let authSession = AuthService.shared.sessionSnapshot()
    let token = authSession.ndToken

    let url = "\(UserDefaultsManager.serverBaseURL)\(endpoint)"
    let headers: HTTPHeaders = [API.NDAuthHeader: "Bearer \(token)"]

    session.request(
      url, method: method, parameters: parameters, encoding: encoding, headers: headers,
      requestModifier: { request in
        if let timeout = timeout {
          request.timeoutInterval = timeout
        }
      }
    )
    .validate(statusCode: 200..<300)
    .responseDecodable(of: T.self) { response in
      if response.error == nil,
        let refreshed = response.response?.value(forHTTPHeaderField: "X-Nd-Authorization")
      {
        AuthService.shared.adoptRefreshedToken(refreshed, from: authSession)
      }
      ConnectivityMonitor.shared.record(
        response: response.response, error: response.error?.underlyingError)
      completion(response)
    }
  }

  func SubsonicEndpointRequest<T: Decodable>(
    endpoint: String, method: HTTPMethod = .get, parameters: Parameters?,
    encoding: ParameterEncoding = URLEncoding.queryString, timeout: TimeInterval? = nil,
    completion: @escaping (DataResponse<T, AFError>) -> Void
  ) {

    // FIXME: refactor getCreds(key: "subsonicToken")
    let authSession = AuthService.shared.sessionSnapshot()
    let url =
      "\(UserDefaultsManager.serverBaseURL)\(endpoint)\(authSession.subsonicCredentials)"

    session.request(
      url, method: method, parameters: parameters, encoding: encoding,
      requestModifier: { request in
        if let timeout = timeout {
          request.timeoutInterval = timeout
        }
      }
    )
    .validate(statusCode: 200..<300)
    .responseDecodable(of: T.self) { response in
      Self.notifyIfSessionExpired(
        response: response.response, error: response.error, authSession: authSession)
      ConnectivityMonitor.shared.record(
        response: response.response, error: response.error?.underlyingError)
      completion(response)
    }
  }

  // FIXME: refactor later
  func SubsonicEndpointDownloadNew(
    endpoint: String, method: HTTPMethod = .get, parameters: Parameters?,
    encoding: ParameterEncoding = URLEncoding.queryString,
    progressUpdate: ((Double) -> Void)?,
    completion: @escaping (Result<URL, AFError>) -> Void
  ) -> DownloadRequest {

    // FIXME: refactor getCreds(key: "subsonicToken")
    let url =
      "\(UserDefaultsManager.serverBaseURL)\(endpoint)\(AuthService.shared.getCreds(key: "subsonicToken"))"

    return session.download(
      url, method: method, parameters: parameters, encoding: encoding,
      requestModifier: { $0.timeoutInterval = 60 }
    )
    .downloadProgress { progressValue in
      progressUpdate?(progressValue.fractionCompleted * 100)
    }
    .validate()
    .responseURL { response in
      switch response.result {
      case .success(let fileURL):
        completion(.success(fileURL))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func SubsonicEndpointDownload(
    endpoint: String, method: HTTPMethod = .get, parameters: Parameters?,
    encoding: ParameterEncoding = URLEncoding.queryString,
    completion: @escaping (Result<URL, AFError>) -> Void
  ) {

    // FIXME: refactor getCreds(key: "subsonicToken")
    let url =
      "\(UserDefaultsManager.serverBaseURL)\(endpoint)\(AuthService.shared.getCreds(key: "subsonicToken"))"

    session.download(
      url, method: method, parameters: parameters, encoding: encoding,
      requestModifier: { $0.timeoutInterval = 60 }
    )
    .validate()
    .responseURL { response in
      switch response.result {
      case .success(let fileURL):
        completion(.success(fileURL))
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }
}

/// One retry for transient connection failures. Time-outs are not retried,
/// since the watch already waited the full request timeout, and scrobbles
/// never are: a lost response would submit the same listen again.
final class WatchRetryPolicy: RetryPolicy {
  init() {
    var codes = RetryPolicy.defaultRetryableURLErrorCodes
    codes.remove(.timedOut)
    super.init(retryLimit: 1, retryableURLErrorCodes: codes)
  }

  override func shouldRetry(request: Request, dueTo error: Error) -> Bool {
    if request.request?.url?.path.hasSuffix(API.SubsonicEndpoint.scrobble) == true {
      return false
    }
    return super.shouldRetry(request: request, dueTo: error)
  }
}

/// Renews Navidrome sessions in place: a 401/403 on an /api request is
/// retried once after the re-login triggered by .sessionExpired, and requests
/// created meanwhile wait for the new token. Connection failures fall back to
/// WatchRetryPolicy. Subsonic requests, downloads and the login call carry no
/// X-ND-Authorization header and pass through untouched.
final class NDSessionInterceptor: RequestInterceptor {
  private let fallback = WatchRetryPolicy()
  private let renewalTimeout: TimeInterval = 15
  private let lock = NSLock()
  // The token a server rejected; requests carrying it wait for its successor.
  private var rejectedToken: String?

  func adapt(
    _ urlRequest: URLRequest, for session: Session,
    completion: @escaping (Result<URLRequest, Error>) -> Void
  ) {
    guard Self.bearerToken(in: urlRequest) != nil else {
      completion(.success(urlRequest))
      return
    }
    let snapshot = AuthService.shared.sessionSnapshot()
    guard !snapshot.ndToken.isEmpty else {
      completion(.success(urlRequest))
      return
    }
    let rejected = lock.withLock { rejectedToken }
    guard rejected == snapshot.ndToken else {
      completion(.success(Self.applying(snapshot.ndToken, to: urlRequest)))
      return
    }
    AuthService.shared.waitForRenewedSession(after: snapshot, timeout: renewalTimeout) { _ in
      let token = AuthService.shared.sessionSnapshot().ndToken
      completion(.success(token.isEmpty ? urlRequest : Self.applying(token, to: urlRequest)))
    }
  }

  // Alamofire may ask twice for one failure (validation, then serialization),
  // so this answers right away; the waiting happens in adapt.
  func retry(
    _ request: Request, for session: Session, dueTo error: Error,
    completion: @escaping (RetryResult) -> Void
  ) {
    guard let status = request.response?.statusCode, status == 401 || status == 403,
      request is DataRequest, let sent = Self.bearerToken(in: request.request)
    else {
      fallback.retry(request, for: session, dueTo: error, completion: completion)
      return
    }
    let current = AuthService.shared.sessionSnapshot()
    guard request.retryCount == 0, !current.ndToken.isEmpty else {
      fallback.retry(request, for: session, dueTo: error, completion: completion)
      return
    }
    if sent == current.ndToken {
      lock.withLock { rejectedToken = sent }
    }
    // AuthViewModel ignores the notice while a re-login is under way.
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .sessionExpired, object: current)
    }
    debugLog("session rejected, retrying \(request.request?.url?.path ?? "") after re-login")
    completion(.retry)
  }

  private static func bearerToken(in request: URLRequest?) -> String? {
    guard var value = request?.headers.value(for: API.NDAuthHeader) else { return nil }
    if value.hasPrefix("Bearer ") { value.removeFirst("Bearer ".count) }
    return value.isEmpty ? nil : value
  }

  private static func applying(_ token: String, to request: URLRequest) -> URLRequest {
    var request = request
    request.headers.update(name: API.NDAuthHeader, value: "Bearer \(token)")
    return request
  }
}

extension APIManager {
  /// Posts .sessionExpired when the underlying HTTP response is 401/403.
  /// Covers Subsonic requests; NDSessionInterceptor covers /api.
  fileprivate static func notifyIfSessionExpired(
    response: HTTPURLResponse?, error: AFError?, authSession: AuthSessionSnapshot
  ) {
    let status = response?.statusCode ?? error?.responseCode
    guard let code = status, code == 401 || code == 403 else { return }
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: .sessionExpired, object: authSession)
    }
  }

  func login<T: Decodable>(
    endpoint: String, parameters: Parameters?,
    completion: @escaping (DataResponse<T, AFError>) -> Void
  ) {
    session.request(
      endpoint,
      method: .post,
      parameters: parameters,
      encoding: JSONEncoding.default,
      requestModifier: { request in
        request.timeoutInterval = 10
      }
    )
    .validate(statusCode: 200..<300)
    .responseDecodable(of: T.self) { response in
      completion(response)
    }
  }
}

extension Notification.Name {
  static let sessionExpired = Notification.Name("flo.sessionExpired")
  static let didLogout = Notification.Name("flo.didLogout")
}
