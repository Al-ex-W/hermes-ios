import SwiftUI

/// The desktop's cron editor dialog (`CronEditorDialog`): a new job from scratch or from a blueprint, or an edit of
/// an existing one. Delivery targets come from the host (`/api/cron/delivery-targets`), models from the same catalog
/// the chat picker uses.
struct CronEditorSheet: View {
    @ObservedObject var store: CronStore
    let mode: CronEditorMode

    @Environment(\.dismiss) private var dismiss
    @State private var values: CronEditorValues
    @State private var preset: CronSchedule
    /// `custom`, or a blueprint key.
    @State private var template: String
    @State private var slots: [String: String] = [:]
    @State private var targets: [CronDeliveryTarget] = []
    @State private var providers: [ModelOptionProvider] = []
    @State private var saving = false
    @State private var error: String?

    private static let customTemplate = "custom"

    init(store: CronStore, mode: CronEditorMode) {
        self.store = store
        self.mode = mode
        switch mode {
        case let .edit(job):
            _values = State(initialValue: CronEditorValues(job: job))
            _preset = State(initialValue: CronSchedule.preset(for: job.editableSchedule))
            _template = State(initialValue: Self.customTemplate)
        case let .create(key):
            _values = State(initialValue: CronEditorValues())
            _preset = State(initialValue: .daily)
            _template = State(initialValue: key ?? Self.customTemplate)
            _slots = State(initialValue: store.blueprints.first { $0.key == key }?.initialValues ?? [:])
        }
    }

    private var editing: CronJob? {
        if case let .edit(job) = mode { return job }
        return nil
    }

    private var scriptOnly: Bool { editing?.isScriptOnly ?? false }

    private var blueprint: CronBlueprint? {
        template == Self.customTemplate ? nil : store.blueprints.first { $0.key == template }
    }

    /// The profile the job lives in, for its delivery targets and models.
    private var profile: String? {
        if let editing { return editing.profile }
        return blueprint == nil ? store.createProfile : store.blueprintProfile
    }

