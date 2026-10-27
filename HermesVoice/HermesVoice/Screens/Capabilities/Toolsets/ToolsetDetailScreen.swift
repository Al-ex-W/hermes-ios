import SwiftUI

/// One toolset's page (`toolsets/toolset-detail.tsx` + `settings/toolset-config-panel.tsx`): its switch and tools,
/// the toolset-specific panels (terminal backends, real browser profile, Computer Use status, the vision hint),
/// then its providers with their keys, one-time installs and model catalogs.
struct ToolsetDetailScreen: View {
    @ObservedObject var store: ToolsetsStore
    let context: CapabilitiesContext
    let name: String
    @StateObject private var setup: ToolsetSetupModel

    init(store: ToolsetsStore, context: CapabilitiesContext, name: String) {
        self.store = store
        self.context = context
        self.name = name
        _setup = StateObject(wrappedValue: ToolsetSetupModel(api: context.toolsets, actions: context.actions, toolset: name))
    }

    private var toolset: CapabilityToolset? { store.toolset(named: name) }

    var body: some View {
        List {
            if let toolset {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if !toolset.configured { StatusTag("Needs keys", tone: .warning) }
                        Text(toolset.description.isEmpty ? "No description." : toolset.description)
                            .hermesText(.body)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    Toggle("Enabled", isOn: Binding(get: { toolset.enabled },
                                                    set: { on in Task { await store.setEnabled(toolset, on) } }))
                        .disabled(store.bulkBusy)
                } footer: {
                    FormNote("Changes apply to new sessions.")
                }
                .hermesFormRows()
                if !toolset.tools.isEmpty {
                    Section {
                        CapabilityFlow(spacing: Theme.Spacing.xs) {
                            ForEach(toolset.tools, id: \.self) { tool in
                                ToolsetToolChip(name: tool, calls: store.calls?[tool] ?? 0)
                            }
                        }
                        .padding(.vertical, Theme.Spacing.xs)
                    } header: {
                        FormNote("\(toolset.tools.count) \(toolset.tools.count == 1 ? "tool" : "tools")")
                    }
                    .hermesFormRows()
                }
            }
            switch name {
            case "vision":
                Section {
                    FormNote("Vision uses your auxiliary model configuration — the image-capable model is picked there, not per-provider here. Choose it in Settings ▸ Model.")
                }
                .hermesFormRows()
            case "computer_use":
                ToolsetComputerUseSection(api: context.toolsets)
            case "browser":
                ToolsetBrowserProfileSection(config: context.config)
            case "terminal":
                ToolsetTerminalSection(api: context.toolsets) { Task { await store.reload() } }
            default:
                EmptyView()
            }
            ToolsetProviderSections(model: setup, context: context) { Task { await store.reload() } }
        }
        .capabilityList()
        .navigationTitle(toolset?.label ?? EnvVar.prettyName(name))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .refreshable {
            await setup.load()
            await store.reload()
        }
        .task { await setup.loadOnce() }
        .failureAlert($setup.failure)
        .capabilityNotice($setup.notice)
    }
}

// MARK: - Tools

/// A tool name with its call count (`ToolChip`).
private struct ToolsetToolChip: View {
    let name: String
    let calls: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(name).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.secondary)
            if calls > 0 {
                Text("×\(calls.formatted(.number.notation(.compactName)))")
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.quaternary)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xxs)
        .background(Theme.Fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
    }
}

// MARK: - Computer Use

/// Computer Use readiness on the host, read-only (`ComputerUsePanel`): granting the macOS permissions needs
/// someone at the host's screen.
private struct ToolsetComputerUseSection: View {
    let api: ToolsetsAPI
    @State private var status: ComputerUseStatus?
    @State private var failed: String?

