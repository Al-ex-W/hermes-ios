import SwiftUI

/// A provider and model pair (`{provider, model}` in fallbacks, MoA slots and routes).
struct ModelRoute: Hashable {
    var provider: String
    var model: String
}

/// The providers and models the host offers (`GET /api/model/options`, the `model.options` twin), shared by every
/// model picker in Settings.
@MainActor
final class ModelCatalog: ObservableObject {
    @Published private(set) var providers: [ModelOptionProvider] = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?

    let api: ConfigAPI

    init(api: ConfigAPI) {
        self.api = api
    }

    func load(refresh: Bool = false) async {
        do {
            providers = try await api.modelOptions(refresh: refresh).providers
            error = nil
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.localizedDescription
        }
        loaded = true
    }

    /// The catalog row for a provider slug, alias or name (`findCatalogProvider`), case-insensitively.
    func provider(_ slug: String) -> ModelOptionProvider? {
        let wanted = slug.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return nil }
        return providers.first { row in
            row.slug.lowercased() == wanted || (row.aliases ?? []).contains { $0.lowercased() == wanted }
        } ?? providers.first { $0.name.lowercased() == wanted }
    }

    func providerName(_ slug: String) -> String {
        provider(slug)?.name ?? (slug.isEmpty ? "Auto" : slug)
    }

    func capabilities(_ route: ModelRoute) -> ModelCapabilities? {
        provider(route.provider)?.capabilities?[route.model]
    }

    /// "model · Provider", or the model alone when the provider is unknown.
    func describe(_ route: ModelRoute) -> String {
        guard !route.model.isEmpty else { return "Not set" }
        guard !route.provider.isEmpty else { return route.model }
        return "\(route.model) · \(providerName(route.provider))"
    }
}

// MARK: - Picker

/// Picks a provider, then one of its models (or a typed model id). Providers that aren't signed in show, greyed,
/// so the list matches the desktop's; they are set up on the Providers page.
struct ModelRoutePicker: View {
    @EnvironmentObject private var catalog: ModelCatalog
    let title: String
    let current: ModelRoute?
    /// A first row that clears the route ("Same as main model").
    var clearLabel: String?
    let choose: (ModelRoute?) -> Void

