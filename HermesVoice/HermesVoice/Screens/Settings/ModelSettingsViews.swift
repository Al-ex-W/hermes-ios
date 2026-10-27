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
    /// The models that offer Ultrafast, by provider slug.
    @Published private(set) var ultrafast: Set<ModelRoute> = []
    @Published private(set) var loaded = false
    @Published private(set) var error: String?

    let api: ConfigAPI

    init(api: ConfigAPI) {
        self.api = api
    }

    func load(refresh: Bool = false) async {
        do {
            let options = try await api.modelOptions(refresh: refresh)
            providers = options.result.providers
            ultrafast = options.ultrafast
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

    /// The model offers the Ultrafast tier (`capabilities[model].ultrafast`).
    func offersUltrafast(_ route: ModelRoute) -> Bool {
        guard let slug = provider(route.provider)?.slug else { return false }
        return ultrafast.contains(ModelRoute(provider: slug, model: route.model))
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
        speed(value) == "fast"
    }

    /// `agent.service_tier` as the Speed choice shows it (`speedValue`): fast, ultrafast, or normal (Standard).
    static func speed(_ value: JSONValue?) -> String {
        switch (value?.displayText ?? "").trimmingCharacters(in: .whitespaces).lowercased() {
        case "fast", "priority", "on": return "fast"
        case "ultrafast", "ultra": return "ultrafast"
        default: return "normal"
        }
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
            // On this one row: a Section hands its modifiers to every row, and several rows presenting one sheet
            // make UIKit dismiss Settings itself.
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
            let speed = Self.speed(store.value("agent.service_tier"))
            // Standard, Fast and Ultrafast where the model offers Ultrafast (or it is the saved tier, so it shows as
            // itself rather than as Off); a Fast switch otherwise.
            if catalog.offersUltrafast(main) || speed == "ultrafast" {
                SettingsRow(title: "Speed", error: store.errors["agent.service_tier"],
                            saving: store.saving.contains("agent.service_tier")) {
                    Picker("Speed", selection: Binding(get: { speed }, set: { store.set("agent.service_tier", .string($0)) })) {
                        Text("Standard").tag("normal")
                        if caps?.fast ?? false || speed == "fast" { Text("Fast").tag("fast") }
                        Text("Ultrafast").tag("ultrafast")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                .id("model.fast")
            } else if caps?.fast ?? false {
                SettingsRow(title: "Fast", description: "Priority processing for new chats.",
                            error: store.errors["agent.service_tier"], saving: store.saving.contains("agent.service_tier")) {
                    Toggle("Fast", isOn: Binding(get: { speed == "fast" },
                                                 set: { store.set("agent.service_tier", .string($0 ? "fast" : "normal")) }))
                        .labelsHidden()
                }
                .id("model.fast")
            }
        } footer: {
            FormNote("Applies to new chats. A running chat switches with the model pill in the composer.")
                .task { await refreshInfo() }
        }
        .hermesFormRows()
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

/// Settings > Model > Auxiliary models: each side task's model and reasoning effort, the main model by default
/// (`/api/model/auxiliary`, assigned with `POST /api/model/set` scope auxiliary). A plugin task registered with
/// `inherit_from` follows its base task instead until it is pinned.
struct AuxiliaryModelsSection: View {
    @EnvironmentObject private var catalog: ModelCatalog
    @State private var tasks: [ConfigAPI.AuxiliaryTask] = []
    @State private var loading = true
    @State private var busy = false
    @State private var failure: String?
    @State private var editing: ConfigAPI.AuxiliaryTask?
    @State private var pendingConfirm: (assignment: ConfigAPI.ModelAssignment, message: String)?
    @State private var confirmingReset = false

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

    /// The editor's "inherit" effort choice (no `reasoning_effort` on the slot).
    static let inheritEffort = "__inherit__"

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
                            Text(Self.summary(task, in: tasks, catalog: catalog))
                                .foregroundStyle(Theme.Text.tertiary).lineLimit(1)
                        }
                        if let hint = copy?.hint ?? task.hint {
                            Text(hint).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
                .disabled(busy)
                // Presented from the row that was tapped: a Section hands its modifiers to every row, and several
                // rows presenting at once make UIKit dismiss Settings itself.
                .sheet(isPresented: Binding(get: { editing?.id == task.id }, set: { if !$0 { editing = nil } })) {
                    AuxiliaryTaskEditor(task: task, title: Self.title(task),
                                        baseLabel: task.inheritFrom.map { Self.baseTitle($0, in: tasks) }) { route, effort in
                        Task { await assign(Self.assignment(task: task.task, route: route, effort: effort, catalog: catalog)) }
                    }
                    .environmentObject(catalog)
                }
                .alert("Use this model?", isPresented: Binding(get: { pendingConfirm?.assignment.task == task.task },
                                                               set: { if !$0 { pendingConfirm = nil } }),
                       presenting: pendingConfirm) { pending in
                    Button("Cancel", role: .cancel) {}
                    Button("Use it") {
                        var confirmed = pending.assignment
                        confirmed.confirmExpensiveModel = true
                        Task { await assign(confirmed) }
                    }
                } message: { pending in
                    Text(pending.message)
                }
            }
            if !tasks.isEmpty {
                Button("Reset all to main model", role: .destructive) { confirmingReset = true }
                    .disabled(busy || tasks.allSatisfy { $0.isAuto && $0.reasoningEffort == nil })
                    .confirmationDialog("Reset every side task to the main model?", isPresented: $confirmingReset,
                                        titleVisibility: .visible) {
                        Button("Reset all", role: .destructive) { Task { await resetAll() } }
                    } message: {
                        Text("Their own models and reasoning settings are cleared.")
                    }
            }
        } header: {
            FormNote("Side tasks")
                .task { await reload() }
        } footer: {
            if let failure { FormNote(failure, color: Theme.destructive) }
            else { FormNote("Each side task uses the main model unless you pick one for it.") }
        }
        .hermesFormRows()
        .id("model.auxiliary")
    }

    static func title(_ task: ConfigAPI.AuxiliaryTask) -> String {
        builtinCopy[task.task]?.label ?? task.label ?? task.task
    }

    /// A task's label by key (an inheriting task's base).
    static func baseTitle(_ key: String, in tasks: [ConfigAPI.AuxiliaryTask]) -> String {
        tasks.first { $0.task == key }.map(title) ?? builtinCopy[key]?.label ?? key
    }

    /// The row's route line (`AuxTaskRouteSummary`): the pinned route, "Main model", or for an unpinned
    /// inheriting task "Follows <Base> · <the route it resolves to>"; then the task's own reasoning effort.
    static func summary(_ task: ConfigAPI.AuxiliaryTask, in tasks: [ConfigAPI.AuxiliaryTask], catalog: ModelCatalog) -> String {
        var line: String
        if let route = task.route {
            line = route.model.isEmpty ? "\(catalog.providerName(route.provider)) · provider default" : catalog.describe(route)
        } else if let base = task.inheritFrom {
            let effective = task.effective.flatMap { $0.provider.isEmpty || $0.provider.lowercased() == "auto" ? nil : $0 }
            let resolved = effective.map { $0.model.isEmpty ? catalog.providerName($0.provider) : catalog.describe($0) } ?? "Main model"
            line = "Follows \(baseTitle(base, in: tasks)) · \(resolved)"
        } else {
            line = "Main model"
        }
        if let effort = task.reasoningEffort {
            line += effort == "none" ? " · Reasoning off" : " · \(SettingsText.prettyName(effort))"
        }
        return line
    }

    /// The `POST /api/model/set` body for an edit: a route pins the task (with a user-defined provider's endpoint),
    /// none puts it back on auto (the main model, or its base); the effort is always sent (inherit clears it).
    static func assignment(task: String, route: ModelRoute?, effort: String, catalog: ModelCatalog) -> ConfigAPI.ModelAssignment {
        let target = route ?? ModelRoute(provider: "auto", model: "")
        return ConfigAPI.ModelAssignment(
            scope: .auxiliary, provider: target.provider, model: target.model, task: task,
            baseURL: route.flatMap { catalog.provider($0.provider)?.apiUrl },
            reasoningEffort: effort == inheritEffort ? .null : .string(effort)
        )
    }

    /// "Reset all": one auto assignment per task shown here. The server's `__reset__` would also reset the tasks
    /// this app hides (voice chat), which the user can't see from the phone.
    static func resetAssignments(_ tasks: [ConfigAPI.AuxiliaryTask]) -> [ConfigAPI.ModelAssignment] {
        tasks.filter { !SettingsCatalog.strippedAuxiliaryTasks.contains($0.task) }.map { task in
            ConfigAPI.ModelAssignment(scope: .auxiliary, provider: "auto", model: "", task: task.task, reasoningEffort: .null)
        }
    }

    private func reload() async {
        do {
            let result = try await catalog.api.auxiliaryModels()
            tasks = result.tasks.filter { !SettingsCatalog.strippedAuxiliaryTasks.contains($0.task) }
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
        loading = false
        if !catalog.loaded { await catalog.load() }
    }

    /// Sends an assignment; a pricing or data-use warning is shown first and the assignment resent once confirmed,
    /// as the main model's row does.
    private func assign(_ assignment: ConfigAPI.ModelAssignment) async {
        busy = true
        failure = nil
        defer { busy = false }
        do {
            let result = try await catalog.api.assignModel(assignment)
            if let confirm = result.confirmMessage {
                pendingConfirm = (assignment, confirm)
                return
            }
            if !result.ok { failure = "Hermes didn't change the model." }
            await reload()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func resetAll() async {
        busy = true
        failure = nil
        defer { busy = false }
        do {
            for assignment in Self.resetAssignments(tasks) {
                _ = try await catalog.api.assignModel(assignment)
            }
        } catch {
            failure = error.localizedDescription
        }
        await reload()
    }
}

/// One side task's model and reasoning effort (the desktop row's Change editor), saved together.
private struct AuxiliaryTaskEditor: View {
    @EnvironmentObject private var catalog: ModelCatalog
    @Environment(\.dismiss) private var dismiss
    let task: ConfigAPI.AuxiliaryTask
    let title: String
    /// The base task's label, for a plugin task that inherits one.
    let baseLabel: String?
    let save: (ModelRoute?, String) -> Void
    @State private var route: ModelRoute?
    @State private var effort: String
    @State private var picking = false

    init(task: ConfigAPI.AuxiliaryTask, title: String, baseLabel: String?, save: @escaping (ModelRoute?, String) -> Void) {
        self.task = task
        self.title = title
        self.baseLabel = baseLabel
        self.save = save
        _route = State(initialValue: task.route)
        _effort = State(initialValue: task.reasoningEffort ?? AuxiliaryModelsSection.inheritEffort)
    }

    private var followLabel: String { baseLabel.map { "Follow \($0)" } ?? "Use main model" }
    private var initialEffort: String { task.reasoningEffort ?? AuxiliaryModelsSection.inheritEffort }
    private var changed: Bool { route != task.route || effort != initialEffort }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { picking = true } label: {
                        HStack {
                            Text("Model").foregroundStyle(Theme.Text.primary)
                            Spacer()
                            Text(route.map(catalog.describe) ?? (baseLabel.map { "Follows \($0)" } ?? "Main model"))
                                .foregroundStyle(Theme.Text.tertiary).lineLimit(1)
                            Image(systemName: "chevron.right").foregroundStyle(Theme.Text.quaternary)
                        }
                    }
                    Picker("Reasoning", selection: $effort) {
                        Text("Same as main model").tag(AuxiliaryModelsSection.inheritEffort)
                        let levels = ["none"] + SettingsCatalog.reasoningEfforts
                        ForEach(levels.contains(effort) || effort == AuxiliaryModelsSection.inheritEffort ? levels : levels + [effort],
                                id: \.self) { level in
                            Text(level == "none" ? "Off" : SettingsText.prettyName(level)).tag(level)
                        }
                    }
                    .pickerStyle(.menu)
                } footer: {
                    if let base = baseLabel, route == nil {
                        FormNote("Follows \(base) until you pick a model for it.")
                    } else {
                        FormNote(task.hint ?? AuxiliaryModelsSection.builtinCopy[task.task]?.hint ?? "")
                    }
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        dismiss()
                        save(route, effort)
                    }
                    .disabled(!changed)
                }
            }
            .modelRoutePicker(isPresented: $picking, catalog: catalog, title: title, current: route,
                              clearLabel: followLabel) { picked in
                route = picked
            }
        }
        .task { if !catalog.loaded { await catalog.load() } }
    }
}