    var body: some View {
        Section {
            if let status {
                LabeledContent("Driver") { Text(status.installed ? (status.version ?? "Installed") : "Not installed") }
                LabeledContent("Ready") { readiness(status.ready) }
                if status.accessibility != nil || status.screenRecording != nil {
                    LabeledContent("Accessibility") { readiness(status.accessibility) }
                    LabeledContent("Screen recording") { readiness(status.screenRecording) }
                }
                if let error = status.error { FormNote(error, color: Theme.destructive) }
            } else if let failed {
                FormNote("Couldn't read Computer Use status. \(failed)", color: Theme.destructive)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            FormNote("Computer Use on the Hermes host")
        } footer: {
            FormNote("Permissions are granted at the host's own screen: run `hermes computer-use permissions grant` there.")
        }
        .hermesFormRows()
        .task {
            do { status = try await api.computerUseStatus() } catch { if !error.isCancellation { failed = error.dashboardMessage } }
        }
    }

    @ViewBuilder private func readiness(_ value: Bool?) -> some View {
        switch value {
        case true?: StatusTag("Ready", tone: .good, systemImage: "checkmark")
        case false?: StatusTag("Not granted", tone: .warning)
        case nil: StatusTag("Unknown")
        }
    }
}

// MARK: - Browser

/// The `browser.use_real_profile` consent (`BrowserRealProfilePanel`), saved as a sparse `PUT /api/config`.
private struct ToolsetBrowserProfileSection: View {
    let config: ConfigAPI
    @State private var enabled: Bool?
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Section {
            if let enabled {
                Toggle(isOn: Binding(get: { enabled }, set: { on in Task { await save(on) } })) {
                    Text("Use My Real Browser Profile")
                }
                .disabled(saving)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let failure { FormNote(failure, color: Theme.destructive) }
        } footer: {
            FormNote("Copies the host's default browser logins and cookies into a managed snapshot the agent browses with. The live profile is never opened directly. Applies to new sessions.")
        }
        .hermesFormRows()
        .task {
            let record = try? await config.config()
            enabled = record?["browser"]?["use_real_profile"]?.boolValue ?? false
        }
    }

    private func save(_ on: Bool) async {
        let previous = enabled
        enabled = on
        saving = true
        defer { saving = false }
        do {
            try await config.save(["browser": ["use_real_profile": .bool(on)]])
            failure = nil
        } catch {
            enabled = previous
            failure = "Could not save the real-profile setting. \(error.dashboardMessage)"
        }
    }
}

// MARK: - Terminal

/// The execution backend picker (`TerminalBackendPanel`): each backend with its health probe. A backend that
/// still needs setup can be picked, after a yes: later sessions would have no terminal or file tools until then.
private struct ToolsetTerminalSection: View {
    let api: ToolsetsAPI
    let onChange: () -> Void
    @State private var backends: [TerminalBackend]?
    @State private var loading = false
    @State private var selecting: String?
    @State private var failure: String?
    @State private var confirmation: CapabilityConfirmation?

    var body: some View {
        Section {
            if let backends {
                ForEach(backends) { backend in
                    Button { pick(backend) } label: { row(backend) }
                        .buttonStyle(.plain)
                        .disabled(selecting != nil)
                }
            } else if let failure {
                FormNote(failure, color: Theme.destructive)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        } header: {
            HStack {
                FormNote("Execution backend")
                Spacer()
                Button { Task { await load() } } label: { Image(systemName: Theme.Icon.retry) }
                    .disabled(loading)
                    .accessibilityLabel("Check backends again")
            }
        } footer: {
            if backends != nil, let failure { FormNote(failure, color: Theme.destructive) }
        }
        .hermesFormRows()
        .task { await load() }
        .capabilityConfirmation($confirmation)
    }

    private func row(_ backend: TerminalBackend) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(backend.label).hermesText(.rowTitle).foregroundStyle(Theme.Text.primary)
                    switch backend.status {
                    case .ready: StatusTag("Ready", tone: .good, systemImage: "checkmark")
                    case .needsSetup: StatusTag("Needs setup", systemImage: Theme.Icon.warning)
                    case .unavailable: StatusTag("Unavailable", systemImage: Theme.Icon.warning)
                    }
                    if backend.active { StatusTag("In use", tone: .accent, systemImage: "checkmark") }
                }
                if !backend.description.isEmpty {
                    Text(backend.description).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
                if backend.status != .ready, !backend.detail.isEmpty {
                    Text(backend.detail + (backend.active ? " This backend is currently selected without full setup — commands will fail until setup is complete." : ""))
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Semantic.attention)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if selecting == backend.name { ProgressView() }
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            backends = try await api.terminalBackends()
            failure = nil
        } catch {
            guard !error.isCancellation else { return }
            failure = "Could not load terminal backends. \(error.dashboardMessage)"
        }
    }

