//
//  RadiosViewModel.swift
//  flo
//

import Foundation
import Combine

class RadiosViewModel: ObservableObject {
  @Published var radios: [Radio] = []
  @Published private(set) var state = ListState()

  func fetchAllRadios(completion: @escaping () -> Void = {}) {
    state = ListState(isLoading: true)

    RadioService.shared.getAllRadios { result in
      DispatchQueue.main.async {
        switch result {
        case .success(let radios):
          self.radios = radios
          self.state = ListState(loadedAt: Date())

        case .failure:
          self.state = ListState(failed: true)
        }
        completion()
      }
    }
  }

  @MainActor func refresh() async {
    await withCheckedContinuation { continuation in
      fetchAllRadios { continuation.resume() }
    }
  }
}