    var body: some View {
        List {
            if let clearLabel {
                Section {
                    Button {
                        choose(nil)
                    } label: {
                        HStack {
                            Text(clearLabel).foregroundStyle(Theme.Text.primary)
                            Spacer()
                            if current == nil { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
                        }
                    }
                }
                .hermesFormRows()
            }
            Section {
                ForEach(catalog.providers, id: \.slug) { provider in
                    let usable = provider.authenticated ?? true
                    NavigationLink {
                        ProviderModelList(provider: provider, current: current, choose: choose)
                    } label: {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(provider.name).foregroundStyle(usable ? Theme.Text.primary : Theme.Text.quaternary)
                            if !usable {
                                Text("Not connected. Set it up under Providers.").hermesText(.caption)
                                    .foregroundStyle(Theme.Text.tertiary)
                            } else if let warning = provider.warning, !warning.isEmpty {
                                Text(warning).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                            }
                        }
                    }
                    .disabled(!usable)
                }
            } header: {
                FormNote("Providers")
            } footer: {
                if let error = catalog.error { FormNote(error, color: Theme.destructive) }
            }
            .hermesFormRows()
        }
        .overlay {
            if !catalog.loaded { ProgressView() }
            else if catalog.providers.isEmpty && catalog.error == nil {
                ContentUnavailableView("No providers", systemImage: "shippingbox",
                                       description: Text("Connect a provider on the host first."))
            }
        }
        .refreshable { await catalog.load(refresh: true) }
        .task { if !catalog.loaded { await catalog.load() } }
        .hermesForm()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ProviderModelList: View {
    let provider: ModelOptionProvider
    let current: ModelRoute?
    let choose: (ModelRoute?) -> Void

    @State private var custom = ""

    private var models: [String] {
        let featured = provider.featuredModels ?? []
        let rest = (provider.models ?? []).filter { !featured.contains($0) }
        return featured + rest
    }

    var body: some View {
        List {
            Section {
                ForEach(models, id: \.self) { model in
                    let unavailable = (provider.unavailableModels ?? []).contains(model)
                    Button {
                        choose(ModelRoute(provider: provider.slug, model: model))
                    } label: {
                        HStack {
                            Text(model)
                                .foregroundStyle(unavailable ? Theme.Text.quaternary : Theme.Text.primary)
                                .lineLimit(1)
                            Spacer()
                            if let price = provider.pricing?[model], !price.input.isEmpty {
                                Text(price.free ? "Free" : "\(price.input) / \(price.output)")
                                    .hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                            }
                            if current == ModelRoute(provider: provider.slug, model: model) {
                                Image(systemName: "checkmark").foregroundStyle(Theme.primary)
                            }
                        }
                    }
                    .disabled(unavailable)
                }
            } header: {
                FormNote(provider.name)
            }
            .hermesFormRows()
            Section {
                HStack {
                    TextField("Model id", text: $custom)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(useCustom)
                    Button("Use", action: useCustom)
                        .disabled(custom.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                FormNote("Other model")
            }
            .hermesFormRows()
        }
        .hermesForm()
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func useCustom() {
        let model = custom.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { return }
        choose(ModelRoute(provider: provider.slug, model: model))
    }
}

extension View {
    /// Presents the route picker in a sheet of its own; picking (or clearing) closes it.
    func modelRoutePicker(isPresented: Binding<Bool>, catalog: ModelCatalog, title: String, current: ModelRoute?,
                          clearLabel: String? = nil, choose: @escaping (ModelRoute?) -> Void) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                ModelRoutePicker(title: title, current: current, clearLabel: clearLabel) { route in
                    isPresented.wrappedValue = false
                    choose(route)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isPresented.wrappedValue = false }
                    }
                }
            }
            .environmentObject(catalog)
        }
    }
}

// MARK: - Main model

