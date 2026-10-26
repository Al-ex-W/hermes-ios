import SwiftUI

/// Settings > Tools & Keys (`keys-settings.tsx`): tool API keys (`tools`) and server-wide settings such as the
/// API server or gateway proxy (`settings`) from `GET /api/env`. Provider keys live on the Providers page and
/// messaging-platform credentials on Messaging. A typed value is sent once to the dashboard (`PUT /api/env`) and
/// dropped from memory; the page shows only the dashboard's masked preview.
struct KeysSettingsView: View {
    @EnvironmentObject private var context: SettingsContext
    /// "tools" or "settings".
    let view: String
    let anchor: String?

    @State private var catalog = EnvCatalog()
    @State private var loaded = false
    @State private var failure: String?
    @State private var open: String?

    private var categories: Set<String> { view == "settings" ? ["setting", "messaging"] : ["tool"] }

    var body: some View {
        let entries = catalog.entries(categories: categories)
        Form {
            Section {
                if loaded && entries.isEmpty {
                    Text("Nothing to set up here.").foregroundStyle(Theme.Text.tertiary)
                }
                ForEach(entries) { info in
                    CredentialRow(info: info, expanded: open == info.key) {
                        open = open == info.key ? nil : info.key
                    } changed: { isSet, preview in
                        catalog.update(info.key, isSet: isSet, preview: preview)
                    }
                    .id(info.key)
                }
            } footer: {
                if let failure { FormNote(failure, color: Theme.destructive) }
                else { FormNote("Keys are stored in the host's .env. This iPhone keeps no copy.") }
            }
            .hermesFormRows()
        }
        .hermesForm()
        .overlay { if !loaded { ProgressView() } }
        .settingsAnchor(anchor, ready: loaded)
        .refreshable { await reload() }
        .task {
            await reload()
            if let anchor, catalog[anchor] != nil { open = anchor }
        }
    }

    private func reload() async {
        do {
            catalog = try await context.client.envVars()
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
        loaded = true
    }
}

/// One credential (`CredentialKeyCard`): its state, and when opened, a field to set or replace it and a way to
/// remove it.
private struct CredentialRow: View {
    @EnvironmentObject private var context: SettingsContext
    let info: EnvVar
    let expanded: Bool
    let toggle: () -> Void
    let changed: (_ isSet: Bool, _ preview: String?) -> Void

    @State private var draft = ""
    @State private var busy = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(info.label).foregroundStyle(Theme.Text.primary)
                        Text(info.key).hermesText(.meta).foregroundStyle(Theme.Text.quaternary)
                    }
                    Spacer()
                    Text(info.preview ?? "Not set")
                        .hermesText(.caption)
                        .foregroundStyle(info.isSet ? Theme.Text.secondary : Theme.Text.quaternary)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            if expanded {
                if !info.description.isEmpty {
                    Text(info.description).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
                if !info.tools.isEmpty {
                    Text("Used by \(info.tools.joined(separator: ", "))").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
                Group {
                    if info.isSecret {
                        SecureField(info.isSet ? "Paste a new value to replace it" : info.placeholder, text: $draft)
                    } else {
                        TextField(info.placeholder, text: $draft)
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit { Task { await save() } }
                HStack(spacing: Theme.Spacing.xl) {
                    Button(info.isSet ? "Replace" : "Save") { Task { await save() } }
                        .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if info.isSet {
                        Button("Remove", role: .destructive) { Task { await remove() } }.disabled(busy)
                    }
                    Spacer()
                    if let url = info.url.flatMap(URL.init(string:)) {
                        Link("Get a key", destination: url)
                    }
                    if busy { ProgressView() }
                }
                .buttonStyle(.borderless)
                .hermesText(.button)
                if let failure {
                    Text(failure).hermesText(.caption).foregroundStyle(Theme.destructive)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private func save() async {
        let value = draft
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        busy = true
        defer { busy = false }
        do {
            try await context.client.setEnv(info.key, value: value)
            changed(true, CredentialMask.localPreview(value.trimmingCharacters(in: .whitespacesAndNewlines)))
            draft = ""
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    private func remove() async {
        busy = true
        defer { busy = false }
        do {
            try await context.client.deleteEnv(info.key)
            changed(false, nil)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
