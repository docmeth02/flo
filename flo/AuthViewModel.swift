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

  @Published var serverUrl: String = "" {
    didSet {
      validateURL()
    }
  }

  @Published var username: String = ""
  @Published var password: String = ""

  @Published var showAlert: Bool = false
  @Published var alertMessage: String = ""
  @Published var extraMessage: String = ""
  @Published var experimentalSaveLoginInfo: Bool = false

  @Published var isSubmitting: Bool = false
  @Published var isLoggedIn: Bool = false

  // Bumped by every interactive login and logout; a background session
  // refresh only persists its result while the generation is unchanged.
  private var sessionGeneration: Int = 0

  static let shared = AuthViewModel()

  private func validateURL() {
    if serverUrl.lowercased().hasPrefix("http://") {
      extraMessage =
        "http:// is only supported within private IP ranges: 192.168.0.0/16, 10.0.0.0/8, and 172.16.0.0/12 — learn more at https://dub.sh/flo-ats"
    } else {
      extraMessage = ""
    }
  }

  init() {
    // TODO: invalidate authz token somewhere here
    do {
      if let jsonString = try KeychainManager.getAuthCreds(),
        let jsonData = jsonString.data(using: .utf8)
      {
        let data: UserAuth = try JSONDecoder().decode(UserAuth.self, from: jsonData)

        self.serverUrl = UserDefaultsManager.serverBaseURL
        self.username = data.username

        if UserDefaultsManager.saveLoginInfo {
          do {
            self.password = try KeychainManager.getAuthPassword() ?? ""
          } catch {
            print("Error loading password from Keychain: \(error)")
          }

          // Trust cached creds immediately — a cold launch must never block on
          // a login that can only time out while offline. Refresh the session
          // once the first real connectivity verdict lands; a stale session
          // surfaces as a 401 on the first call after that.
          // AuthService.shared reads creds from Keychain on first access — no setCreds needed.
          self.user = UserAuth(
            id: data.id, username: data.username, name: data.name, isAdmin: data.isAdmin,
            lastFMApiKey: data.lastFMApiKey)
          self.isLoggedIn = true

          ConnectivityMonitor.shared.onFirstVerdict { [weak self] online in
            if online { self?.refreshSession() }
          }
        } else {

          self.user = UserAuth(
            id: data.id, username: data.username, name: data.name, isAdmin: data.isAdmin,
            lastFMApiKey: data.lastFMApiKey)
          self.isLoggedIn = true
        }
      }
    } catch {
      print("Error loading data from Keychain: \(error)")
    }
  }

  // Non-interactive session refresh after the optimistic cached login: no
  // spinner, no alerts, no form-field resets. Any failure keeps the cached
  // session — a transport error is indistinguishable from a rejected
  // credential here (ErrorHandler maps URLErrors to .server too), and stale
  // credentials surface as 401s on real calls where the user can act.
  private func refreshSession() {
    // A delayed connectivity verdict can arrive after a logout, when the form
    // fields may already hold half-typed credentials for another account.
    guard isLoggedIn else { return }
    let generation = sessionGeneration

    AuthService.shared.login(serverUrl: serverUrl, username: username, password: password) {
      [weak self] result in
      DispatchQueue.main.async {
        // The generation check drops a refresh that outlived its session —
        // a logout or an interactive login into another account must never
        // be overwritten by this stale completion.
        guard let self = self, self.isLoggedIn, self.sessionGeneration == generation,
          case .success(let data) = result
        else { return }
        self.persistAuthData(data)
      }
    }
  }

  func login() {
    sessionGeneration += 1
    isSubmitting = true

    AuthService.shared.login(serverUrl: serverUrl, username: username, password: password) {
      result in
      switch result {
      case .success(let data):
        self.persistAuthData(data)

        if self.experimentalSaveLoginInfo {
          do {
            try KeychainManager.setAuthPassword(newValue: self.password)
            UserDefaultsManager.saveLoginInfo = true

            self.experimentalSaveLoginInfo = false
          } catch {
            print("error saving password to Keychain: \(error)")
          }
        }

        DispatchQueue.main.async {
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
          case .server(let message):
            self.alertMessage = message

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

      self.destroySavedPassword()

      UserDefaultsManager.removeObject(key: UserDefaultsKeys.serverURL)

      self.user = nil
      self.isLoggedIn = false
    } catch let error {
      print("error>>>>> \(error)")
    }
  }

  func destroySavedPassword() {
    do {
      try KeychainManager.removeAuthPassword()

      UserDefaultsManager.saveLoginInfo = false
      UserDefaultsManager.removeObject(key: UserDefaultsKeys.saveLoginInfo)
    } catch let error {
      print("error>>>>> \(error)")
    }
  }

  func persistAuthData(_ data: UserAuth) {
    do {
      let jsonData = try JSONEncoder().encode(data)
      let jsonString = String(data: jsonData, encoding: .utf8)!

      try KeychainManager.setAuthCreds(newValue: jsonString)

      AuthService.shared.setCreds(data)
      UserDefaultsManager.serverBaseURL = self.serverUrl

      self.user = UserAuth(
        id: data.id, username: data.username, name: data.name, isAdmin: data.isAdmin,
        lastFMApiKey: data.lastFMApiKey)
    } catch {
      print("Error saving data to Keychain: \(error)")
    }
  }
}
