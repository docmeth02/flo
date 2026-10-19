//
//  TourOverlay.swift
//  Ownwave
//

import SwiftUI

extension View {
  /// Marks the element the tour's `step` points at.
  func tourAnchor(_ step: TourStep) -> some View {
    anchorPreference(key: TourAnchors.self, value: .bounds) { [step: $0] }
  }

  /// Shows the tour's card for `step` over this view, with the spotlight on
  /// the step's element when it is marked below and on screen.
  func tourOverlay(_ step: TourStep?) -> some View {
    overlayPreferenceValue(TourAnchors.self) { anchors in
      ZStack {
        if let step {
          TourOverlay(step: step, anchors: anchors).transition(.opacity)
        }
      }
      .animation(.easeInOut(duration: 0.25), value: step == nil)
    }
  }
}

private struct TourAnchors: PreferenceKey {
  static let defaultValue: [TourStep: Anchor<CGRect>] = [:]

  static func reduce(
    value: inout [TourStep: Anchor<CGRect>], nextValue: () -> [TourStep: Anchor<CGRect>]
  ) {
    value.merge(nextValue()) { $1 }
  }
}

/// A dimmed backdrop with a rounded cut-out around the step's element, and the
/// step's card above or below it, or centred when the element is not shown.
/// The backdrop takes every touch, so only the card can be used.
private struct TourOverlay: View {
  let step: TourStep
  let anchors: [TourStep: Anchor<CGRect>]

  @EnvironmentObject private var app: AppModel
  @Environment(\.palette) private var palette
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  // The step the spotlight and card show. It follows `step` after the screen
  // it navigated to has settled, as a pushed screen or the cover slides in.
  @State private var shown: TourStep?

  /// The design's backdrop, the same in both schemes.
  private static let scrim = Color(hex: 0x06040E).opacity(0.72)
  private static let padding: CGFloat = 8
  private static let gap: CGFloat = 14
  /// Less room than this beside the element puts the card in the middle.
  private static let minRoom: CGFloat = 200

  var body: some View {
    // The outer reader only tells the safe area the overlay itself ignores.
    GeometryReader { safeArea in
      GeometryReader { proxy in
        let bounds = CGRect(origin: .zero, size: proxy.size)
        let hole = shown.flatMap { anchors[$0] }.map { proxy[$0] }
          .flatMap { Self.visible($0, in: bounds) }?
          .insetBy(dx: -Self.padding, dy: -Self.padding)
        ZStack {
          spotlight(hole, in: bounds)
            // Reduce Motion fades the spotlight from one element to the next.
            .id(reduceMotion ? shown : nil)
            .transition(.opacity)
          if shown == step {
            place(card, around: hole, in: proxy.size, insets: safeArea.safeAreaInsets)
              .transition(.opacity)
          }
        }
        .animation(motion, value: hole)
      }
      .ignoresSafeArea()
    }
    .animation(.easeInOut(duration: 0.2), value: step)
    .task(id: step) {
      // A step left within the wait must not show after the next one.
      guard (try? await Task.sleep(for: .seconds(0.45))) != nil else { return }
      withAnimation(motion) { shown = step }
    }
  }

  private var motion: Animation {
    reduceMotion ? .easeInOut(duration: 0.3) : .smooth(duration: 0.35)
  }

  /// The element's frame, unless most of it is off screen.
  private static func visible(_ frame: CGRect, in bounds: CGRect) -> CGRect? {
    let inside = frame.intersection(bounds)
    return !inside.isNull && inside.height >= frame.height / 2 && frame.height > 0 ? frame : nil
  }

  private func spotlight(_ hole: CGRect?, in bounds: CGRect) -> some View {
    // Without an element the cut-out shrinks to the middle.
    let cutout = hole ?? CGRect(x: bounds.midX, y: bounds.midY, width: 0, height: 0)
    return ZStack {
      SpotlightScrim(hole: cutout)
        .fill(Self.scrim, style: FillStyle(eoFill: true))
        .contentShape(Rectangle())
        .onTapGesture {}
      RoundedRectangle(cornerRadius: 20, style: .continuous)
        .strokeBorder(palette.accent, lineWidth: 2)
        .frame(width: cutout.width + 4, height: cutout.height + 4)
        .position(x: cutout.midX, y: cutout.midY)
        .opacity(hole == nil ? 0 : 1)
        .allowsHitTesting(false)
    }
    .accessibilityHidden(true)
  }

  /// Below an element in the upper half, above one in the lower half;
  /// centred without one, or when large text leaves that side too little
  /// room. The card stays inside the safe area.
  private func place(
    _ card: some View, around hole: CGRect?, in size: CGSize, insets: EdgeInsets
  ) -> some View {
    let top = insets.top + 16
    let bottom = size.height - insets.bottom - 16
    var alignment = Alignment.center
    var edges = EdgeInsets(top: top, leading: 16, bottom: size.height - bottom, trailing: 16)
    if let hole {
      let below = hole.midY <= size.height / 2
      if below, bottom - hole.maxY - Self.gap >= Self.minRoom {
        alignment = .top
        edges.top = max(top, hole.maxY + Self.gap)
      } else if !below, hole.minY - Self.gap - top >= Self.minRoom {
        alignment = .bottom
        edges.bottom = size.height - min(bottom, hole.minY - Self.gap)
      }
    }
    return
      card
      .frame(maxHeight: size.height - edges.top - edges.bottom, alignment: alignment)
      .padding(edges)
  }

  private var card: some View {
    let isLast = step.next == nil
    return VStack(alignment: .leading, spacing: 6) {
      Text("\(step.rawValue + 1) of \(TourStep.allCases.count)")
        .font(.counter)
        .tracking(0.1 * 11)
        .textCase(.uppercase)
        .foregroundStyle(palette.accent)
      Text(step.title)
        .font(.sectionTitle)
        .tracking(-0.02 * 21)
      // Large text scrolls inside the card instead of pushing it off screen.
      ViewThatFits(in: .vertical) {
        message
        ScrollView { message }.scrollBounceBehavior(.basedOnSize)
      }
      HStack {
        if !isLast {
          Button("Skip tour") { app.tour = nil }
            .font(.rowSubtitle.weight(.semibold))
            .foregroundStyle(palette.secondary)
            .padding(.vertical, 10)
            .padding(.horizontal, 4)
        }
        Spacer()
        Button {
          app.tour = step.next
        } label: {
          Text(isLast ? "Done" : "Next").padding(.horizontal, 22)
        }
        .buttonStyle(FillButtonStyle(height: 44))
        .fixedSize()
      }
      .buttonStyle(.plain)
      .padding(.top, 10)
    }
    .padding(EdgeInsets(top: 18, leading: 18, bottom: 14, trailing: 18))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .shadow(color: .black.opacity(0.45), radius: 25, y: 20)
    .accessibilityElement(children: .contain)
    .accessibilityAddTraits(.isModal)
  }

  private var message: some View {
    Text(step.text)
      .font(.rowSubtitle)
      .lineSpacing(4)
      .foregroundStyle(palette.secondary)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// The whole screen with a rounded hole, drawn even-odd; the hole animates
/// from one element to the next.
private struct SpotlightScrim: Shape {
  var hole: CGRect

  var animatableData: CGRect.AnimatableData {
    get { hole.animatableData }
    set { hole.animatableData = newValue }
  }

  func path(in rect: CGRect) -> Path {
    var path = Path(rect)
    path.addRoundedRect(in: hole, cornerSize: CGSize(width: 18, height: 18), style: .continuous)
    return path
  }
}