    var body: some View {
        NavigationStack {
            Form {
                if editing == nil, !store.blueprints.isEmpty {
                    Section {
                        Picker("Start from", selection: $template) {
                            Text("Custom").tag(Self.customTemplate)
                            ForEach(store.blueprints) { item in
                                Text(item.plugin.map { "\(item.title) · \($0)" } ?? item.title).tag(item.key)
                            }
                        }
                    } footer: {
                        if let blueprint, !blueprint.description.isEmpty { FormNote(blueprint.description) }
                    }
                    .hermesFormRows()
                }
                if let blueprint {
                    blueprintForm(blueprint)
                } else {
                    customForm
                }
                if let error {
                    Section {
                        Label(error, systemImage: Theme.Icon.warning)
                            .hermesText(.caption)
                            .foregroundStyle(Theme.destructive)
                    }
                    .listRowBackground(Theme.destructive.opacity(0.08))
                }
            }
            .hermesForm()
            .navigationTitle(editing == nil ? "New cron job" : "Edit cron job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(confirmLabel) { Task { await save() } }
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .onChange(of: template) { _, _ in
                slots = blueprint?.initialValues ?? [:]
                error = nil
            }
            .task(id: profile ?? "") { await loadChoices() }
        }
    }

    private var confirmLabel: String {
        if blueprint != nil { return "Schedule it" }
        return editing == nil ? "Create cron" : "Save changes"
    }

    // MARK: Custom job

    @ViewBuilder private var customForm: some View {
        Section {
            if let editing, scriptOnly {
                FormNote("Script-only job (no AI prompt). Job id: \(editing.id)")
            }
            TextField("Name", text: $values.name, prompt: Text("Morning briefing"))
        } header: {
            FormNote(editing == nil
                ? "Schedule a prompt to run automatically. Use cron syntax or a natural phrase like \"every 15 minutes\"."
                : "Update the schedule, prompt, or delivery target. Changes apply on next run.")
        } footer: {
            FormNote("Name is optional.")
        }
        .hermesFormRows()

        Section {
            ZStack(alignment: .topLeading) {
                if values.prompt.isEmpty {
                    Text("Summarize my unread Slack threads and email me the top 5...")
                        .foregroundStyle(Theme.Text.quaternary)
                        .padding(.top, 8)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $values.prompt)
                    .font(Theme.TextStyle.code.font)
                    .frame(minHeight: 110)
                    .scrollContentBackground(.hidden)
            }
        } header: {
            FormNote(scriptOnly ? "Prompt (optional)" : "Prompt")
        }
        .hermesFormRows()

        Section {
            Picker("Frequency", selection: $preset) {
                ForEach(CronSchedule.allCases) { option in Text(option.label).tag(option) }
            }
            .onChange(of: preset) { _, next in
                values.schedule = next.applied(to: values.schedule)
                error = nil
            }
            if preset == .custom {
                TextField("Custom schedule", text: $values.schedule, prompt: Text("0 9 * * * or weekdays at 9am"))
                    .font(Theme.TextStyle.code.font)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } else {
                HStack {
                    Text(preset.summary(values.schedule)).foregroundStyle(Theme.Text.primary)
                    Spacer()
                    Text(values.schedule).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary)
                }
                .hermesText(.caption)
            }
        } footer: {
            if preset == .custom {
                FormNote("Cron expression, or phrases like \"every hour\" or \"weekdays at 9am\".")
            }
        }
        .hermesFormRows()

        deliverSection(value: $values.deliver)

        if !scriptOnly {
            Section {
                NavigationLink {
                    CronModelPicker(providers: usableProviders, provider: values.provider, model: values.model) { provider, model in
                        values.provider = provider
                        values.model = model
                    }
                } label: {
                    LabeledContent("Model", value: values.model.isEmpty ? "Default (global model)" : values.model)
                }
            } footer: {
                FormNote("Optional. A pinned model runs this job whatever the global default is.")
            }
            .hermesFormRows()
        }
    }

    /// Configured providers with at least one model, as the chat picker offers them.
    private var usableProviders: [ModelOptionProvider] {
        providers.filter { $0.authenticated != false && !($0.models ?? []).isEmpty }
    }

    // MARK: Blueprint

    @ViewBuilder private func blueprintForm(_ blueprint: CronBlueprint) -> some View {
        ForEach(blueprint.fields.filter { !$0.isDeliver }) { field in
            Section {
                slotControl(field)
            } header: {
                FormNote(field.label)
            } footer: {
                if let help = field.slotHelp { FormNote(help) }
            }
            .hermesFormRows()
        }
        if blueprint.fields.contains(where: \.isDeliver) {
            deliverSection(value: Binding(get: { slots[CronBlueprint.deliverField] ?? CronDelivery.local },
                                          set: { slots[CronBlueprint.deliverField] = $0 }))
        }
    }

    @ViewBuilder private func slotControl(_ field: CronBlueprint.Field) -> some View {
        let binding = Binding(get: { slots[field.name] ?? "" }, set: { slots[field.name] = $0 })
        switch field.kind {
        case .enum, .weekdays:
            Picker(field.label, selection: binding) {
                if !field.options.contains(binding.wrappedValue) {
                    Text(binding.wrappedValue.isEmpty ? "Choose…" : binding.wrappedValue).tag(binding.wrappedValue)
                }
                ForEach(field.options, id: \.self) { option in Text(option).tag(option) }
            }
        case .time:
            DatePicker(field.label, selection: Binding(get: { Self.date(hhmm: binding.wrappedValue) },
                                                       set: { binding.wrappedValue = Self.hhmm($0) }),
                       displayedComponents: .hourAndMinute)
        case .text:
            TextField(field.label, text: binding, prompt: Text(field.help.isEmpty ? field.label : field.help), axis: .vertical)
                .lineLimit(1...6)
        }
    }

