//
//  CarPlayController.swift
//  Ownwave
//

import CarPlay
import Combine

/// Ownwave on the car's screen: four tabs over the phone's own player and
/// lists, the lists pushed from them, Now Playing and the alerts. It reads
/// `AppModel.shared`, so the car works with the phone locked and the app
/// never opened, and it lives as long as the car is connected.
@MainActor
final class CarPlayController: NSObject, CPInterfaceControllerDelegate, CPTabBarTemplateDelegate {
  /// Audio apps may stack five templates, the tab bar included
  /// (CPListTemplate documentation).
  static let maxDepth = 5

  /// A tab: its list, how to build it, what changes it, and what its
  /// selection refreshes.
  struct TabScreen {
    let template: CPListTemplate
    let sections: () -> [CPListSection]
    let changes: AnyPublisher<Void, Never>
    var selected: () -> Void = {}
  }

  let interfaceController: CPInterfaceController
  let images: CarPlayImages
  let app = AppModel.shared
  var player: PlayerViewModel { app.player }
  var albums: AlbumViewModel { app.albums }
  /// The car's own station list; each phone screen keeps its own too.
  let radios = RadiosViewModel()
  private(set) var tabBar: CPTabBarTemplate!
  private var tabs: [TabScreen] = []
  /// The pushed song lists; each lives while its template is on the stack.
  private var songLists: [SongListScreen] = []
  /// The template on screen.
  @Published private(set) var visible: CPTemplate?
  var subscriptions = Set<AnyCancellable>()

  init(interfaceController: CPInterfaceController) {
    self.interfaceController = interfaceController
    images = CarPlayImages(traits: interfaceController.carTraitCollection)
    super.init()
    interfaceController.delegate = self
    tabs = Array(
      [homeTab(), libraryTab(), likedTab(), downloadsTab()].prefix(
        CPTabBarTemplate.maximumTabCount))
    tabBar = CPTabBarTemplate(templates: tabs.map(\.template))
    tabBar.delegate = self
    interfaceController.setRootTemplate(tabBar, animated: false, completion: nil)
    for tab in tabs {
      tab.template.updateSections(tab.sections())
      tab.changes
        .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
        .sink { tab.template.updateSections(tab.sections()) }
        .store(in: &subscriptions)
    }
    startNowPlaying()
    observeSession()
    #if DEBUG
      runDebugCarPlay()
    #endif
  }

  /// Lets go of what outlives the controller: the shared Now Playing
  /// template keeps its observers.
  func disconnect() {
    stopNowPlaying()
    subscriptions.removeAll()
  }

  // MARK: - Navigation

  /// Pushes `template`; nothing else pushes. At the depth limit the top
  /// template makes room: Now Playing is shared and the car's own button
  /// brings it back, and a list was one tap away from it.
  func push(_ template: CPTemplate) {
    if interfaceController.templates.count >= Self.maxDepth {
      interfaceController.popTemplate(animated: false, completion: nil)
    }
    interfaceController.pushTemplate(template, animated: true) { _, error in
      if let error { RequestLog.shared.note("carplay: push failed: \(error.localizedDescription)") }
    }
  }

  /// Pushes a song list and keeps it while it is on the stack.
  func push(_ list: SongListScreen) {
    songLists.append(list)
    push(list.template)
  }

  /// Shows Now Playing once something plays: back to it when it is on the
  /// stack already, else on top.
  func showNowPlaying() {
    let nowPlaying = CPNowPlayingTemplate.shared
    if interfaceController.templates.contains(where: { $0 === nowPlaying }) {
      guard interfaceController.topTemplate !== nowPlaying else { return }
      interfaceController.pop(to: nowPlaying, animated: true, completion: nil)
    } else {
      push(nowPlaying)
    }
  }

  func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {
    visible = aTemplate
  }

  func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
    guard songLists.contains(where: { $0.template === aTemplate }) else { return }
    let stack = interfaceController.templates
    songLists.removeAll { list in !stack.contains { $0 === list.template } }
  }

  func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
    tabs.first { $0.template === selectedTemplate }?.selected()
  }
}
