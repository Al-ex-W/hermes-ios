import SwiftUI

/// One installed agent plugin (`PackageRow`): provenance, servers, the "Agent in <profile>" switch, Update when the
/// catalog pin or git remote moved, and Uninstall for user and git installs.
struct PluginDetailScreen: View {
    @ObservedObject var store: PluginsStore
    let id: String
    let profileLabel: String
    @State private var confirmation: CapabilityConfirmation?
    @Environment(\.dismiss) private var dismiss

    private var plugin: AgentPlugin? { store.plugin(id) }

    var body: some View {
        List {
            if let plugin {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        CapabilityFlow(spacing: Theme.Spacing.xs) {
                            ForEach(PluginsTab.tags(plugin).filter { !$0.text.contains(":") }) { tag in
                                StatusTag(tag.text, tone: tag.tone, systemImage: tag.systemImage)
                            }
                            if !plugin.version.isEmpty { StatusTag("v\(plugin.version)") }
                        }
                        Text(plugin.description.isEmpty ? "No description." : plugin.description)
                            .hermesText(.body)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    HStack {
                        Toggle("Agent in \(profileLabel)", isOn: Binding(get: { plugin.enabled },
                                                                          set: { on in Task { await store.toggle(plugin, enable: on) } }))
                            .disabled(!plugin.toggleable || store.busy != nil)
                        if store.isBusy(plugin) { ProgressView() }
                    }
                } footer: {
                    if !plugin.toggleable {
                        FormNote("This backend predates key-addressed plugin toggles — update Hermes to manage it here.")
                    } else if plugin.hasDesktopHalf {
                        FormNote("This package also ships a desktop half, which runs in the Hermes desktop app only.")
                    } else {
                        FormNote("Plugins load into new sessions; some take effect after a gateway restart.")
                    }
                }
                .hermesFormRows()

                if !plugin.servers.isEmpty {
                    Section {
                        ForEach(plugin.servers) { server in
                            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                                HStack {
                                    Text(server.name).hermesText(.rowTitle)
                                    Spacer()
                                    StatusTag(server.stateLabel, tone: server.connected ? .good : .warning)
                                }
                                if !server.connected, !server.sentence.isEmpty {
                                    Text(server.sentence).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                                }
                            }
                        }
                    } header: {
                        FormNote("MCP servers")
                    }
                    .hermesFormRows()
                }

                Section {
                    if let key = plugin.key { LabeledContent("Key") { Text(key).font(Theme.TextStyle.code.font) } }
                    LabeledContent("Source") { Text(plugin.source) }
                    if let catalogName = plugin.catalogName { LabeledContent("Catalog entry") { Text(catalogName) } }
                    if let sha = plugin.installedSha ?? plugin.pinnedSha {
                        LabeledContent(plugin.pinnedSha != nil ? "Pinned commit" : "Installed commit") {
                            Text(String(sha.prefix(8))).font(Theme.TextStyle.code.font)
                        }
                    }
                    if plugin.settingsCount > 0 {
                        FormNote("Its \(plugin.settingsCount) setting\(plugin.settingsCount == 1 ? "" : "s") are edited in the desktop app's Settings ▸ Plugins.")
                    }
                } header: {
                    FormNote("Details")
                }
                .hermesFormRows()

                if plugin.updateAvailable {
                    Section {
                        Button {
                            confirmUpdate(plugin)
                        } label: {
                            Label("Update to \(plugin.updateLabel.isEmpty ? "the latest version" : plugin.updateLabel)",
                                  systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(store.busy != nil)
                    } footer: {
                        FormNote(plugin.catalogName != nil ? "Moves to the catalog's current reviewed pin." : "Pulls the latest commit of its git source.")
                    }
                    .hermesFormRows()
                }

                if plugin.removable {
                    Section {
                        Button(role: .destructive) {
                            confirmation = Self.removeConfirmation(plugin, profileLabel: profileLabel) {
                                if await store.remove(plugin) { dismiss() }
                            }
                        } label: {
                            Label("Uninstall", systemImage: Theme.Icon.delete)
                        }
                        .disabled(store.busy != nil)
                    } footer: {
                        FormNote("Uninstall \(plugin.name) from \(profileLabel).")
                    }
                    .hermesFormRows()
                }
            } else if store.plugins == nil {
                CapabilityLoader()
            } else {
                ContentUnavailableView("Plugin unavailable", systemImage: Theme.Icon.warning,
                                       description: Text("It may have been uninstalled."))
                    .listRowBackground(Color.clear)
            }
        }
        .capabilityList()
        .navigationTitle(plugin?.name ?? "Plugin")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .refreshable { await store.reloadPlugins() }
        .capabilityConfirmation($confirmation)
    }

