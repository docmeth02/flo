//
//  WatchLoginView.swift
//  flo Watch App
//

import SwiftUI

struct WatchLoginView: View {
  @ObservedObject var viewModel: AuthViewModel

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

          Text("Sign in to your Navidrome server")
            .customFont(.caption1)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)

          loginForm
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

  private var loginForm: some View {
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
}
