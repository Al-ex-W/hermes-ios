import SwiftUI

/// How calls listen (speech provider, language, end of speech), and whether Hermes can ring this phone.
struct CallsSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var push: PushRegistration
    @State private var status: VoicePluginStatus?
    @State private var statusError: String?
    @State private var checking = false

    var body: some View {
        Form {
            Section {
                Picker("Speech recognition", selection: $model.callSettings.provider) {
                    ForEach(SpeechProviderID.allCases) { provider in
                        Text(provider.name).tag(provider)
                    }
                }
                Picker("End of speech", selection: $model.callSettings.endOfSpeech) {
                    ForEach(EndOfSpeech.allCases) { level in
                        Text(level.name).tag(level)
                    }
                }
            } header: {
                Text("Listening")
            } footer: {
                Text(listeningFooter)
            }

            SpeechLanguageSection(selection: $model.callSettings.speechLocale, provider: model.callSettings.provider)

            Section {
                LabeledContent("This iPhone", value: tokenState)
                LabeledContent("Sent to Hermes", value: uploadState)
                if model.signedIn {
                    Button("Send again") { model.sendPushToken() }
                        .disabled(push.token == nil || push.upload == .sending)
                }
            } header: {
                Text("Incoming calls")
            } footer: {
                Text("Hermes rings this iPhone through a VoIP push when an agent calls you with start_call (\(PushRegistration.environment) APNs).")
            }

            Section {
                if let status {
                    LabeledContent("Voice", value: status.tts == "elevenlabs" ? "ElevenLabs" : (status.tts.isEmpty ? "–" : status.tts))
                    LabeledContent("Ringing", value: status.canRing ? "Ready" : (status.apnsConfigured ? "Needs the h2 package" : "No APNs key"))
                    LabeledContent("Scribe", value: status.scribeConfigured ? "Ready" : "No ElevenLabs key")
                } else if let statusError {
                    Text(statusError).foregroundStyle(.red)
                }
                Button {
                    Task { await check() }
                } label: {
                    HStack {
                        Text("Check")
                        if checking { Spacer(); ProgressView() }
                    }
                }
                .disabled(checking || model.client == nil)
            } header: {
                Text("Hermes Voice plugin")
            }
        }
        .navigationTitle("Calls")
        .task { await check() }
    }

    private var listeningFooter: String {
        let settings = model.callSettings
        switch settings.provider {
        case .apple:
            return "Apple speech recognition runs on this iPhone when the language has an on-device model. "
                + "A pause of \(Self.seconds(settings.endOfSpeech.appleSilence)) ends what you say."
        case .scribe:
            return "ElevenLabs Scribe transcribes in the cloud with a key on the Hermes host; if it isn't available, "
                + "calls fall back to Apple. A pause of \(Self.seconds(settings.endOfSpeech.scribeSilence)) ends what you say."
        }
    }

    private static func seconds(_ value: TimeInterval) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) s"
    }

    private var tokenState: String {
        push.token == nil ? "Not registered yet" : "Registered"
    }

    private var uploadState: String {
        switch push.upload {
        case .notSent: return "Not yet"
        case .sending: return "Sending…"
        case let .sent(date): return date.formatted(date: .omitted, time: .shortened)
        case let .failed(error): return error
        }
    }

    private func check() async {
        guard let client = model.client, !checking else { return }
        checking = true
        defer { checking = false }
        do {
            status = try await VoicePluginAPI.status(client)
            statusError = nil
        } catch {
            status = nil
            statusError = error.localizedDescription
        }
    }
}

/// "Automatic" or one of the languages Apple speech recognition supports (Scribe takes the language part).
struct SpeechLanguageSection: View {
    @Binding var selection: String
    var provider: SpeechProviderID = .apple
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
            Text(provider == .apple
                 ? "The language you speak on calls. Automatic follows your iPhone's preferred languages."
                 : "The language you speak on calls. Automatic lets Scribe detect it.")
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