    static func removeConfirmation(_ plugin: AgentPlugin, profileLabel: String, run: @escaping () async -> Void) -> CapabilityConfirmation {
        CapabilityConfirmation(title: "Uninstall \(plugin.name)?",
                               message: "This deletes the plugin's files from the \(profileLabel) profile. Reinstall it from the catalog or from Git at any time.",
                               action: "Uninstall", run: run)
    }

    /// Update asks first; a widened catalog pin or a cautious scan asks again with what changes.
    private func confirmUpdate(_ plugin: AgentPlugin) {
        confirmation = CapabilityConfirmation(
            title: "Update \(plugin.name)?",
            message: "Hermes replaces the plugin's code in \(profileLabel) with \(plugin.updateLabel.isEmpty ? "the latest version" : plugin.updateLabel). Restart the gateway afterwards to load it.",
            action: "Update", destructive: false) { await runUpdate(plugin, accept: false, force: false) }
    }

    private func runUpdate(_ plugin: AgentPlugin, accept: Bool, force: Bool) async {
        guard let outcome = await store.update(plugin, acceptCapabilities: accept, force: force) else { return }
        switch outcome {
        case let .consent(sha, deltaLines):
            confirmation = CapabilityConfirmation(
                title: "Allow what \(plugin.name) \(sha.isEmpty ? "now" : sha) adds?",
                message: (["The new pin widens what the plugin can do:"] + deltaLines).joined(separator: "\n"),
                action: "Accept and update", destructive: false) { await runUpdate(plugin, accept: true, force: force) }
        case let .scan(verdict, findings):
            let summary = (["The security scan rated the new code \(verdict)."] + findings.prefix(6)).joined(separator: "\n")
            if verdict == "caution" {
                confirmation = CapabilityConfirmation(title: "Update \(plugin.name) anyway?", message: summary,
                                                      action: "Update anyway") { await runUpdate(plugin, accept: accept, force: true) }
            } else {
                store.failure = "The update was blocked. \(summary)"
            }
        case .applied, .unchanged:
            break
        }
    }
}

// MARK: - Catalog install

