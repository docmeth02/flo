//
//  RadiosViewModel.swift
//  Ownwave
//

import Combine
import Foundation

/// The server's internet radio stations, one list per app for its screens
/// (and the car).
@MainActor
final class RadiosViewModel: ObservableObject {
  @Published private(set) var radios: [Radio] = []
  @Published private(set) var state = ListState()

  private var loading: Task<Void, Never>?
  /// Bumped by `reset()`, so an answer for the previous account is dropped.
  private var generation = 0

  /// Asks the server unless it is being asked or answered a moment ago.
  func fetchAllRadios() {
    if let loadedAt = state.loadedAt, Date().timeIntervalSince(loadedAt) < ListState.reloadAfter {
      return
    }
    load()
  }

  /// Asks the server again, or waits for the answer under way.
  func refresh() async {
    await load().value
  }

  /// Forgets the stations, for the next account.
  func reset() {
    generation += 1
    loading = nil
    radios = []
    state = ListState()
  }

  /// The fetch under way, else a new one; it ends once the answer is shown.
  @discardableResult
  private func load() -> Task<Void, Never> {
    if let loading { return loading }
    let generation = generation
    state = ListState(isLoading: true)
    let task = Task {
      let result = await Result { try await RadioService.shared.getAllRadios() }
      guard generation == self.generation else { return }
      loading = nil
      switch result {
      case .success(let radios):
        self.radios = radios
        state = ListState(loadedAt: Date())
      case .failure:
        state = ListState(failed: true)
      }
    }
    loading = task
    return task
  }
}