    private func pick(_ backend: TerminalBackend) {
        guard !backend.active, selecting == nil else { return }
        if backend.status == .needsSetup {
            confirmation = CapabilityConfirmation(
                title: "Select \(backend.label) anyway?",
                message: backend.detail.isEmpty
                    ? "This backend isn't set up yet. Sessions that start after this change will have no terminal or file tools until setup is finished."
                    : "\(backend.detail) Sessions that start after this change will have no terminal or file tools until setup is finished.",
                action: "Select anyway", destructive: false) { await select(backend) }
        } else {
            Task { await select(backend) }
        }
    }

    private func select(_ backend: TerminalBackend) async {
        selecting = backend.name
        defer { selecting = nil }
        do {
            try await api.selectTerminalBackend(backend.name)
            backends = backends?.map { row in
                var row = row
                row.active = row.name == backend.name
                return row
            }
            failure = nil
            onChange()
        } catch {
            failure = "Failed to select \(backend.label). \(error.dashboardMessage)"
        }
    }
}

// MARK: - Providers

/// A toolset's provider matrix (`ToolsetConfigPanel`): which backend is active, each one's keys and installs.
@MainActor
final class ToolsetSetupModel: ObservableObject {
    @Published private(set) var setup: ToolsetSetup?
    @Published private(set) var loadError: String?
    /// Keys saved or removed here since the load (the server's `is_set` is stale until the next one).
    @Published private(set) var setKeys: [String: Bool] = [:]
    /// The provider row opened (presentational; the active one is `setup.activeProvider`).
    @Published var expanded: String?
    @Published private(set) var selecting: String?
    @Published private(set) var savingKey: String?
    @Published private(set) var postSetup: [String: CapabilityActionStatus] = [:]
    @Published private(set) var models: [String: ToolsetModelCatalog] = [:]
    @Published private(set) var selectingModel: String?
    /// A managed Nous row was picked without a Portal entitlement.
    @Published var needsNousSignIn: String?
    @Published var failure: String?
    @Published var notice: String?

    let api: ToolsetsAPI
    let actions: CapabilityActionsAPI
    let toolset: String
    private var loaded = false

    init(api: ToolsetsAPI, actions: CapabilityActionsAPI, toolset: String) {
        self.api = api
        self.actions = actions
        self.toolset = toolset
    }

