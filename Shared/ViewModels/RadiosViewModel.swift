//
//  RadiosViewModel.swift
//  flo
//

import Combine
import Foundation

class RadiosViewModel: ObservableObject {
  @Published var radios: [Radio] = []
  @Published private(set) var state = ListState()

  /// The task ends once the answer is shown.
  @discardableResult
  func fetchAllRadios() -> Task<Void, Never> {
    state = ListState(isLoading: true)

    return Task { @MainActor in
      do {
        self.radios = try await RadioService.shared.getAllRadios()
        self.state = ListState(loadedAt: Date())
      } catch {
        self.state = ListState(failed: true)
      }
    }
  }

  @MainActor func refresh() async {
    await fetchAllRadios().value
  }
}
