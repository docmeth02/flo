//
//  PendingEdits.swift
//  flo
//

import Foundation

/// Edits made on the watch that the server has not confirmed yet, kept
/// across launches and sent while the server is reachable. Shared by the
/// ratings and the stars.
@MainActor final class PendingEdits<Value: Equatable> {}