/// A catalog plugin before installing (the install review): what it is, who maintains it, what it registers and
/// needs, and the reviewed pin it installs.
struct PluginCatalogSheet: View {
    @ObservedObject var store: PluginsStore
    let entry: PluginCatalogEntry
    let profileLabel: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    CapabilityFlow(spacing: Theme.Spacing.xs) {
                        StatusTag(entry.tierLabel, tone: entry.tier == "official" ? .accent : entry.tier == "verified" ? .good : .muted)
                        if !entry.category.isEmpty { StatusTag(CapabilitySearch.label(entry.category)) }
                        if !entry.version.isEmpty { StatusTag("v\(entry.version)") }
                    }
                    Text(entry.description.isEmpty ? "No description." : entry.description)
                        .hermesText(.body)
                        .foregroundStyle(Theme.Text.secondary)
                }
                .padding(.vertical, Theme.Spacing.xs)
                if !entry.maintainer.isEmpty { LabeledContent("Maintainer") { Text(entry.maintainer) } }
                if !entry.sha.isEmpty {
                    LabeledContent("Reviewed commit") { Text(String(entry.sha.prefix(8))).font(Theme.TextStyle.code.font) }
                }
                if !entry.platforms.isEmpty { LabeledContent("Platforms") { Text(entry.platforms.joined(separator: ", ")) } }
            }
            .hermesFormRows()

            if !entry.summary.isEmpty || !entry.tools.isEmpty || !entry.requiresEnv.isEmpty {
                Section {
                    if !entry.summary.isEmpty { Text(entry.summary).hermesText(.caption).foregroundStyle(Theme.Text.secondary) }
                    if !entry.tools.isEmpty { LabeledContent("Tools") { Text(entry.tools.joined(separator: ", ")).multilineTextAlignment(.trailing) } }
                    if !entry.requiresEnv.isEmpty {
                        LabeledContent("Requires") { Text(entry.requiresEnv.joined(separator: ", ")).font(Theme.TextStyle.code.font) }
                    }
                } header: {
                    FormNote("What installing grants")
                }
                .hermesFormRows()
            }

            if !entry.knownIssues.isEmpty {
                Section {
                    ForEach(entry.knownIssues, id: \.self) { issue in
                        Text(issue).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                    }
                } header: {
                    FormNote("Known issues")
                }
                .hermesFormRows()
            }

            Section {
                if let repo = URL(string: entry.repo), repo.scheme?.hasPrefix("http") == true {
                    Button { openURL(repo) } label: { Label("View repository", systemImage: "arrow.up.right.square") }
                }
                if let docs = entry.docsURL.flatMap(URL.init(string:)) {
                    Button { openURL(docs) } label: { Label("Documentation", systemImage: "book") }
                }
            }
            .hermesFormRows()

            Section {
                Button {
                    Task {
                        if await store.install(identifier: entry.installIdentifier, catalogName: entry.name) { dismiss() }
                    }
                } label: {
                    HStack {
                        Label(store.installing ? "Installing…" : "Install", systemImage: "arrow.down.circle")
                        Spacer()
                        if store.installing { ProgressView() }
                    }
                }
                .disabled(store.installing || store.api == nil)
            } footer: {
                FormNote("Installs for \(profileLabel) and turns on right away. Reviewed by Nous.")
            }
            .hermesFormRows()
        }
        .capabilityList()
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .interactiveDismissDisabled(store.installing)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }.disabled(store.installing)
            }
        }
        .failureAlert($store.failure)
    }
}

// MARK: - Install from Git

/// Install from Git (`installModal`): a repository, whether to turn it on, a forced reinstall and an optional
/// commit pin. Clones on the Hermes host into the scoped profile.
struct PluginGitInstallSheet: View {
    @ObservedObject var store: PluginsStore
    let profileLabel: String
    @State private var repository = ""
    @State private var enable = true
    @State private var force = false
    @State private var pin = ""
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { repository.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var pinInvalid: Bool { !pin.trimmingCharacters(in: .whitespaces).isEmpty && !PluginsAPI.isCommit(pin) }
    /// `insecureWarning`: plain http, file and other local schemes.
    private var insecure: Bool {
        let lower = trimmed.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("file:") || lower.hasPrefix("/") || lower.hasPrefix("~")
    }

    var body: some View {
        Form {
            Section {
                TextField("https://github.com/owner/repo", text: $repository)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(Theme.TextStyle.code.font)
            } header: {
                FormNote("Repository")
            } footer: {
                if insecure {
                    FormNote("This URL uses an insecure or local scheme. Prefer https:// or git@ for production installs.", color: Theme.Semantic.attention)
                } else {
                    FormNote("Install only from sources you trust — review the repository before adding it.")
                }
            }
            .hermesFormRows()
            Section {
                Toggle("Enable agent plugin after install", isOn: $enable)
                Toggle("Force reinstall (replace if already installed)", isOn: $force)
                TextField("Pin to commit (optional)", text: $pin)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.TextStyle.code.font)
            } header: {
                FormNote("Advanced")
            } footer: {
                if pinInvalid {
                    FormNote("A pin is a full 40-character commit SHA.", color: Theme.destructive)
                } else {
                    FormNote(enable ? "Installs for \(profileLabel) and turns on right away." : "Installs for \(profileLabel).")
                }
            }
            .hermesFormRows()
        }
        .hermesForm()
        .disabled(store.installing)
        .navigationTitle("Install from Git")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .interactiveDismissDisabled(store.installing)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(store.installing)
            }
            ToolbarItem(placement: .confirmationAction) {
                if store.installing {
                    ProgressView()
                } else {
                    Button("Install") {
                        Task {
                            if await store.install(identifier: trimmed, enable: enable, force: force, ref: pin) { dismiss() }
                        }
                    }
                    .disabled(trimmed.isEmpty || pinInvalid)
                }
            }
        }
        .failureAlert($store.failure)
    }
}