    func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        await load()
    }

    func load() async {
        do {
            let next = try await api.setup(toolset)
            setup = next
            setKeys = [:]
            loadError = nil
            if expanded == nil || !next.providers.contains(where: { $0.name == expanded }) { expanded = next.initialProvider }
            if ToolsetCuration.modelCatalogToolsets.contains(toolset) {
                for provider in next.providers { await loadModels(provider.name) }
            }
        } catch {
            guard !error.isCancellation else { return }
            loadError = error.dashboardMessage
        }
    }

    func isSet(_ key: ToolsetEnvKey) -> Bool { setKeys[key.key] ?? key.isSet }

    func readiness(_ provider: ToolsetProvider) -> ToolsetProviderStatus { provider.readiness(setKeys) }

    func isActive(_ provider: ToolsetProvider) -> Bool { provider.isActive || setup?.activeProvider == provider.name }

    /// "Use this backend": writes the same keys `hermes tools` does.
    func select(_ provider: ToolsetProvider) async -> Bool {
        guard selecting == nil else { return false }
        selecting = provider.name
        defer { selecting = nil }
        do {
            let choice = try await api.selectProvider(toolset, provider: provider.name)
            setup?.activeProvider = provider.name
            setup?.providers = (setup?.providers ?? []).map { row in
                var row = row
                row.isActive = row.name == provider.name
                return row
            }
            if choice.needsNousAuth {
                needsNousSignIn = provider.name
            } else {
                notice = "\(provider.name) is now active."
            }
            if ToolsetCuration.modelCatalogToolsets.contains(toolset) { await loadModels(provider.name) }
            return true
        } catch {
            failure = "Failed to select \(provider.name). \(error.dashboardMessage)"
            return false
        }
    }

    /// Web only: one provider for search or extract, leaving the other capability as it is.
    func select(_ provider: ToolsetProvider, capability: String) async -> Bool {
        guard selecting == nil else { return false }
        selecting = provider.name
        defer { selecting = nil }
        do {
            let choice = try await api.selectProvider(toolset, provider: provider.name, capability: capability)
            if choice.needsNousAuth { needsNousSignIn = provider.name } else { notice = "\(provider.name) now handles web \(capability)." }
            // Whether the capability now rides the Nous Tool Gateway or the user's own key is resolved on the host.
            await load()
            return true
        } catch {
            failure = "Failed to set \(provider.name). \(error.dashboardMessage)"
            return false
        }
    }

    /// Saves one key through the toolset's own route (it only takes keys its providers declare). The value isn't
    /// kept: the field clears once it is sent.
    func save(_ key: ToolsetEnvKey, value: String) async -> Bool {
        savingKey = key.key
        defer { savingKey = nil }
        do {
            try await api.saveKeys(toolset, [key.key: value])
            setKeys[key.key] = true
            notice = "\(key.key) updated."
            return true
        } catch {
            failure = "Failed to save \(key.key). \(error.dashboardMessage)"
            return false
        }
    }

    func remove(_ key: ToolsetEnvKey) async {
        savingKey = key.key
        defer { savingKey = nil }
        do {
            try await api.removeKey(key.key)
            setKeys[key.key] = false
            notice = "\(key.key) removed."
        } catch {
            failure = "Failed to remove \(key.key). \(error.dashboardMessage)"
        }
    }

    /// Runs the provider's one-time install on the host and tails its log.
    func runPostSetup(_ key: String) async {
        guard postSetup[key]?.running != true else { return }
        postSetup[key] = CapabilityActionStatus(name: "tools-post-setup", running: true)
        do {
            let started = try await api.runPostSetup(toolset, key: key)
            guard started.ok else { throw DashboardError.rpc("Hermes didn't start the setup.") }
            let finished = try await actions.follow(started.name) { [weak self] status in
                self?.postSetup[key] = status
            }
            postSetup[key] = CapabilityActionStatus(name: finished.name, running: false, exitCode: finished.exitCode, lines: finished.lines)
            if finished.succeeded {
                notice = "\(key) installed."
            } else {
                failure = "Setting up \(EnvVar.prettyName(key)) did not finish. Read the log below, then run setup again."
            }
            await load()
        } catch {
            postSetup[key]?.running = false
            guard !error.isCancellation else { return }
            failure = "Failed to run \(key) setup. \(error.dashboardMessage)"
        }
    }

    func loadModels(_ provider: String) async {
        guard let catalog = try? await api.models(toolset, provider: provider) else { return }
        models[provider] = catalog
    }

    func selectModel(_ model: ToolsetModelOption, provider: String) async {
        selectingModel = model.id
        defer { selectingModel = nil }
        do {
            try await api.selectModel(toolset, model: model.id, provider: provider)
            models[provider]?.current = model.id
            notice = "\(model.id) applies to new sessions."
        } catch {
            failure = "Failed to select \(model.id). \(error.dashboardMessage)"
        }
    }
}

/// The provider sections of a toolset page.
private struct ToolsetProviderSections: View {
    @ObservedObject var model: ToolsetSetupModel
    let context: CapabilitiesContext
    let onConfiguredChange: () -> Void

    var body: some View {
        if let setup = model.setup {
            if setup.hasCategory {
                if setup.providers.isEmpty {
                    Section { FormNote("No providers are available for this toolset right now.") }.hermesFormRows()
                } else {
                    if setup.name == "web", setup.reportsWebBackends {
                        Section {
                            LabeledContent("Search") { Text(setup.webBackendLabel(search: true)) }
                            LabeledContent("Extract") { Text(setup.webBackendLabel(search: false)) }
                        } header: {
                            FormNote("In use now")
                        }
                        .hermesFormRows()
                    }
                    ForEach(setup.providers) { provider in
                        ToolsetProviderSection(model: model, setup: setup, provider: provider, onConfiguredChange: onConfiguredChange)
                    }
                    if let name = model.needsNousSignIn {
                        Section {
                            NavigationLink {
                                ProvidersScreen(client: context.client, scope: context.profile)
                            } label: {
                                Label("Sign in with your Nous account", systemImage: "person.crop.circle.badge.checkmark")
                            }
                        } footer: {
                            FormNote("\(name) is saved but will only work once you sign in with your Nous account.")
                        }
                        .hermesFormRows()
                    }
                }
            }
        } else if let error = model.loadError {
            Section {
                FormNote("Tool configuration failed to load. \(error)", color: Theme.destructive)
                Button("Try again") { Task { await model.load() } }
            }
            .hermesFormRows()
        } else {
            Section { ProgressView().frame(maxWidth: .infinity) }.hermesFormRows()
        }
    }
}