/// Settings > Model > Main model (`ModelSettings` main + `MainModelDefaults`): the default model, applied through
/// `POST /api/model/set` (new sessions only), and the profile's reasoning and Fast defaults.
struct MainModelSection: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var catalog: ModelCatalog
    @State private var info: ConfigAPI.ModelInfo?
    @State private var applying = false
    @State private var message: String?
    @State private var failure: String?
    @State private var pendingConfirm: (route: ModelRoute, message: String)?
    @State private var picking = false

    private var main: ModelRoute {
        if let info, !info.model.isEmpty { return ModelRoute(provider: info.provider, model: info.model) }
        return ModelRoute(provider: store.value("model.provider")?.stringValue ?? "",
                          model: store.value("model")?.displayText ?? "")
    }

    /// `agent.reasoning_effort` as the menu shows it: a hand-written false or "disabled" reads as Off, empty as
    /// the default effort.
    static func effort(_ value: JSONValue?) -> String {
        let raw = (value?.displayText ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if raw == "false" || raw == "disabled" { return "none" }
        return raw.isEmpty ? "medium" : raw
    }

    /// Fast is on for the tiers the composer reads as priority (`composerServiceTier`).
    static func fastOn(_ value: JSONValue?) -> Bool {
        ["fast", "priority", "on"].contains((value?.displayText ?? "").trimmingCharacters(in: .whitespaces).lowercased())
    }

    var body: some View {
        let caps = catalog.capabilities(main)
        Section {
            SettingsRow(title: SettingsCatalog.label(for: "model"), description: SettingsCatalog.descriptions["model"],
                        error: failure, saving: applying, wide: true) {
                Button { picking = true } label: {
                    HStack {
                        Text(catalog.describe(main)).foregroundStyle(Theme.Text.primary).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(Theme.Text.quaternary)
                    }
                }
                .disabled(applying)
            }
            .id("model.main-model")
            if let message { FormNote(message) }
            if caps?.reasoning ?? true {
                let efforts = ["none"] + SettingsCatalog.reasoningEfforts
                let current = Self.effort(store.value("agent.reasoning_effort"))
                SettingsRow(title: "Reasoning", error: store.errors["agent.reasoning_effort"],
                            saving: store.saving.contains("agent.reasoning_effort")) {
                    Picker("Reasoning", selection: Binding(get: { current }, set: { store.set("agent.reasoning_effort", .string($0)) })) {
                        ForEach(efforts.contains(current) ? efforts : efforts + [current], id: \.self) { effort in
                            Text(effort == "none" ? "Off" : SettingsText.prettyName(effort)).tag(effort)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .id("model.reasoning")
            }
            if caps?.fast ?? false {
                SettingsRow(title: "Fast", description: "Priority processing for new chats.",
                            error: store.errors["agent.service_tier"], saving: store.saving.contains("agent.service_tier")) {
                    Toggle("Fast", isOn: Binding(get: { Self.fastOn(store.value("agent.service_tier")) },
                                                 set: { store.set("agent.service_tier", .string($0 ? "fast" : "normal")) }))
                        .labelsHidden()
                }
                .id("model.fast")
            }
        } footer: {
            FormNote("Applies to new chats. A running chat switches with the model pill in the composer.")
        }
        .hermesFormRows()
        .modelRoutePicker(isPresented: $picking, catalog: catalog, title: "Default Model", current: main) { route in
            if let route { Task { await apply(route) } }
        }
        .alert("Use this model?", isPresented: Binding(get: { pendingConfirm != nil }, set: { if !$0 { pendingConfirm = nil } }),
               presenting: pendingConfirm) { pending in
            Button("Cancel", role: .cancel) {}
            Button("Use it") { Task { await apply(pending.route, confirmed: true) } }
        } message: { pending in
            Text(pending.message)
        }
        .task { await refreshInfo() }
    }

    /// The detected context window, for the override row beside this section.
    static func contextNote(_ info: ConfigAPI.ModelInfo?) -> String? {
        guard let info, info.autoContextLength > 0 else { return nil }
        return "Detected: \(info.autoContextLength.formatted()) tokens."
    }

    private func refreshInfo() async {
        info = try? await catalog.api.modelInfo()
        if !catalog.loaded { await catalog.load() }
    }

    private func apply(_ route: ModelRoute, confirmed: Bool = false) async {
        applying = true
        failure = nil
        message = nil
        defer { applying = false }
        do {
            let result = try await catalog.api.assignModel(.init(
                scope: .main, provider: route.provider, model: route.model,
                baseURL: catalog.provider(route.provider)?.apiUrl, confirmExpensiveModel: confirmed
            ))
            if let confirm = result.confirmMessage {
                pendingConfirm = (route, confirm)
                return
            }
            guard result.ok else {
                failure = "Hermes didn't switch the model."
                return
            }
            message = result.notice ?? "New chats use \(result.model ?? route.model)."
            NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
            await refreshInfo()
            await store.load()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Auxiliary models

/// Settings > Model > Auxiliary models: each side task's model, "Use main model" by default
/// (`/api/model/auxiliary`, assigned with `POST /api/model/set` scope auxiliary).
struct AuxiliaryModelsSection: View {
    @EnvironmentObject private var catalog: ModelCatalog
    @State private var tasks: [ConfigAPI.AuxiliaryTask] = []
    @State private var main = ModelRoute(provider: "", model: "")
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?
    @State private var editing: ConfigAPI.AuxiliaryTask?

    /// `en_aux_tasks.ts`: built-in tasks have client-side copy; plugin tasks bring their own.
    static let builtinCopy: [String: (label: String, hint: String)] = [
        "vision": ("Vision", "Image analysis"),
        "compression": ("Compression", "Context compaction"),
        "skills_hub": ("Skills hub", "Skill search"),
        "approval": ("Approval", "Smart auto-approve"),
        "mcp": ("MCP", "MCP tool routing"),
        "title_generation": ("Title gen", "Session titles"),
        "review": ("Review", "/review reviewer subagent"),
        "triage_specifier": ("Triage specifier", "Kanban spec fleshing"),
        "kanban_decomposer": ("Kanban decomposer", "Task decomposition"),
        "profile_describer": ("Profile describer", "Auto profile descriptions"),
        "curator": ("Curator", "Skill-usage review"),
    ]

    var body: some View {
        Section {
            if loading {
                ProgressView().frame(maxWidth: .infinity)
            }
            ForEach(tasks) { task in
                let copy = Self.builtinCopy[task.task]
                Button { editing = task } label: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        HStack {
                            Text(Self.title(task)).foregroundStyle(Theme.Text.primary)
                            Spacer()
                            Text(task.followsMain ? "Main model" : catalog.describe(ModelRoute(provider: task.provider, model: task.model)))
                                .foregroundStyle(Theme.Text.tertiary).lineLimit(1)
                        }
                        if let hint = copy?.hint ?? task.hint {
                            Text(hint).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
                .disabled(busy)
            }
            if !tasks.isEmpty {
                Button("Reset all to main model", role: .destructive) { Task { await resetAll() } }
                    .disabled(busy || main.model.isEmpty)
            }
        } header: {
            FormNote("Side tasks")
        } footer: {
            if let failure { FormNote(failure, color: Theme.destructive) }
            else { FormNote("Each side task uses the main model unless you pick one for it.") }
        }
        .hermesFormRows()
        .id("model.auxiliary")
        .modelRoutePicker(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } }),
                          catalog: catalog, title: editing.map(Self.title) ?? "",
                          current: editing.flatMap { $0.followsMain ? nil : ModelRoute(provider: $0.provider, model: $0.model) },
                          clearLabel: "Use main model") { [editing] route in
            guard let task = editing?.task else { return }
            Task { await assign(task, route) }
        }
        .task { await reload() }
    }

    static func title(_ task: ConfigAPI.AuxiliaryTask) -> String {
        builtinCopy[task.task]?.label ?? task.label ?? task.task
    }

    private func reload() async {
        do {
            let result = try await catalog.api.auxiliaryModels()
            tasks = result.tasks.filter { !SettingsCatalog.strippedAuxiliaryTasks.contains($0.task) }
            main = ModelRoute(provider: result.mainProvider, model: result.mainModel)
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
        loading = false
        if !catalog.loaded { await catalog.load() }
    }

    private func assign(_ task: String, _ route: ModelRoute?) async {
        busy = true
        defer { busy = false }
        // "Use main model" stores provider auto with no model, as the desktop's per-row reset does.
        let target = route ?? ModelRoute(provider: "auto", model: "")
        do {
            _ = try await catalog.api.assignModel(.init(
                scope: .auxiliary, provider: target.provider, model: target.model, task: task,
                baseURL: route.flatMap { catalog.provider($0.provider)?.apiUrl }, confirmExpensiveModel: true
            ))
            await reload()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func resetAll() async {
        busy = true
        defer { busy = false }
        do {
            _ = try await catalog.api.assignModel(.init(scope: .auxiliary, provider: main.provider, model: main.model,
                                                       task: "__reset__"))
            await reload()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Mixture of Agents

/// Settings > Model > Mixture of Agents: the presets' reference models and aggregator (`/api/model/moa`). The
/// whole MoA record is sent back on save, so members this page doesn't edit survive.
struct MoaSection: View {
    @EnvironmentObject private var catalog: ModelCatalog
    @State private var moa: JSONValue?
    @State private var selected = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var addingReference = false
    @State private var pickingAggregator = false

    private var presetNames: [String] { (moa?["presets"]?.objectValue?.keys).map { Array($0).sorted() } ?? [] }
    private var defaultPreset: String { moa?["default_preset"]?.stringValue ?? "" }
    private var presetName: String { presetNames.contains(selected) ? selected : (presetNames.contains(defaultPreset) ? defaultPreset : presetNames.first ?? "") }
    private var preset: JSONValue? { moa?["presets"]?[presetName] }

    static func route(_ slot: JSONValue?) -> ModelRoute {
        ModelRoute(provider: slot?["provider"]?.stringValue ?? "", model: slot?["model"]?.stringValue ?? "")
    }

    var body: some View {
        Group {
            if moa == nil {
                Section {
                    if let failure { FormNote(failure, color: Theme.destructive) } else { ProgressView().frame(maxWidth: .infinity) }
                }
                .hermesFormRows()
            } else {
                presetSection
                referenceSection
                aggregatorSection
            }
        }
        .id("model.moa")
        .task { await reload() }
    }

    @ViewBuilder private var presetSection: some View {
        if presetNames.count > 1 {
            Section {
                Picker("Preset", selection: Binding(get: { presetName }, set: { selected = $0 })) {
                    ForEach(presetNames, id: \.self) { Text($0).tag($0) }
                }
                if presetName != defaultPreset {
                    Button("Make default") { update { $0 = $0.setting("default_preset", .string(presetName)) } }
                        .disabled(saving)
                }
            } footer: {
                FormNote("Default preset: \(defaultPreset)")
            }
            .hermesFormRows()
        }
    }

    private var referenceSection: some View {
        let slots = preset?["reference_models"]?.arrayValue ?? []
        return Section {
            ForEach(Array(slots.enumerated()), id: \.offset) { index, slot in
                HStack {
                    Text(catalog.describe(Self.route(slot))).foregroundStyle(Theme.Text.primary).lineLimit(1)
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { slot["enabled"]?.boolValue ?? true }, set: { on in
                        updateSlots { $0[index] = $0[index].setting("enabled", .bool(on)) }
                    }))
                    .labelsHidden()
                }
                .swipeActions {
                    Button("Remove", role: .destructive) { updateSlots { $0.remove(at: index) } }
                }
            }
            Button { addingReference = true } label: {
                Label("Add reference model", systemImage: "plus")
            }
            .disabled(saving)
            .modelRoutePicker(isPresented: $addingReference, catalog: catalog, title: "Add reference model", current: nil) { route in
                guard let route else { return }
                updateSlots { $0.append(["provider": .string(route.provider), "model": .string(route.model), "enabled": true]) }
            }
        } header: {
            FormNote("Reference models")
        } footer: {
            if let failure { FormNote(failure, color: Theme.destructive) }
            else { FormNote("Each reference model answers on its own; swipe to remove one.") }
        }
        .hermesFormRows()
    }

    private var aggregatorSection: some View {
        let current = Self.route(preset?["aggregator"])
        return Section {
            Button { pickingAggregator = true } label: {
                HStack {
                    Text("Aggregator").foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Text(catalog.describe(current)).foregroundStyle(Theme.Text.tertiary).lineLimit(1)
                }
            }
            .disabled(saving)
            .modelRoutePicker(isPresented: $pickingAggregator, catalog: catalog, title: "Aggregator", current: current) { route in
                guard let route else { return }
                updatePreset { $0.setting("aggregator", ($0["aggregator"] ?? .object([:]))
                    .setting("provider", .string(route.provider)).setting("model", .string(route.model))) }
            }
        } footer: {
            FormNote("Merges the reference answers into one reply.")
        }
        .hermesFormRows()
    }

    private func reload() async {
        do {
            moa = try await catalog.api.moa()
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
        if !catalog.loaded { await catalog.load() }
    }

    private func updateSlots(_ change: @escaping (inout [JSONValue]) -> Void) {
        updatePreset { preset in
            var slots = preset["reference_models"]?.arrayValue ?? []
            change(&slots)
            return preset.setting("reference_models", .array(slots))
        }
    }

    private func updatePreset(_ change: @escaping (JSONValue) -> JSONValue) {
        let name = presetName
        update { moa in
            guard let preset = moa["presets"]?[name] else { return }
            let presets = (moa["presets"] ?? .object([:])).setting(name, change(preset))
            moa = moa.setting("presets", presets)
        }
    }

    /// Saves at once with the page showing the change; a refusal (the server rejects incomplete slots) puts the
    /// saved record back.
    private func update(_ change: (inout JSONValue) -> Void) {
        guard var next = moa, let previous = moa else { return }
        change(&next)
        moa = next
        saving = true
        failure = nil
        Task {
            do {
                let saved = try await catalog.api.saveMoa(next)
                if saved["presets"] != nil { moa = saved.objectValue.map { .object($0.filter { $0.key != "ok" }) } ?? saved }
            } catch {
                moa = previous
                failure = error.localizedDescription
            }
            saving = false
        }
    }
}

// MARK: - Fallbacks and subagents

/// `fallback_providers`: an ordered list of `{provider, model, ...}` entries. Only provider and model are edited;
/// hand-written routing keys on an entry ride along untouched (`FallbackModelsField`).
struct FallbackModelsEditor: View {
    @EnvironmentObject private var catalog: ModelCatalog
    let value: JSONValue?
    let commit: (JSONValue) -> Void
    @State private var adding = false

    /// Rows from the raw value; legacy `provider/model` strings are read too.
    static func entries(_ value: JSONValue?) -> [JSONValue] {
        (value?.arrayValue ?? []).map { item in
            if item.objectValue != nil { return item }
            let text = item.stringValue ?? ""
            if let slash = text.firstIndex(of: "/"), slash != text.startIndex {
                return ["provider": .string(String(text[..<slash])), "model": .string(String(text[text.index(after: slash)...]))]
            }
            return ["provider": "", "model": .string(text)]
        }
    }

    var body: some View {
        let rows = Self.entries(value)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: Theme.Spacing.md) {
                    Text("\(index + 1).").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                    Text(catalog.describe(MoaSection.route(row))).foregroundStyle(Theme.Text.primary).lineLimit(1)
                    Spacer()
                    if index > 0 {
                        Button { move(rows, index, by: -1) } label: { Image(systemName: "arrow.up") }
                            .buttonStyle(.borderless)
                    }
                    Button(role: .destructive) {
                        var next = rows
                        next.remove(at: index)
                        commit(.array(next))
                    } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            Button { adding = true } label: {
                Label("Add fallback", systemImage: "plus").hermesText(.button)
            }
            .buttonStyle(.borderless)
        }
        .modelRoutePicker(isPresented: $adding, catalog: catalog, title: "Add fallback", current: nil) { route in
            guard let route else { return }
            commit(.array(rows + [["provider": .string(route.provider), "model": .string(route.model)]]))
        }
        .task { if !catalog.loaded { await catalog.load() } }
    }

    private func move(_ rows: [JSONValue], _ index: Int, by offset: Int) {
        var next = rows
        next.swapAt(index, index + offset)
        commit(.array(next))
    }
}

/// `delegation.model` with `delegation.provider`: the subagents' route, empty for "same as the main model"
/// (`DelegationRouteRow`). Both keys are saved together.
struct DelegationRouteRow: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var catalog: ModelCatalog
    var error: String?
    var saving = false
    @State private var picking = false

    var body: some View {
        let route = ModelRoute(provider: store.value("delegation.provider")?.displayText ?? "",
                               model: store.value("delegation.model")?.displayText ?? "")
        let inherits = route.model.isEmpty
        SettingsRow(title: SettingsCatalog.label(for: "delegation.model"),
                    description: "The model subagents run on. Same as the main model unless you pick one.",
                    error: error ?? store.errors["delegation.provider"], saving: saving) {
            Button { picking = true } label: {
                Text(inherits ? "Main model" : catalog.describe(route))
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
            }
            .buttonStyle(.borderless)
            .fixedSize()
        }
        .modelRoutePicker(isPresented: $picking, catalog: catalog, title: "Subagent Model", current: inherits ? nil : route,
                          clearLabel: "Same as main model") { picked in
            store.set([SettingsStore.Entry(key: "delegation.provider", value: .string(picked?.provider ?? "")),
                       SettingsStore.Entry(key: "delegation.model", value: .string(picked?.model ?? ""))])
        }
        .task { if !catalog.loaded { await catalog.load() } }
    }
}
