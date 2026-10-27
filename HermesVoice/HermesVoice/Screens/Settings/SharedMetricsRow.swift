import SwiftUI

/// Settings > Safety > Privacy: "Share usage stats with Nous" for the profile the page edits
/// (`shared-metrics-settings.tsx`, `shared_metrics.status|set`). On sets both opt-ins (collect and send), off
/// clears both. A backend without these methods keeps the switch, off and explained.
struct SharedMetricsRow: View {
    @EnvironmentObject private var context: SettingsContext
    @State private var consent: SharedMetricsConsentResult?
    @State private var loaded = false
    @State private var busy = false
    @State private var failure: String?

    static let docsURL = URL(string: "https://hermes-agent.nousresearch.com/docs/developer-guide/relay-shared-metrics")

    var body: some View {
        Section {
            SettingsRow(title: "Share usage stats with Nous",
                        description: loaded && consent == nil
                            ? "Update the Hermes backend to change this setting."
                            : "Counts only, sent once a day with a random ID for this profile. Never your messages, files, paths or error text.",
                        error: failure, saving: busy) {
                Toggle("Share usage stats with Nous", isOn: Binding(get: { consent?.send ?? false }, set: { on in
                    Task { await save(on) }
                }))
                .labelsHidden()
                .disabled(consent == nil || busy)
            }
            if let url = Self.docsURL {
                Link("What is collected", destination: url).hermesText(.button)
            }
        }
        .hermesFormRows()
        .id("safety.shared-metrics")
        .task { await load() }
    }

    private func load() async {
        defer { loaded = true }
        guard let gateway = context.gateway else { return }
        consent = try? await gateway.sharedMetricsStatus(.init(profile: context.profile))
    }

    /// Optimistic, rolled back on failure.
    private func save(_ on: Bool) async {
        guard let gateway = context.gateway, let previous = consent else { return }
        busy = true
        failure = nil
        consent = SharedMetricsConsentResult(enabled: on, send: on, decided: true)
        defer { busy = false }
        do {
            consent = try await gateway.sharedMetricsSet(.init(profile: context.profile, enabled: on, send: on))
        } catch {
            consent = previous
            failure = "Couldn’t save your choice: \(error.localizedDescription)"
        }
    }
}
