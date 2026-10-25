import SwiftUI

/// Sign-in to the Hermes dashboard, on the app's form surfaces. Calls ride on the same sign-in.
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ConnectionSettings.load()
    @State private var working = false

    private var canSignIn: Bool {
        !working && !draft.dashboardURL.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Hermes")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Theme.Text.primary)
                    Text("Connect to the dashboard your agent runs on.")
                        .hermesText(.body)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                .padding(.vertical, Theme.Spacing.sm)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.xs, bottom: 0, trailing: 0))
            }

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
                FormNote("Hermes dashboard")
            } footer: {
                FormNote("The address of `hermes dashboard` (port 9119), for example through Tailscale Serve.")
            }
            .hermesFormRows()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    working = true
                    Task {
                        await model.signIn(draft)
                        working = false
                    }
                } label: {
                    ZStack {
                        if working {
                            ProgressView().tint(Theme.primaryForeground)
                        } else {
                            Text("Sign in").hermesText(.button)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .foregroundStyle(Theme.primaryForeground)
                    .background(Theme.primary.opacity(canSignIn || working ? 1 : 0.45),
                                in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canSignIn)
                if let error = model.error { FormNote(error, color: Theme.destructive) }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.lg)
            .background(Theme.sidebar)
        }
        .hermesForm()
        .navigationTitle("Sign in")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
    }
}

/// The connection's settings: who is signed in, and the way to the call settings.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section {
                LabeledContent("Address") {
                    Text(model.settings.dashboardURL).foregroundStyle(Theme.Text.tertiary).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("User") {
                    Text(model.settings.username).foregroundStyle(Theme.Text.tertiary)
                }
                Button("Sign out", role: .destructive) {
                    model.signOut()
                    dismiss()
                }
                .foregroundStyle(Theme.destructive)
            } header: {
                FormNote("Hermes dashboard")
            }
            .hermesFormRows()
            Section {
                NavigationLink { CallsSettingsView() } label: { Label("Calls", systemImage: "phone") }
            }
            .hermesFormRows()
        }
        .hermesForm()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
