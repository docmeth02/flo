//
//  Chips.swift
//  Ownwave
//

import SwiftUI

/// The design's quiet chips, Library's lists and Taste's parts: the chosen
/// one filled in the text color, the others on the platter. They scroll
/// sideways to the screen's edges and keep the chosen one in view.
struct ChipBar<Value: Hashable>: View {
  let options: [(value: Value, label: String, systemImage: String?)]
  @Binding var selection: Value

  @Environment(\.palette) private var palette

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(options, id: \.value) { option in
            chip(option).id(option.value)
          }
        }
        .padding(.horizontal, 16)
      }
      .padding(.horizontal, -16)
      .onAppear { proxy.scrollTo(selection) }
      .onChange(of: selection) { withAnimation { proxy.scrollTo(selection) } }
    }
  }

  private func chip(_ option: (value: Value, label: String, systemImage: String?)) -> some View {
    let isOn = option.value == selection
    return Button {
      selection = option.value
    } label: {
      HStack(spacing: 5) {
        if let systemImage = option.systemImage {
          Image(systemName: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isOn ? palette.background : Color.floLiked)
        }
        Text(option.label)
      }
      .font(.rowSubtitle.weight(.semibold))
      .foregroundStyle(isOn ? palette.background : palette.text)
      .padding(.horizontal, 15)
      .padding(.vertical, 9)
      .background(isOn ? palette.text : palette.surface, in: Capsule())
      .contentShape(Capsule())
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isOn ? .isSelected : [])
    .animation(.snappy(duration: 0.2), value: isOn)
  }
}

/// A list's count on the left and, when it can be sorted, its order on the
/// right: "48 albums · Recently added ⌄".
struct ListHeader<Order: Hashable>: View {
  let count: String
  var orders: [(value: Order, label: String)] = []
  var order: Binding<Order>?

  @Environment(\.palette) private var palette

  var body: some View {
    HStack {
      Text(count).foregroundStyle(palette.secondary)
      Spacer(minLength: 8)
      if let order, !orders.isEmpty {
        Menu {
          Picker("Sort", selection: order) {
            ForEach(orders, id: \.value) { Text($0.label).tag($0.value) }
          }
        } label: {
          HStack(spacing: 4) {
            Text(orders.first { $0.value == order.wrappedValue }?.label ?? "")
            Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
          }
          .foregroundStyle(palette.accent)
        }
        .accessibilityLabel("Sort")
      }
    }
    .font(.rowSubtitle.weight(.medium))
    .padding(.horizontal, 4)
  }
}

extension ListHeader where Order == Int {
  /// A count alone, for lists without an order to pick.
  init(count: String) {
    self.count = count
  }
}