// MARK: - Mixture of Agents

/// Settings > Model > Mixture of Agents: the named presets (enabled, default, added and deleted), each preset's
/// reference models and aggregator (`/api/model/moa`). The whole MoA record is sent back on save, so members this
/// page doesn't edit survive; the submitted preset map is what the server keeps.
struct MoaSection: View {
    @EnvironmentObject private var catalog: ModelCatalog
    @State private var moa: JSONValue?
    @State private var selected = ""
    @State private var saving = false
    @State private var failure: String?
    @State private var addingReference = false
    @State private var pickingAggregator = false
    @State private var namingPreset = false
    @State private var newPresetName = ""
    @State private var deletingPreset = false

    private var presetNames: [String] { (moa?["presets"]?.objectValue?.keys).map { Array($0).sorted() } ?? [] }
    private var defaultPreset: String { moa?["default_preset"]?.stringValue ?? "" }
    private var presetName: String { presetNames.contains(selected) ? selected : (presetNames.contains(defaultPreset) ? defaultPreset : presetNames.first ?? "") }
    private var preset: JSONValue? { moa?["presets"]?[presetName] }

    static func route(_ slot: JSONValue?) -> ModelRoute {
        ModelRoute(provider: slot?["provider"]?.stringValue ?? "", model: slot?["model"]?.stringValue ?? "")
    }

