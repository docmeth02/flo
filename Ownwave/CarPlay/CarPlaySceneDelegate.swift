//
//  CarPlaySceneDelegate.swift
//  Ownwave
//

import CarPlay

/// The car's screen: one controller for as long as the car is connected.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
  private var controller: CarPlayController?

  func templateApplicationScene(
    _ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController
  ) {
    controller = CarPlayController(interfaceController: interfaceController)
  }

  func templateApplicationScene(
    _ scene: CPTemplateApplicationScene,
    didDisconnectInterfaceController interfaceController: CPInterfaceController
  ) {
    controller?.disconnect()
    controller = nil
  }
}
