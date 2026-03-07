//
//  WatchLoginView.swift
//  flo Watch App
//

import SwiftUI

struct WatchLoginView: View {
  @ObservedObject var viewModel: AuthViewModel

  @State private var showManualLogin = false

  var isSubmitDisabled: Bool {
    viewModel.serverUrl.isEmpty || viewModel.username.isEmpty || viewModel.password.isEmpty
      || viewModel.isSubmitting
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 12) {
          Image(systemName: "music.note")
            .font(.system(size: 36))
            .foregroundColor(.accentColor)
            .padding(.top, 8)

          Text("flo")
            .customFont(.title2)
            .fontWeight(.bold)

          Text("Open flo on iPhone to sign in")
            .customFont(.caption1)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

          Button(action: refreshAuth) {
            Label("Refresh", systemImage: "arrow.clockwise")
          }
          .padding(.top, 4)

          Divider()
            .padding(.vertical, 8)

          Button(action: { showManualLogin.toggle() }) {
            Text(showManualLogin ? "Hide Login" : "Manual Login")
              .customFont(.caption1)
          }
          .buttonStyle(.plain)
          .foregroundColor(.accentColor)

          if showManualLogin {
            manualLoginForm
          }
        }
        .padding(.horizontal)
      }
      .navigationTitle("Sign In")
      .alert(isPresented: $viewModel.showAlert) {
        Alert(
          title: Text("Login Failed"),
          message: Text(viewModel.alertMessage),
          dismissButton: .default(Text("OK"))
        )
      }
    }
  }

  private var manualLoginForm: some View {
    VStack(spacing: 8) {
      TextField("Server URL", text: $viewModel.serverUrl)
        .textContentType(.URL)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)

      TextField("Username", text: $viewModel.username)
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)

      SecureField("Password", text: $viewModel.password)

      Button(action: {
        viewModel.experimentalSaveLoginInfo = true
        viewModel.login()
      }) {
        if viewModel.isSubmitting {
          ProgressView()
        } else {
          Text("Login")
            .fontWeight(.bold)
        }
      }
      .disabled(isSubmitDisabled)
      .padding(.top, 4)
    }
  }

  private func refreshAuth() {
    if let jsonString = try? KeychainManager.getAuthCreds(),
      let jsonData = jsonString.data(using: .utf8),
      let data = try? JSONDecoder().decode(UserAuth.self, from: jsonData)
    {
      let serverURL = UserDefaultsManager.serverBaseURL
      if !serverURL.isEmpty {
        viewModel.serverUrl = serverURL
        viewModel.username = data.username

        if UserDefaultsManager.saveLoginInfo,
          let password = try? KeychainManager.getAuthPassword(), !password.isEmpty
        {
          viewModel.password = password
          viewModel.experimentalSaveLoginInfo = true
        }

        viewModel.login()
      }
    }
  }
}