/// One provider row and, opened, its activation, keys, install and models.
private struct ToolsetProviderSection: View {
    @ObservedObject var model: ToolsetSetupModel
    let setup: ToolsetSetup
    let provider: ToolsetProvider
    let onConfiguredChange: () -> Void

    private var expanded: Bool { model.expanded == provider.name }

    var body: some View {
        let active = model.isActive(provider)
        let status = model.readiness(provider)
        let webCapabilities = setup.name == "web" ? provider.capabilities : []
        Section {
            Button {
                withAnimation { model.expanded = expanded ? nil : provider.name }
            } label: {
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(provider.name).hermesText(.rowTitle).foregroundStyle(Theme.Text.primary)
                        tags(active: active, status: status)
                    }
                    Spacer(minLength: 0)
                    if model.selecting == provider.name { ProgressView() }
                    Image(systemName: "chevron.right")
                        .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                        .foregroundStyle(Theme.Text.quaternary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(expanded ? .isSelected : [])

            if expanded {
                if !provider.tag.isEmpty { FormNote(provider.tag) }
                if webCapabilities.isEmpty {
                    if active {
                        Label("This is your active backend", systemImage: "checkmark.circle").foregroundStyle(Theme.primary)
                    } else {
                        Button {
                            Task { if await model.select(provider) { onConfiguredChange() } }
                        } label: {
                            Label("Use this backend", systemImage: "checkmark")
                        }
                        .disabled(model.selecting != nil)
                    }
                } else {
                    if webCapabilities.contains("search") {
                        Button("Use for Search") { Task { if await model.select(provider, capability: "search") { onConfiguredChange() } } }
                            .disabled(model.selecting != nil || setup.serves(provider, search: true))
                    }
                    if webCapabilities.contains("extract") {
                        Button("Use for Extract") { Task { if await model.select(provider, capability: "extract") { onConfiguredChange() } } }
                            .disabled(model.selecting != nil || setup.serves(provider, search: false))
                    }
                }
                if provider.requiresNousAuth, status == .needsAuth {
                    FormNote("Included with a Nous subscription — sign in with your Nous account to activate.")
                }
                if provider.envKeys.isEmpty {
                    FormNote("No API key required.")
                } else {
                    ForEach(provider.envKeys) { key in
                        ToolsetKeyRow(model: model, key: key, onChange: onConfiguredChange)
                    }
                }
                if let postSetup = provider.postSetup {
                    ToolsetPostSetupRow(model: model, key: postSetup, installed: provider.status == .ready)
                }
                if ToolsetCuration.modelCatalogToolsets.contains(setup.name), let catalog = model.models[provider.name], !catalog.models.isEmpty {
                    ToolsetModelRows(model: model, provider: provider.name, catalog: catalog, activeBackend: active)
                }
            }
        }
        .hermesFormRows()
    }

    private func tags(active: Bool, status: ToolsetProviderStatus) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            if !provider.badge.isEmpty { StatusTag(provider.badge) }
            if active { StatusTag("Active", tone: .accent, systemImage: "checkmark") }
            switch status {
            case .ready where !active: StatusTag("Ready", tone: .good, systemImage: "checkmark")
            case .needsAuth: StatusTag("Needs sign-in", tone: .warning)
            case .needsSetup: StatusTag("Setup required", tone: .warning)
            default: EmptyView()
            }
            if setup.name == "web", setup.serves(provider, search: true) { StatusTag("Search backend", tone: .accent) }
            if setup.name == "web", setup.serves(provider, search: false) { StatusTag("Extract backend", tone: .accent) }
        }
    }
}

