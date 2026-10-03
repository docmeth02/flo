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
        VStack(spacing: 6) {
          HStack(spacing: 10) {
            Image("FloLogo")
              .resizable()
              .frame(width: 40, height: 40)
              .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
              Text("flo")
                .font(.floWordmark)
                .foregroundStyle(Color.floLavender)
              Text("Sign in to your Navidrome server")
                .font(.floMeta)
                .foregroundStyle(Color.floSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 6)
          .padding(.bottom, 6)

          loginForm
        }
        .padding(.horizontal, 8)
      }
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
    VStack(spacing: 6) {
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
        HStack(spacing: 6) {
          if viewModel.isSubmitting {
            ProgressView()
              .frame(width: 18, height: 18)
          }
          Text(viewModel.isSubmitting ? "Signing in…" : "Login")
            .fontWeight(.bold)
        }
      }
      .buttonStyle(FloPrimaryButtonStyle())
      .opacity(isSubmitDisabled ? 0.6 : 1)
      .disabled(isSubmitDisabled)
      .padding(.top, 4)
    }
  }
}
