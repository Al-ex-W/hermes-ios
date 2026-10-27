import SwiftUI

/// Providers › API keys (`buildProviderKeyGroups` in `providers-settings.tsx`): one card per provider with its key
/// and the knobs that belong to it. Values go to the profile's `.env` on the host; the page only ever shows the
/// dashboard's previews.
struct APIKeysScreen: View {
    let client: DashboardClient
    /// Nil: the dashboard's own profile.
    let profile: String?
    @State private var catalog: EnvCatalog?
    @State private var loadError: String?
    @State private var query = ""

    var body: some View {
        List {
            if let catalog {
                let groups = Self.filter(catalog.providerGroups(), query: query)
                if groups.isEmpty {
                    Text(query.isEmpty ? "No provider API keys available." : "No providers match your search.")
                        .foregroundStyle(Theme.Text.tertiary)
                        .hermesFormRows()
                }
                ForEach(groups) { group in
                    NavigationLink {
                        ProviderKeyScreen(client: client, profile: profile, groupName: group.name, catalog: catalogBinding)
                    } label: {
                        KeyGroupRow(group: group)
                    }
                    .hermesFormRows()
                }
            } else if let loadError {
                Section {
                    Text(loadError).foregroundStyle(Theme.destructive)
                    Button("Try again") { Task { await load() } }
                }
                .hermesFormRows()
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .hermesFormRows()
            }
        }
        .hermesForm()
        .searchable(text: $query, prompt: "Search providers")
        .navigationTitle("API keys")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .task(id: profile) { await load() }
        .refreshable { await load() }
    }

    private var catalogBinding: Binding<EnvCatalog> {
        Binding(get: { catalog ?? EnvCatalog() }, set: { catalog = $0 })
    }

    private func load() async {
        do {
            catalog = try await client.envVars(profile: profile)
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if catalog == nil { loadError = error.dashboardMessage }
        }
    }

    /// Provider name, blurb or any of its variable names (the desktop's key search).
    nonisolated static func filter(_ groups: [ProviderKeyGroup], query: String) -> [ProviderKeyGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return groups }
        return groups.filter { group in
            ([group.name, group.description ?? ""] + group.keys).contains { $0.lowercased().contains(needle) }
        }
    }
}

private struct KeyGroupRow: View {
    let group: ProviderKeyGroup

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Circle()
                .fill(group.hasAnySet ? Theme.primary : Theme.Hairline.secondary)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(group.name).hermesText(.rowTitle)
                if let preview = group.primary.preview {
                    Text(preview).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary)
                } else if let description = group.description {
                    Text(description).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(group.hasAnySet ? "Set" : "Not set")
    }
}

/// One provider's key and its extra settings (base URL, region, other keys already set).
struct ProviderKeyScreen: View {
    let client: DashboardClient
    let profile: String?
    let groupName: String
    @Binding var catalog: EnvCatalog
    @State private var page: WebPage?

    var body: some View {
        Form {
            if let group = catalog.providerGroups().first(where: { $0.name == groupName }) {
                if group.description != nil || group.docsURL != nil {
                    Section {
                        if let description = group.description {
                            Text(description).foregroundStyle(Theme.Text.secondary)
                        }
                        if let docs = group.docsURL.flatMap(URL.init(string:)), docs.scheme?.hasPrefix("http") == true {
                            Button {
                                page = WebPage(url: docs)
                            } label: {
                                Label("Get a key", systemImage: "arrow.up.right.square")
                            }
                        }
                    }
                    .hermesFormRows()
                }
                EnvFieldSection(client: client, profile: profile, info: group.primary, title: "API key",
                                checksKey: true, catalog: $catalog)
                ForEach(group.advanced) { info in
                    EnvFieldSection(client: client, profile: profile, info: info, title: info.fieldLabel,
                                    checksKey: false, catalog: $catalog)
                }
            } else {
                Text("This provider is no longer listed.").foregroundStyle(Theme.Text.tertiary).hermesFormRows()
            }
        }
        .hermesForm()
        .navigationTitle(groupName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .sheet(item: $page) { page in
            SafariSheet(url: page.url).ignoresSafeArea()
        }
    }
}

/// Edits one `.env` variable: its saved preview, a field for a new value, Save and Remove. A provider key is tried
/// against the provider first when Hermes has a probe for it. The typed value lives only in this view's state and
/// is cleared once sent.
struct EnvFieldSection: View {
    let client: DashboardClient
    let profile: String?
    let info: EnvVar
    let title: String
    /// Try the key with `POST /api/providers/validate` before saving it.
    var checksKey = false
    @Binding var catalog: EnvCatalog
    @State private var draft = ""
    @State private var saving = false
    @State private var note: String?
    @State private var rejected: String?
    @State private var confirmingRemove = false
    @State private var failure: String?