/// One key a provider needs (`EnvVarField`): set or not, and a field to paste a new value. The value is sent to
/// the dashboard and dropped; nothing on the phone keeps or logs it.
private struct ToolsetKeyRow: View {
    @ObservedObject var model: ToolsetSetupModel
    let key: ToolsetEnvKey
    let onChange: () -> Void
    @State private var editing = false
    @State private var value = ""
    @State private var confirmingRemove = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        let isSet = model.isSet(key)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(key.key).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.primary)
                StatusTag(isSet ? "Set" : "Not set", tone: isSet ? .accent : .muted, systemImage: isSet ? "checkmark" : nil)
                Spacer(minLength: 0)
                if model.savingKey == key.key {
                    ProgressView()
                } else if !editing {
                    Menu {
                        Button { editing = true } label: { Label(isSet ? "Replace" : "Set", systemImage: Theme.Icon.rename) }
                        if let link = key.url.flatMap(URL.init(string:)) {
                            Button { openURL(link) } label: { Label("Get a key", systemImage: "arrow.up.right.square") }
                        }
                        if isSet {
                            Button(role: .destructive) { confirmingRemove = true } label: { Label("Remove", systemImage: Theme.Icon.delete) }
                        }
                    } label: {
                        Image(systemName: Theme.Icon.more).frame(width: 28, height: 28).contentShape(Rectangle())
                    }
                    .accessibilityLabel("\(key.key) actions")
                }
            }
            if key.prompt != key.key { Text(key.prompt).hermesText(.caption).foregroundStyle(Theme.Text.tertiary) }
            if editing {
                Group {
                    if key.defaultValue != nil {
                        TextField(key.prompt, text: $value)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.TextStyle.code.font)
                            .onSubmit(save)
                    } else {
                        SecretInput(title: key.prompt, text: $value, onSubmit: save)
                    }
                }
                .padding(Theme.Spacing.md)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                HStack {
                    Button("Save", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.savingKey != nil)
                    Button("Cancel") {
                        editing = false
                        value = ""
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .confirmationDialog("Remove \(key.key) from .env?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    await model.remove(key)
                    onChange()
                }
            }
        } message: {
            Text("Tools that need it stop working until a new value is set.")
        }
    }

    private func save() {
        let typed = value
        Task {
            if await model.save(key, value: typed) {
                editing = false
                onChange()
            }
            value = ""
        }
    }
}

/// A provider's one-time install (`PostSetupRunner`), tailed inline.
private struct ToolsetPostSetupRow: View {
    @ObservedObject var model: ToolsetSetupModel
    let key: String
    let installed: Bool

    var body: some View {
        let status = model.postSetup[key]
        let running = status?.running == true
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(installed ? "Installed. Re-run setup only if something is broken."
                           : "This backend needs a one-time install (\(key)). It runs on the Hermes host and may take a few minutes.")
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.tertiary)
            HStack(spacing: Theme.Spacing.md) {
                if installed { StatusTag("Installed", tone: .accent, systemImage: "checkmark") }
                Button {
                    Task { await model.runPostSetup(key) }
                } label: {
                    Label(running ? "Installing…" : installed ? "Re-run setup" : "Run setup", systemImage: Theme.Icon.terminal)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(running)
                if running { ProgressView() }
            }
            if let status, running || !status.lines.isEmpty {
                CapabilityActionLog(lines: status.lines)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }
}

/// An image or video backend's model catalog (`ModelCatalogPicker`).
private struct ToolsetModelRows: View {
    @ObservedObject var model: ToolsetSetupModel
    let provider: String
    let catalog: ToolsetModelCatalog
    let activeBackend: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack {
                Text("Model").hermesText(.label).foregroundStyle(Theme.Text.secondary)
                Spacer()
                Text("\(catalog.models.count) model\(catalog.models.count == 1 ? "" : "s")").hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
            }
            if !activeBackend {
                Text("Select this backend first to change its model.").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
        }
        ForEach(catalog.models) { option in
            Button {
                Task { await model.selectModel(option, provider: provider) }
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(option.display).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.primary)
                            if catalog.selected == option.id {
                                StatusTag("In use", tone: .accent, systemImage: "checkmark")
                            } else if catalog.defaultModel == option.id {
                                StatusTag("default")
                            }
                        }
                        let facts = [option.speed, option.strengths, option.price].filter { !$0.isEmpty }
                        if !facts.isEmpty {
                            Text(facts.joined(separator: " · ")).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                    Spacer(minLength: 0)
                    if model.selectingModel == option.id { ProgressView() }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!activeBackend || model.selectingModel != nil)
            .opacity(activeBackend ? 1 : 0.6)
        }
    }
}
