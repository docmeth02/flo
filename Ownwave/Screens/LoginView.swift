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
    ScrollView {
      VStack(alignment: .leading, spacing: 28) {
        VStack(alignment: .leading, spacing: 6) {
          Wordmark()
          Text("Sign in to your Navidrome server")
            .font(.rowSubtitle)
            .foregroundStyle(palette.secondary)
        }
        .padding(.horizontal, 4)

        VStack(spacing: 10) {
          field(.server) {
            TextField("Server URL", text: $auth.serverUrl, prompt: prompt("Server URL"))
              .keyboardType(.URL)
              .textContentType(.URL)
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
              .submitLabel(.next)
          }
          field(.username) {
            TextField("Username", text: $auth.username, prompt: prompt("Username"))
              .textContentType(.username)
              .autocorrectionDisabled()
              .textInputAutocapitalization(.never)
              .submitLabel(.next)
          }
          field(.password) {
            SecureField("Password", text: $auth.password, prompt: prompt("Password"))
              .textContentType(.password)
              .submitLabel(.go)
          }
        }

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
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 24)
    }
    .defaultScrollAnchor(.center, for: .alignment)
    .scrollDismissesKeyboard(.interactively)
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

  private func submit() {
    guard !isSubmitDisabled else { return }
    focus = nil
    auth.login()
  }

  private func prompt(_ text: String) -> Text {
    Text(text).foregroundStyle(palette.secondary)
  }

  private func field(_ field: Field, @ViewBuilder input: () -> some View) -> some View {
    input()
      .font(.body)
      .focused($focus, equals: field)
      .padding(.horizontal, 16)
      .frame(height: 52)
      .background(palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}
