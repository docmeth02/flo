//
//  KeychainManager.swift
//  flo
//
//  Created by rizaldy on 09/06/24.
//

import Foundation
import KeychainAccess

/// Credentials live in the Keychain, readable after first unlock and never
/// migrated to another device.
class KeychainManager {
  private static let keychain = Keychain(service: KeychainKeys.service)
    .accessibility(.afterFirstUnlockThisDeviceOnly)


  static func getAuthCreds() throws -> String? {
    return try keychain.get(KeychainKeys.dataKey)
  }

  static func getAuthPassword() throws -> String? {
    return try keychain.get(KeychainKeys.serverPassword)
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

