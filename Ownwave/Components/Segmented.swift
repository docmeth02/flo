//
//  Segmented.swift
//  Ownwave
//

import SwiftUI

/// The design's segmented control: the chosen option on the fill with ink,
/// or, `filled` false, on the second platter color.
struct Segmented<Value: Hashable>: View {
  let options: [(value: Value, label: String)]
  @Binding var selection: Value
  var filled = true
  var font = Font.rowSubtitle.weight(.semibold)

  @Environment(\.palette) private var palette

  var body: some View {
    HStack(spacing: 2) {
      ForEach(options, id: \.value) { option in
        let isOn = option.value == selection
        Button {
          selection = option.value
        } label: {
          Text(option.label)
            .font(font)
            .foregroundStyle(
              isOn
                ? (filled ? palette.ink : palette.text)
                : (filled ? palette.text : palette.secondary)
            )
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
              isOn ? (filled ? palette.fill : palette.surface2) : .clear,
              in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
      }
    }
    .padding(3)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    .animation(.snappy(duration: 0.2), value: selection)
  }
}
