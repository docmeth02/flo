//
//  KeychainManager.swift
//  flo
//
//  Created by rizaldy on 09/06/24.
//

import Foundation
import KeychainAccess

/// One read of a Keychain item. A read error is not a missing item: the item
/// may well be there and readable on the next attempt.
enum KeychainRead<Value> {
  case found(Value)
  case missing
  case unreadable(Error)

  /// The item `read` returns, as `parse` makes it. An item `parse` rejects
  /// counts as missing, since reading it again cannot repair it.
  init(_ read: () throws -> String?, parse: (String) -> Value?) {
    let item: String?
    do {
      item = try read()
    } catch {
      self = .unreadable(error)
      return
    }
    self = item.flatMap(parse).map { .found($0) } ?? .missing
  }
}

/// Credentials live in the Keychain, readable after first unlock and never
/// migrated to another device.
class KeychainManager {
  private static let keychain = Keychain(service: KeychainKeys.service)
    .accessibility(.afterFirstUnlockThisDeviceOnly)

  /// The stored login of the account in use.
  static func loadAuth() -> KeychainRead<UserAuth> {
    KeychainRead({ try keychain.get(KeychainKeys.dataKey) }) { json in
      do {
        return try JSONDecoder().decode(UserAuth.self, from: Data(json.utf8))
      } catch {
        debugLog("stored login is not a login: \(error)")
        return nil
      }
    }
  }

  /// The password saved for silent re-logins.
  static func loadPassword() -> KeychainRead<String> {
    KeychainRead({ try keychain.get(KeychainKeys.serverPassword) }) { $0.isEmpty ? nil : $0 }
  }

  static func removeAuthCreds() throws {
    try keychain.remove(KeychainKeys.dataKey)
  }

  static func removeAuthPassword() throws {
    try keychain.remove(KeychainKeys.serverPassword)
  }

  static func getServerURL() throws -> String? {
    return try keychain.get(KeychainKeys.serverURL)
  }

  static func setServerURL(newValue: String) throws {
    try keychain.set(newValue, key: KeychainKeys.serverURL)
  }

  static func removeServerURL() throws {
    try keychain.remove(KeychainKeys.serverURL)
  }

  static func setAuthCreds(newValue: String) throws {
    try keychain.set(newValue, key: KeychainKeys.dataKey)
  }

  static func setAuthPassword(newValue: String) throws {
    try keychain.set(newValue, key: KeychainKeys.serverPassword)
  }
}

