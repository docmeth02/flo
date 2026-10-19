//
//  WidgetGallery.swift
//  Ownwave
//

#if DEBUG
  import SwiftUI
  import UIKit
  import WidgetKit

  // Simulator verification only: simctl cannot place widgets, so
  // FLO_DEBUG_SCREEN=widgets shows every widget at its family size on a
  // wallpaper, for screenshots. It reads the snapshot the app wrote (sample
  // content while there is none) and rereads it every second, so a mix
  // started with FLO_DEBUG_PLAY_SOMETHING shows up. FLO_DEBUG_WIDGETS=empty
  // shows the signed-in widgets with nothing played, =signedout signed out.
  struct WidgetGallery: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        let snapshot = Self.snapshot
        VStack(spacing: 22) {
          HStack(spacing: 16) {
            tile(.systemSmall) { PlaySomethingWidgetView(snapshot: snapshot) }
            tile(.systemSmall) { NowPlayingWidgetView(snapshot: snapshot, family: .systemSmall) }
          }
          tile(.systemMedium) { NowPlayingWidgetView(snapshot: snapshot, family: .systemMedium) }
          tile(.systemMedium) { RecentlyPlayedWidgetView(snapshot: snapshot) }
          HStack(spacing: 16) {
            tile(.systemSmall) { LauncherWidgetView() }
            Color.clear.frame(width: 170, height: 170)
          }
          Spacer(minLength: 0)
        }
        .padding(.top, 72)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(wallpaper)
      }
    }

    private static var snapshot: WidgetSnapshot {
      switch ProcessInfo.processInfo.environment["FLO_DEBUG_WIDGETS"] {
      case "empty": return WidgetSnapshot(signedIn: true)
      case "signedout": return WidgetSnapshot()
      default:
        let written = WidgetSnapshot.load()
        return written.signedIn ? written : .sample
      }
    }

    private func tile(_ family: WidgetFamily, @ViewBuilder _ content: () -> some View) -> some View
    {
      content()
        .frame(width: family == .systemSmall ? 170 : 364, height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 15, y: 10)
    }

    /// The design's dusk wallpaper, or a pale one in light mode.
    private var wallpaper: some View {
      let colors =
        scheme == .dark
        ? [Color(hex: 0x3A2E5C), Color(hex: 0x0B0A14)]
        : [Color(hex: 0xD9CFF2), Color(hex: 0xF3F1FA)]
      return LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom).ignoresSafeArea()
    }

    /// Covers whatever the app shows, from the debug screen hook.
    @MainActor static func present() {
      let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
      guard var top = scene?.keyWindow?.rootViewController else { return }
      while let presented = top.presentedViewController { top = presented }
      let host = UIHostingController(rootView: WidgetGallery())
      host.modalPresentationStyle = .fullScreen
      top.present(host, animated: false)
    }
  }
#endif
