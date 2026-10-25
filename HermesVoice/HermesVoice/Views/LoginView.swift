import SwiftUI

/// Sign-in to the Hermes dashboard (and the call server), on the app's form surfaces.
struct LoginView: View {
    @EnvironmentObject private var model: AppModel
    @State private var draft = ConnectionSettings.load()
    @State private var working = false

    private var canSignIn: Bool {
        !working && !draft.dashboardURL.isEmpty && !draft.username.isEmpty && !draft.password.isEmpty
            && VoiceServerFields.addressError(draft.voiceServerURL) == nil
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

            VoiceServerFields(url: $draft.voiceServerURL, token: $draft.voiceToken)
            SpeechLanguageSection(selection: $draft.speechLocale)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button {
                    working = true
                    draft.voiceServerURL = draft.voiceServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.voiceToken = draft.voiceToken.trimmingCharacters(in: .whitespacesAndNewlines)
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

struct VoiceServerFields: View {
    @Binding var url: String
    @Binding var token: String

    /// Why the typed address can't be used, or nil (an empty address is allowed: calls are optional).
    static func addressError(_ address: String) -> String? {
        guard !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ConnectionSettings.voiceURL(from: address) == nil else { return nil }
        return "That isn't a usable address. Use one like \(ConnectionSettings.voiceAddressExample)."
    }

    var body: some View {
        Section {
            TextField(text: $url, prompt: Text(verbatim: ConnectionSettings.voiceAddressExample)) { Text("Address") }
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Token", text: $token)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            FormNote("Hermes Voice server")
        } footer: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                if let error = Self.addressError(url) { FormNote(error, color: Theme.destructive) }
                FormNote("Where `hermes-voice-mcp` runs. Get the token on the host with `hermes-voice-mcp token`.")
            }
        }
        .hermesFormRows()
    }
}

/// "Automatic" (the preferred languages) or one of the languages Apple speech recognition supports.
struct SpeechLanguageSection: View {
    @Binding var selection: String
    private static let identifiers = SpeechListener.supportedLocaleIdentifiers()

    var body: some View {
        Section {
            Picker("Speech language", selection: $selection) {
                Text("Automatic").tag("")
                ForEach(options, id: \.self) { identifier in
                    Text(Self.name(identifier)).tag(identifier)
                }
            }
            .pickerStyle(.navigationLink)
        } footer: {
            FormNote("The language you speak on calls. Automatic follows your iPhone's preferred languages.")
        }
        .hermesFormRows()
    }

    private var options: [String] {
        var identifiers = Self.identifiers
        if !selection.isEmpty, !identifiers.contains(selection) { identifiers.append(selection) }
        return identifiers.sorted { Self.name($0).localizedCaseInsensitiveCompare(Self.name($1)) == .orderedAscending }
    }

    private static func name(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// The connection's settings: who is signed in, and the call server.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var speechLocale = ""
    @State private var filled = false

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
            VoiceServerFields(url: $url, token: $token)
            SpeechLanguageSection(selection: $speechLocale)
        }
        .hermesForm()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    model.updateVoice(
                        url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                        token: token.trimmingCharacters(in: .whitespacesAndNewlines),
                        speechLocale: speechLocale
                    )
                    dismiss()
                }
                .disabled(VoiceServerFields.addressError(url) != nil)
            }
        }
        .onAppear {
            // Also runs when returning from the language list; keep the edits made so far.
            guard !filled else { return }
            filled = true
            url = model.settings.voiceServerURL
            token = model.settings.voiceToken
            speechLocale = model.settings.speechLocale
        }
    }
}
