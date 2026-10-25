//
//  WatchLoginView.swift
//  Ownwave Watch App
//

import SwiftUI

struct WatchLoginView: View {
  @ObservedObject var viewModel: AuthViewModel
  @FocusState private var focus: Field?

  private enum Field {
    case server, username, password
  }

  private static let buttonID = "signIn"

  var isSubmitDisabled: Bool {
    viewModel.serverUrl.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
      || viewModel.isSubmitting
  }

  var body: some View {
    NavigationStack {
      ScrollViewReader { proxy in
        ScrollView {
          VStack(spacing: 5) {
            VStack(alignment: .leading, spacing: 1) {
              Wordmark()
              Text("Sign in to Navidrome")
                .font(.floMeta)
                .foregroundStyle(Color.floSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.bottom, 5)

            loginForm
          }
          .padding(.horizontal, 8)
        }
        // The error and Try Again sit below the fields, out of sight.
        .onChange(of: viewModel.loginError, initial: true) {
          guard viewModel.loginError != nil else { return }
          withAnimation { proxy.scrollTo(Self.buttonID, anchor: .bottom) }
        }
      }
      .background(alignment: .top) { glow }
    }
  }

  private var loginForm: some View {
    VStack(spacing: 5) {
      field(.server, "Server URL") {
        TextField("Server URL", text: $viewModel.serverUrl, prompt: prompt("https://"))
          .textContentType(.URL)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
      }

      field(.username, "Username") {
        TextField("Username", text: $viewModel.username, prompt: prompt("Required"))
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
      }

      field(.password, "Password", isRejected: viewModel.loginError?.isCredentialError == true) {
        SecureField("Password", text: $viewModel.password, prompt: prompt("Required"))
      }

      if let error = viewModel.loginError {
        Label(error.loginMessage, systemImage: "exclamationmark.circle.fill")
          .font(.floMeta)
          .foregroundStyle(Color.floDestructive)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 4)
          .padding(.top, 2)
      }

      Button(action: {
        viewModel.login()
      }) {
        HStack(spacing: 6) {
          if viewModel.isSubmitting {
            ProgressView()
              .tint(Color.floInk)
              .frame(width: 18, height: 18)
          }
          Text(
            viewModel.isSubmitting
              ? "Signing in…" : viewModel.loginError == nil ? "Sign In" : "Try Again")
        }
      }
      .buttonStyle(FloPrimaryButtonStyle())
      .opacity(isSubmitDisabled ? 0.6 : 1)
      .disabled(isSubmitDisabled)
      .padding(.top, 5)
      .id(Self.buttonID)
    }
  }

  /// A soft light of the accent behind the wordmark.
  private var glow: some View {
    RadialGradient(
      colors: [Color.floWave.opacity(0.28), .clear], center: .center, startRadius: 0,
      endRadius: 140
    )
    .frame(width: 330, height: 280)
    .offset(y: -120)
    .ignoresSafeArea()
    .allowsHitTesting(false)
  }

  private func prompt(_ text: String) -> Text {
    Text(text).foregroundStyle(Color.floSecondary)
  }

  /// An input under its mono label: the focused one ringed in the accent, a
  /// rejected password in red. The system draws the field itself, so the
  /// label sits above it rather than on its platter.
  private func field(
    _ field: Field, _ label: String, isRejected: Bool = false,
    @ViewBuilder input: () -> some View
  ) -> some View {
    let ring: Color? = isRejected ? .floDestructive : focus == field ? .floWave : nil
    let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
    return VStack(alignment: .leading, spacing: 3) {
      CapsLabel(label, tint: ring ?? .floSecondary)
        .padding(.horizontal, 10)
        // The field says its own name.
        .accessibilityHidden(true)
      input()
        .focused($focus, equals: field)
        // Under the system's translucent field, so the glow does not show
        // through it.
        .background(Color.floSurface, in: shape)
        .overlay {
          if let ring { shape.strokeBorder(ring, lineWidth: 1.5) }
        }
    }
  }
}
