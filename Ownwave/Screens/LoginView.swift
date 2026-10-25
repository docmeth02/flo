//
//  LoginView.swift
//  Ownwave
//

import SwiftUI

struct LoginView: View {
  @EnvironmentObject private var auth: AuthViewModel
  @Environment(\.palette) private var palette
  @FocusState private var focus: Field?

  private enum Field {
    case server, username, password
  }

  private var isSubmitDisabled: Bool {
    auth.serverUrl.isEmpty || auth.username.isEmpty || auth.password.isEmpty || auth.isSubmitting
  }

  var body: some View {
    GeometryReader { proxy in
      ScrollView {
        VStack(spacing: 0) {
          VStack(spacing: 6) {
            let own = Text("Own").foregroundStyle(palette.text)
            let wave = Text("wave").foregroundStyle(palette.accent)
            Text("\(own)\(wave)")
              .font(.familjen(40, relativeTo: .largeTitle))
              .tracking(-0.035 * 40)
            Text("Sign in to your Navidrome server")
              .foregroundStyle(palette.secondary)
          }
          .padding(.top, 92)

          VStack(spacing: 12) {
            field(.server, "Server URL") {
              TextField("Server URL", text: $auth.serverUrl, prompt: Text(""))
                .keyboardType(.URL)
                .textContentType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
            }
            field(.username, "Username") {
              TextField("Username", text: $auth.username, prompt: Text(""))
                .textContentType(.username)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.next)
            }
            field(.password, "Password", isRejected: auth.loginError?.isCredentialError == true) {
              SecureField("Password", text: $auth.password, prompt: Text(""))
                .textContentType(.password)
                .submitLabel(.go)
            }
          }
          .padding(.top, 44)

          if let error = auth.loginError {
            Label(error.loginMessage, systemImage: "exclamationmark.circle.fill")
              .font(.meta)
              .foregroundStyle(Color.floDestructive)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 4)
              .padding(.top, 10)
          }

          Spacer(minLength: 32)

          Button(action: submit) {
            HStack(spacing: 8) {
              if auth.isSubmitting {
                ProgressView().tint(palette.ink)
              }
              Text(
                auth.isSubmitting ? "Signing in…" : auth.loginError == nil ? "Sign in" : "Try again"
              )
            }
          }
          .buttonStyle(FillButtonStyle())
          .disabled(isSubmitDisabled)
          Text("Requires Navidrome 0.64 or newer")
            .font(.meta)
            .foregroundStyle(palette.secondary)
            .padding(.top, 14)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        // The button sits at the bottom, and the whole scrolls once the
        // keyboard leaves too little room.
        .frame(minHeight: proxy.size.height)
      }
      .scrollBounceBehavior(.basedOnSize)
    }
    .scrollDismissesKeyboard(.interactively)
    .background(alignment: .top) { glow }
    .background(palette.background)
    .onSubmit {
      switch focus {
      case .server: focus = .username
      case .username: focus = .password
      case .password, nil: submit()
      }
    }
  }

  /// A soft light of the accent behind the wordmark.
  private var glow: some View {
    RadialGradient(
      colors: [palette.accent.opacity(0.3), .clear], center: .center, startRadius: 0,
      endRadius: 260
    )
    .frame(height: 520)
    .offset(y: -200)
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  private func submit() {
    guard !isSubmitDisabled else { return }
    focus = nil
    auth.login()
  }

  /// An input under its small label on a platter; the focused one is
  /// outlined in the accent, a rejected password in red.
  private func field(
    _ field: Field, _ label: String, isRejected: Bool = false,
    @ViewBuilder input: () -> some View
  ) -> some View {
    let ring = isRejected ? Color.floDestructive : focus == field ? palette.accent : nil
    return VStack(alignment: .leading, spacing: 3) {
      Text(label)
        .font(.counter)
        .tracking(1.2)
        .textCase(.uppercase)
        .foregroundStyle(ring ?? palette.secondary)
        // The field says its own name.
        .accessibilityHidden(true)
      input()
        .font(.body)
        .focused($focus, equals: field)
    }
    .padding(.horizontal, 16)
    .padding(.top, 9)
    .padding(.bottom, 11)
    .background(palette.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      if let ring {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(ring, lineWidth: 1.5)
      }
    }
    .contentShape(Rectangle())
    // Alongside the field's own taps, which place the cursor.
    .simultaneousGesture(TapGesture().onEnded { focus = field })
  }
}
