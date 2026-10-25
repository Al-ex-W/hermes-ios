import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ConnectionSettings.load()
    @State private var working = false

    var body: some View {
        Form {
            Section {
                TextField(text: $draft.dashboardURL, prompt: Text(verbatim: "https://machine.tailnet.ts.net")) { Text("Address") }
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $draft.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $draft.password)
                    .textContentType(.password)
            } header: {
                Text("Hermes dashboard")
            } footer: {
                Text("The address of `hermes dashboard` (port 9119), for example through Tailscale Serve.")
            }

            Section {
                Button {
                    working = true
                    Task {
                        await model.signIn(draft)
                        working = false
                    }
                } label: {
                    HStack {
                        Text("Sign in")
                        if working { Spacer(); ProgressView() }
                    }
                }
                .disabled(working || draft.dashboardURL.isEmpty || draft.username.isEmpty || draft.password.isEmpty)
            } footer: {
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Hermes Voice")
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Hermes dashboard") {
                LabeledContent("Address", value: model.settings.dashboardURL)
                LabeledContent("User", value: model.settings.username)
                Button("Sign out", role: .destructive) {
                    model.signOut()
                    dismiss()
                }
            }
            // Hook (M6): calls have their own settings screen.
            Section {
                NavigationLink { CallsSettingsView() } label: { Label("Calls", systemImage: "phone") }
            }
        }
        .navigationTitle("Settings")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
