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

            VoiceServerFields(url: $draft.voiceServerURL, token: $draft.voiceToken)
            SpeechLanguageSection(selection: $draft.speechLocale)

            Section {
                Button {
                    working = true
                    draft.voiceServerURL = draft.voiceServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    draft.voiceToken = draft.voiceToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
                .disabled(working || draft.dashboardURL.isEmpty || draft.username.isEmpty || draft.password.isEmpty
                    || VoiceServerFields.addressError(draft.voiceServerURL) != nil)
            } footer: {
                if let error = model.error { Text(error).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Hermes Voice")
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
            Text("Hermes Voice server")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if let error = Self.addressError(url) { Text(error).foregroundStyle(.red) }
                Text("Where `hermes-voice-mcp` runs. Get the token on the host with `hermes-voice-mcp token`.")
            }
        }
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
            Text("The language you speak on calls. Automatic follows your iPhone's preferred languages.")
        }
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

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var token = ""
    @State private var speechLocale = ""
    @State private var filled = false

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
            VoiceServerFields(url: $url, token: $token)
            SpeechLanguageSection(selection: $speechLocale)
        }
        .navigationTitle("Settings")
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
