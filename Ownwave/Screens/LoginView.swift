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
            field(.password, "Password") {
              SecureField("Password", text: $auth.password, prompt: Text(""))
                .textContentType(.password)
                .submitLabel(.go)
            }
          }
          .padding(.top, 44)

          Spacer(minLength: 32)

          Button(action: submit) {
            HStack(spacing: 8) {
              if auth.isSubmitting {
                ProgressView().tint(palette.ink)
              }
              Text(auth.isSubmitting ? "Signing in…" : "Sign in")
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
    .alert("Login Failed", isPresented: $auth.showAlert) {
      Button("OK") {}
    } message: {
      Text(auth.alertMessage)
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
  /// outlined in the accent.
  private func field(_ field: Field, _ label: String, @ViewBuilder input: () -> some View)
    -> some View
  {
    let isFocused = focus == field
    return VStack(alignment: .leading, spacing: 3) {
      Text(label)
        .font(.counter)
        .tracking(1.2)
        .textCase(.uppercase)
        .foregroundStyle(isFocused ? palette.accent : palette.secondary)
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
      if isFocused {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(palette.accent, lineWidth: 1.5)
      }
    }
    .contentShape(Rectangle())
    .onTapGesture { focus = field }
  }
}