    /// A blueprint time slot ("07:30", 24 h) as a date today; 9:00 when empty.
    static func date(hhmm: String) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let hour = parts.count == 2 && (0..<24).contains(parts[0]) ? parts[0] : 9
        let minute = parts.count == 2 && (0..<60).contains(parts[1]) ? parts[1] : 0
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }

    static func hhmm(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", components.hour ?? 9, components.minute ?? 0)
    }

    // MARK: Delivery

    private func deliverSection(value: Binding<String>) -> some View {
        Section {
            ForEach(CronDelivery.options(targets.isEmpty ? [CronDeliveryTarget(id: CronDelivery.local, name: "Local (save only)")] : targets,
                                         selected: value.wrappedValue)) { target in
                let selected = CronDelivery.parse(value.wrappedValue).contains(target.id)
                Button {
                    value.wrappedValue = CronDelivery.toggle(value.wrappedValue, target.id, on: !selected)
                } label: {
                    HStack {
                        Text(target.label).foregroundStyle(Theme.Text.primary)
                        Spacer()
                        Image(systemName: selected ? "checkmark.square.fill" : "square")
                            .foregroundStyle(selected ? Theme.primary : Theme.Text.quaternary)
                    }
                }
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        } header: {
            FormNote("Deliver to")
        } footer: {
            FormNote("Results can stay on the host and also go to a connected platform.")
        }
        .hermesFormRows()
    }

    // MARK: Loading and saving

    private func loadChoices() async {
        async let targetRows = try? store.client.cronDeliveryTargets(profile: profile)
        async let modelRows = try? ConfigAPI(client: store.client, profile: profile).modelOptions()
        if let rows = await targetRows { targets = rows }
        if let options = await modelRows { providers = options.result.providers }
    }

    private func save() async {
        error = nil
        if let blueprint {
            saving = true
            defer { saving = false }
            do {
                try await store.instantiate(blueprint, values: slots)
                dismiss()
            } catch {
                if !error.isCancellation { self.error = CronBlueprint.cleanFieldError(error.dashboardMessage) }
            }
            return
        }
        if let invalid = values.validate(scriptOnly: scriptOnly) {
            error = invalid.message
            return
        }
        saving = true
        defer { saving = false }
        do {
            try await store.save(values, editing: editing)
            dismiss()
        } catch {
            if !error.isCancellation { self.error = error.dashboardMessage }
        }
    }
}

/// The editor's model choice: the global default, a model the job pinned that the catalog no longer offers, or a
/// provider's model.
private struct CronModelPicker: View {
    let providers: [ModelOptionProvider]
    let provider: String
    let model: String
    let choose: (_ provider: String, _ model: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var known: Bool {
        model.isEmpty || providers.contains { $0.slug == provider && ($0.models ?? []).contains(model) }
    }

    private func models(_ row: ModelOptionProvider) -> [String] {
        let models = row.models ?? []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty, !row.name.lowercased().contains(needle) else { return models }
        return models.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    row("Default (global model)", provider: "", model: "", monospaced: false)
                    if !known { row(model, provider: provider, model: model) }
                }
                .hermesFormRows()
            }
            ForEach(providers, id: \.slug) { row in
                let models = models(row)
                if !models.isEmpty {
                    Section {
                        ForEach(models, id: \.self) { model in self.row(model, provider: row.slug, model: model) }
                    } header: {
                        FormNote(row.name)
                    }
                    .hermesFormRows()
                }
            }
            if providers.isEmpty {
                Text("No configured provider offers models.").foregroundStyle(Theme.Text.tertiary).hermesFormRows()
            }
        }
        .hermesForm()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, provider: String, model: String, monospaced: Bool = true) -> some View {
        Button {
            choose(provider, model)
            dismiss()
        } label: {
            HStack {
                Text(title)
                    .font(monospaced ? Theme.TextStyle.code.font : nil)
                    .foregroundStyle(Theme.Text.primary)
                Spacer()
                if self.provider == provider, self.model == model {
                    Image(systemName: "checkmark").foregroundStyle(Theme.primary)
                }
            }
        }
    }
}
