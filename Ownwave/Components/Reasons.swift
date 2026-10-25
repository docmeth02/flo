//
//  Reasons.swift
//  Ownwave
//

import SwiftUI

/// Why the mix picked a song, behind its kind's icon: the short label in an
/// Up Next row, the whole note on Now Playing.
struct ReasonLabel: View {
  let reason: MixReason
  var isShort = true

  @Environment(\.colorScheme) private var scheme

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: reason.kind.systemImage)
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(reason.kind.color(scheme))
      Text(isShort ? reason.label : reason.note)
    }
    .lineLimit(1)
  }
}