    var body: some View {
        Section {
            if let preview = info.preview {
                LabeledContent("Saved") {
                    Text(preview).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary)
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                if info.isSecret {
                    SecretInput(title: info.isSet ? "Paste a new key to replace it" : info.placeholder, text: $draft) {
                        Task { await save(force: false) }
                    }
                } else {
                    TextField(info.placeholder, text: $draft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(info.key.uppercased().hasSuffix("URL") ? .URL : .default)
                        .font(Theme.TextStyle.code.font)
                        .submitLabel(.done)
                        .onSubmit { Task { await save(force: false) } }
                }
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save(force: false) } }
                        .buttonStyle(.borderless)
                        .disabled(trimmedDraft.isEmpty)
                }
            }
            // On this one row: a Section hands its modifiers to every row, and several rows presenting one alert
            // make UIKit dismiss Settings itself.
            .failureAlert($failure)
            .onChange(of: draft) { _, _ in rejected = nil }
            if let rejected {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(rejected).hermesText(.caption).foregroundStyle(Theme.destructive)
                    Button("Save anyway") { Task { await save(force: true) } }
                        .buttonStyle(.borderless)
                        .hermesText(.caption)
                }
            }
            if info.isSet {
                Button(info.isSecret ? "Remove key" : "Clear", role: .destructive) { confirmingRemove = true }
                    .foregroundStyle(Theme.destructive)
                    .disabled(saving)
                    .confirmationDialog("Remove \(info.key)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
                        Button("Remove", role: .destructive) { Task { await remove() } }
                    } message: {
                        Text("Hermes deletes it from this profile's .env on the host, with every copy of it in the config.")
                    }
            }
        } header: {
            HStack {
                FormNote(title)
                Spacer()
                Text(info.key).font(Theme.TextStyle.meta.font.monospaced()).foregroundStyle(Theme.Text.quaternary).textCase(nil)
            }
        } footer: {
            if let note {
                FormNote(note)
            } else if !info.description.isEmpty, info.description != title {
                FormNote(info.description)
            }
        }
        .hermesFormRows()
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func save(force: Bool) async {
        let value = trimmedDraft
        guard !value.isEmpty, !saving else { return }
        if CredentialMask.isPreview(value) {
            failure = "That's the saved key's preview. Paste the full key to replace it."
            return
        }
        saving = true
        defer { saving = false }
        note = nil
        if checksKey, info.isSecret, !force,
           let check = try? await client.checkCredential(info.key, value: value), check.rejected {
            rejected = check.message ?? "The provider rejected this key."
            return
        }
        do {
            try await client.setEnv(info.key, value: value, profile: profile, providerSetup: checksKey)
            draft = ""
            rejected = nil
            catalog.update(info.key, isSet: true, preview: CredentialMask.localPreview(value))
            note = "Saved."
            NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
        } catch {
            failure = "Couldn't save \(info.key). \(error.dashboardMessage)"
        }
    }

    private func remove() async {
        saving = true
        defer { saving = false }
        do {
            try await client.deleteEnv(info.key, profile: profile)
            catalog.update(info.key, isSet: false, preview: nil)
            note = "Removed."
            NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
        } catch {
            failure = "Couldn't remove \(info.key). \(error.dashboardMessage)"
        }
    }
}
