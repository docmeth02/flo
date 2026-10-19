//
//  EnvironmentAction.swift
//  Ownwave
//

/// An action handed down through the environment, in a struct like SwiftUI's
/// own (DismissAction, OpenURLAction): `@Entry` warns about a bare closure.
struct EnvironmentAction<Input> {
  private let action: (Input) -> Void

  init(_ action: @escaping (Input) -> Void) { self.action = action }

  func callAsFunction(_ input: Input) { action(input) }
}

extension EnvironmentAction where Input == Void {
  func callAsFunction() { action(()) }
}