    /// The record without preset `name`: the default moves to the first preset left and an active pick of it is
    /// cleared (the desktop's Delete preset). Nil when it is the only preset.
    static func deleting(_ name: String, from moa: JSONValue) -> JSONValue? {
        guard var presets = moa["presets"]?.objectValue, presets.count > 1, presets[name] != nil else { return nil }
        presets[name] = nil
        var next = moa.setting("presets", .object(presets))
        if moa["default_preset"]?.stringValue == name, let fallback = presets.keys.sorted().first {
            next = next.setting("default_preset", .string(fallback))
        }
        if moa["active_preset"]?.stringValue == name { next = next.setting("active_preset", "") }
        return next
    }

    /// The record with a new preset `name`, a copy of `source` (the desktop's Add preset). Nil for an empty or
    /// taken name.
    static func adding(_ name: String, copyOf source: String, to moa: JSONValue) -> JSONValue? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, var presets = moa["presets"]?.objectValue, presets[name] == nil,
              let copy = presets[source] else { return nil }
        presets[name] = copy
        return moa.setting("presets", .object(presets))
    }

    var body: some View {
        if moa == nil {
            // One row: its task loads the record once (a Section's modifiers run on every row).
            Section {
                Group {
                    if let failure { FormNote(failure, color: Theme.destructive) } else { ProgressView().frame(maxWidth: .infinity) }
                }
                .task { await reload() }
            }
            .hermesFormRows()
            .id("model.moa")
        } else {
            presetSection.id("model.moa")
            referenceSection
            aggregatorSection
        }
    }

    private var presetSection: some View {
        Section {
            if presetNames.count > 1 {
                Picker("Preset", selection: Binding(get: { presetName }, set: { selected = $0 })) {
                    ForEach(presetNames, id: \.self) { Text($0).tag($0) }
                }
            } else {
                LabeledContent("Preset") { Text(presetName).foregroundStyle(Theme.Text.tertiary) }
            }
            Toggle("Enabled", isOn: Binding(get: { preset?["enabled"]?.boolValue ?? true }, set: { on in
                updatePreset { $0.setting("enabled", .bool(on)) }
            }))
            .disabled(saving)
            if presetName != defaultPreset {
                Button("Make default") { update { $0 = $0.setting("default_preset", .string(presetName)) } }
                    .disabled(saving)
            }
            Button { newPresetName = ""; namingPreset = true } label: {
                Label("Add preset", systemImage: "plus")
            }
            .disabled(saving)
            .alert("Add preset", isPresented: $namingPreset) {
                TextField("new preset", text: $newPresetName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Cancel", role: .cancel) {}
                Button("Add") {
                    let name = newPresetName.trimmingCharacters(in: .whitespacesAndNewlines), source = presetName
                    update { moa in if let next = Self.adding(name, copyOf: source, to: moa) { moa = next } }
                    if presetNames.contains(name) { selected = name }
                }
                .disabled(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || presetNames.contains(newPresetName.trimmingCharacters(in: .whitespacesAndNewlines)))
            } message: {
                Text("A copy of “\(presetName)” under a new name.")
            }
            if presetNames.count > 1 {
                Button("Delete preset", role: .destructive) { deletingPreset = true }
                    .disabled(saving)
                    .confirmationDialog("Delete preset “\(presetName)”?", isPresented: $deletingPreset, titleVisibility: .visible) {
                        Button("Delete", role: .destructive) {
                            let name = presetName
                            update { moa in if let next = Self.deleting(name, from: moa) { moa = next } }
                            selected = presetNames.first { $0 != name } ?? ""
                        }
                    }
            }
        } header: {
            FormNote("Presets")
        } footer: {
            FormNote("Each enabled preset shows as a model of the Mixture of Agents provider. Default preset: \(defaultPreset)")
        }
        .hermesFormRows()
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
                // A preset keeps at least one reference model (the server refuses an empty one).
                .swipeActions {
                    if slots.count > 1 {
                        Button("Remove", role: .destructive) { updateSlots { $0.remove(at: index) } }
                    }
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
            else { FormNote(slots.count > 1 ? "Each reference model answers on its own; swipe to remove one."
                                             : "Each reference model answers on its own. A preset keeps at least one.") }
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
        guard next != previous else { return }
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
/// (`DelegationRouteRow`). Both keys are saved together, and a route picked here leaves a direct endpoint
/// (`delegation.base_url`, set on the desktop or the CLI), which Hermes would otherwise keep calling.
struct DelegationRouteRow: View {
    @EnvironmentObject private var store: SettingsStore
    @EnvironmentObject private var catalog: ModelCatalog
    @EnvironmentObject private var routing: DelegationRoutingModel
    var error: String?
    var saving = false
    @State private var picking = false

    /// The saved route (`SavedRoute` in `delegation-route-draft.ts`).
    struct Saved: Equatable {
        var provider: String
        var model: String
        var baseURL: String
    }

    /// A direct URL + key + wire protocol; leaving it clears all three (`DIRECT_ENDPOINT_KEYS`).
    static let directEndpointKeys = ["delegation.base_url", "delegation.api_key", "delegation.api_mode"]
    /// Native SDK routes ignore a direct URL (`tools/delegate_tool_config.py`).
    static let nativeSDKProviders: Set<String> = ["bedrock", "vertex", "google", "google-genai"]

    /// Hermes calls `delegation.base_url` directly (`directEndpointActive`).
    static func directEndpointActive(_ saved: Saved) -> Bool {
        !saved.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            && !nativeSDKProviders.contains(saved.provider.trimmingCharacters(in: .whitespaces).lowercased())
    }

    /// The editor mode of a saved route (`savedMode`): a direct endpoint, a provider, a model alone, or inherit.
    static func mode(_ saved: Saved) -> String {
        if directEndpointActive(saved) { return "direct" }
        if !saved.provider.isEmpty { return "provider:\(saved.provider)" }
        return saved.model.isEmpty ? "inherit" : "model-only"
    }

    /// What picking `picked` (nil: same as the main model) saves (`draftOutcome` + `applyDelegationRoute`): the
    /// provider and model, and the direct endpoint's keys cleared when it was active or the mode changes.
    static func entries(saved: Saved, picked: ModelRoute?) -> [SettingsStore.Entry] {
        var entries = [SettingsStore.Entry(key: "delegation.provider", value: .string(picked?.provider ?? "")),
                       SettingsStore.Entry(key: "delegation.model", value: .string(picked?.model ?? ""))]
        let next = picked.map { "provider:\($0.provider)" } ?? "inherit"
        if directEndpointActive(saved) || next != mode(saved) {
            entries += directEndpointKeys.map { SettingsStore.Entry(key: $0, value: .string("")) }
        }
        return entries
    }

    private var saved: Saved {
        Saved(provider: store.value("delegation.provider")?.displayText ?? "",
              model: store.value("delegation.model")?.displayText ?? "",
              baseURL: store.value("delegation.base_url")?.displayText ?? "")
    }

    var body: some View {
        let saved = saved
        let route = ModelRoute(provider: saved.provider, model: saved.model)
        let direct = Self.directEndpointActive(saved)
        let inherits = !direct && route.model.isEmpty
        // A routing mode other than Default picks each subagent's model itself (`SubagentModelGate`).
        let gated = routing.routing.flatMap { $0.ownsSubagentModel ? $0 : nil }
        Group {
            SettingsRow(title: SettingsCatalog.label(for: "delegation.model"),
                        description: gated.map { "Not used in this mode. \($0.inactiveReason)" }
                            ?? (direct ? "Subagents call a direct endpoint (\(Self.host(saved.baseURL))). Picking a model here stops that."
                                       : "The model subagents run on. Same as the main model unless you pick one."),
                        error: error ?? store.errors["delegation.provider"], saving: saving) {
                Button { picking = true } label: {
                    Text(direct ? (saved.model.isEmpty ? "Direct endpoint" : "\(saved.model) · Direct endpoint")
                                : inherits ? "Main model" : catalog.describe(route))
                        .foregroundStyle(gated == nil ? Theme.Text.tertiary : Theme.Text.quaternary)
                        .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .fixedSize()
                .disabled(gated != nil)
            }
            // On the row itself: a Group hands its modifiers to each of its rows.
            .modelRoutePicker(isPresented: $picking, catalog: catalog, title: "Subagent Model",
                              current: inherits || direct ? nil : route, clearLabel: "Same as main model") { picked in
                store.set(Self.entries(saved: saved, picked: picked))
            }
            .task { if !catalog.loaded { await catalog.load() } }
            if gated != nil {
                Button("Switch to Default") { Task { await routing.choose("default") } }
                    .disabled(routing.busy)
            }
        }
    }

    /// The endpoint's host, for the row's note (never its key).
    static func host(_ url: String) -> String {
        URL(string: url.trimmingCharacters(in: .whitespaces))?.host ?? url
    }
}
