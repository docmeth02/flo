//    flo

import Foundation
import Combine

class RadiosViewModel: ObservableObject {
  @Published var radios: [Radio] = []
  
  @Published var isLoading = false
  @Published var error: Error?
  
  func fetchAllRadios(completion: @escaping () -> Void = {}) {
    isLoading = true
    error = nil

    RadioService.shared.getAllRadios { result in
      DispatchQueue.main.async {
        self.isLoading = false
        
        switch result {
        case .success(let radios):
          self.radios = radios
          
        case .failure(let error):
          self.error = error
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
