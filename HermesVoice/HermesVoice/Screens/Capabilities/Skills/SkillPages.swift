import SwiftUI

/// One installed skill (`skills/skill-detail.tsx`): its switch, frontmatter and full SKILL.md, with Edit and
/// Archive for the user's own skills and Uninstall for hub installs.
struct SkillDetailScreen: View {
    @ObservedObject var store: SkillsStore
    let name: String
    @State private var document: SkillDocument?
    @State private var loadError: String?
    @State private var editing = false
    @State private var confirmation: CapabilityConfirmation?
    @Environment(\.dismiss) private var dismiss

    private var skill: CapabilitySkill? { store.skill(named: name) }

    var body: some View {
        List {
            if let skill {
                Section {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.sm) {
                            StatusTag(skill.provenance.label)
                            StatusTag(skill.categoryLabel)
                            if skill.usage > 0 { StatusTag("used \(skill.usage)×") }
                        }
                        Text(skill.description.isEmpty ? "No description." : skill.description)
                            .hermesText(.body)
                            .foregroundStyle(Theme.Text.secondary)
                    }
                    .padding(.vertical, Theme.Spacing.xs)
                    Toggle("Enabled", isOn: Binding(get: { skill.enabled },
                                                    set: { on in Task { await store.setEnabled([skill], on) } }))
                        .disabled(store.busy)
                } footer: {
                    FormNote("Changes apply to new sessions.")
                }
                .hermesFormRows()
            }
            if let document {
                let parsed = SkillFrontmatter(document.content)
                if !parsed.meta.isEmpty {
                    Section {
                        ForEach(parsed.meta, id: \.key) { field in
                            LabeledContent(field.key) {
                                Text(field.value)
                                    .hermesText(.caption)
                                    .foregroundStyle(Theme.Text.secondary)
                                    .multilineTextAlignment(.trailing)
                                    .textSelection(.enabled)
                            }
                        }
                    } header: {
                        FormNote("Details")
                    }
                    .hermesFormRows()
                }
                Section {
                    let markdown = parsed.body.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(markdown.isEmpty ? "No description." : markdown)
                        .font(Theme.TextStyle.code.font)
                        .foregroundStyle(Theme.Text.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    FormNote("SKILL.md")
                }
                .hermesFormRows()
            } else if let loadError {
                CapabilityLoadFailure(title: "Couldn't load SKILL.md", message: loadError) { Task { await load() } }
            } else {
                CapabilityLoader()
            }
        }
        .capabilityList()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar { toolbar }
        .refreshable { await load() }
        .task { await load() }
        .navigationDestination(isPresented: $editing) {
            if let document {
                SkillEditorScreen(store: store, name: name, content: document.content) { saved in
                    self.document = SkillDocument(name: name, content: saved)
                }
            }
        }
        // Failures of the store's writes show in the Skills tab's alert, below this page.
        .capabilityConfirmation($confirmation)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let skill {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if skill.provenance.editable {
                    Button("Edit") { editing = true }
                        .disabled(document == nil)
                }
                if skill.provenance.editable || skill.provenance == .hub {
                    Menu {
                        if skill.provenance.editable {
                            Button(role: .destructive) { confirmArchive() } label: { Label("Archive", systemImage: Theme.Icon.archive) }
                        }
                        if skill.provenance == .hub {
                            Button(role: .destructive) { confirmUninstall() } label: { Label("Uninstall", systemImage: Theme.Icon.delete) }
                        }
                    } label: {
                        if store.hubActions[name]?.running == true { ProgressView() } else { Image(systemName: Theme.Icon.more) }
                    }
                    .accessibilityLabel("Skill actions")
                }
            }
        }
    }

    private func load() async {
        do {
            document = try await store.content(name)
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = error.dashboardMessage
        }
    }

    private func confirmArchive() {
        confirmation = CapabilityConfirmation(title: "Archive \(name)?",
                                              message: "The skill is archived and can be restored with `hermes curator restore`.",
                                              action: "Archive") {
            if await store.archive(name) { dismiss() }
        }
    }

    private func confirmUninstall() {
        confirmation = CapabilityConfirmation(title: "Uninstall \(name)?",
                                              message: "Hermes removes the skill from this profile. You can install it from the hub again at any time.",
                                              action: "Uninstall") {
            if await store.uninstall(name) { dismiss() }
        }
    }
}

// MARK: - Editor

/// A skill's SKILL.md editor (`skillEditor` + `CodeEditor`): monospaced plain text, saved whole through
/// `PUT /api/skills/content`, with a guard against leaving unsaved edits behind.
struct SkillEditorScreen: View {
    @ObservedObject var store: SkillsStore
    let name: String
    let onSaved: (String) -> Void
    @State private var text: String
    @State private var original: String
    @State private var saving = false
    @State private var failure: String?
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(store: SkillsStore, name: String, content: String, onSaved: @escaping (String) -> Void) {
        self.store = store
        self.name = name
        self.onSaved = onSaved
        _text = State(initialValue: content)
        _original = State(initialValue: content)
    }

    private var dirty: Bool { text != original }

    var body: some View {
        SoulTextEditor(text: $text, placeholder: "---\nname: \(name)\ndescription: …\n---")
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            .disabled(saving)
            .navigationTitle("\(name)/SKILL.md")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .navigationBarBackButtonHidden(dirty)
            .interactiveDismissDisabled(dirty)
            .toolbar {
                if dirty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            confirmingDiscard = true
                        } label: {
                            HStack(spacing: Theme.Spacing.xs) {
                                Image(systemName: "chevron.left").fontWeight(.semibold)
                                Text("Back")
                            }
                        }
                        .accessibilityLabel("Back")
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 0) {
                            Text("\(name)/SKILL.md").font(.headline).lineLimit(1)
                            Text("Unsaved changes").hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save(thenClose: true) } }
                            .disabled(!dirty)
                    }
                }
            }
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Save") { Task { await save(thenClose: true) } }
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            } message: {
                Text("Your edits to \(name)'s SKILL.md haven't been saved.")
            }
            .failureAlert($failure)
    }

    /// Saves what is in the editor now; Hermes checks the frontmatter (name, description) and keeps the old file
    /// on a refusal.
    private func save(thenClose: Bool) async {
        guard !saving else { return }
        let content = text
        saving = true
        defer { saving = false }
        do {
            try await store.save(name, content: content)
            original = content
            onSaved(content)
            if thenClose { dismiss() }
        } catch {
            failure = "Couldn't save \(name). \(error.dashboardMessage)"
        }
    }
}

// MARK: - New skill

/// A new skill (`POST /api/skills`): name, optional category and its SKILL.md, written through the agent's own
/// skill path.
struct SkillCreateSheet: View {
    @ObservedObject var store: SkillsStore
    let categories: [String]
    @State private var name = ""
    @State private var category = ""
    @State private var content = SkillCreateSheet.template(name: "")
    @State private var edited = false
    @State private var creating = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    /// A SKILL.md Hermes accepts: frontmatter with `name` and `description`, then a body.
    static func template(name: String) -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return "---\nname: \(name)\ndescription: What this skill does and when to use it.\n---\n\n# \(name.isEmpty ? "Skill" : name)\n\nSteps for the agent to follow.\n"
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: name) { _, value in if !edited { content = Self.template(name: value) } }
                TextField("Category (optional)", text: $category)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !categories.isEmpty {
                    Picker("Existing category", selection: $category) {
                        Text("None").tag("")
                        ForEach(categories, id: \.self) { Text(CapabilitySearch.label($0)).tag($0) }
                    }
                }
            } footer: {
                FormNote("Lowercase letters, digits, dashes and underscores; start with a letter or digit.")
            }
            .hermesFormRows()
            Section {
                SoulTextEditor(text: Binding(get: { content }, set: { content = $0; edited = true }))
                    .frame(minHeight: 280)
            } header: {
                FormNote("SKILL.md")
            } footer: {
                FormNote("Starts with YAML frontmatter that names and describes the skill. It applies to new sessions.")
            }
            .hermesFormRows()
        }
        .hermesForm()
        .disabled(creating)
        .navigationTitle("New skill")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .interactiveDismissDisabled(edited || !trimmedName.isEmpty)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                if creating {
                    ProgressView()
                } else {
                    Button("Create") { Task { await create() } }
                        .disabled(trimmedName.isEmpty || content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .failureAlert($failure)
    }

    private func create() async {
        creating = true
        defer { creating = false }
        do {
            try await store.create(name: trimmedName, category: category, content: content)
            dismiss()
        } catch {
            failure = "Couldn't create \(trimmedName). \(error.dashboardMessage)"
        }
    }
}

// MARK: - Hub skill

/// A catalog or hub skill before it is installed (the catalog detail): its SKILL.md and files read from the hub
/// without installing, the install-time security scan on request, and Add.
struct HubSkillSheet: View {
    @ObservedObject var store: SkillsStore
    let skill: HubSkill
    @State private var preview: HubSkillPreview?
    @State private var previewError: String?
    @State private var scan: HubSkillScan?
    @State private var scanning = false
    @State private var scanError: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.sm) {
                        StatusTag(skill.trustLevel, tone: skill.trustLevel == "community" ? .muted : .accent)
                        if !skill.source.isEmpty { StatusTag(skill.source) }
                    }
                    Text(skill.description.isEmpty ? "No description." : skill.description)
                        .hermesText(.body)
                        .foregroundStyle(Theme.Text.secondary)
                    if !skill.tags.isEmpty {
                        Text(skill.tags.joined(separator: " · ")).hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                if let repo = skill.repo {
                    LabeledContent("Repository") { Text(repo).hermesText(.caption).textSelection(.enabled) }
                }
                LabeledContent("Identifier") { Text(skill.identifier).hermesText(.caption).textSelection(.enabled) }
            } footer: {
                FormNote("Review the source before installing. Changes apply to new sessions.")
            }
            .hermesFormRows()

            installSection
            scanSection

            if let preview {
                if !preview.files.isEmpty {
                    Section {
                        ForEach(preview.files, id: \.self) { file in
                            Text(file).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.secondary)
                        }
                    } header: {
                        FormNote("Files")
                    }
                    .hermesFormRows()
                }
                Section {
                    Text(preview.skillMarkdown.isEmpty ? "This skill has no SKILL.md preview." : preview.skillMarkdown)
                        .font(Theme.TextStyle.code.font)
                        .foregroundStyle(Theme.Text.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    FormNote("SKILL.md")
                }
                .hermesFormRows()
            } else if let previewError {
                Section {
                    FormNote("Skill preview failed. \(previewError)", color: Theme.destructive)
                }
                .hermesFormRows()
            } else {
                CapabilityLoader()
            }
        }
        .capabilityList()
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
        .task { await loadPreview() }
        .failureAlert($store.failure)
    }

    @ViewBuilder private var installSection: some View {
        let action = store.hubActions[skill.identifier]
        Section {
            if store.isInstalled(identifier: skill.identifier, name: skill.name), action?.running != true {
                Label("Installed", systemImage: "checkmark.circle").foregroundStyle(Theme.primary)
            } else {
                Button {
                    Task { await store.install(identifier: skill.identifier, name: skill.name) }
                } label: {
                    HStack {
                        Label(action?.running == true ? "Installing…" : "Install", systemImage: "plus.circle")
                        Spacer()
                        if action?.running == true { ProgressView() }
                    }
                }
                .disabled(action?.running == true || store.skills == nil || scan?.policy == .block)
            }
            if let action, action.kind == .install {
                CapabilityActionLog(lines: action.lines)
                    .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.lg, bottom: Theme.Spacing.md, trailing: Theme.Spacing.lg))
            }
        } footer: {
            if scan?.policy == .block { FormNote("Install blocked by policy.", color: Theme.destructive) }
        }
        .hermesFormRows()
    }

    @ViewBuilder private var scanSection: some View {
        Section {
            if let scan {
                LabeledContent("Verdict") {
                    StatusTag(scan.verdictLabel, tone: scan.verdict == "safe" ? .good : .warning)
                }
                LabeledContent("Policy") { Text(scan.policyLabel).hermesText(.caption) }
                if let reason = scan.policyReason { FormNote(reason) }
                if !scan.summary.isEmpty { FormNote(scan.summary) }
                if scan.findings.isEmpty {
                    FormNote("No security findings.")
                } else {
                    ForEach(Array(scan.findings.enumerated()), id: \.offset) { _, finding in
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            HStack(spacing: Theme.Spacing.sm) {
                                StatusTag(finding.severity, tone: ["critical", "high"].contains(finding.severity) ? .warning : .muted)
                                Text(finding.line.map { "\(finding.file):\($0)" } ?? finding.file)
                                    .font(Theme.TextStyle.code.font)
                                    .foregroundStyle(Theme.Text.tertiary)
                                    .lineLimit(1)
                            }
                            Text(finding.description).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                        }
                    }
                }
            } else {
                Button {
                    Task { await runScan() }
                } label: {
                    HStack {
                        Label(scanning ? "Scanning…" : "Scan", systemImage: "checkmark.shield")
                        Spacer()
                        if scanning { ProgressView() }
                    }
                }
                .disabled(scanning)
                if let scanError { FormNote("Security scan failed. \(scanError)", color: Theme.destructive) }
            }
        } header: {
            FormNote("Security scan")
        } footer: {
            if scan == nil { FormNote("Runs the install-time scan on the Hermes host without installing.") }
        }
        .hermesFormRows()
    }

    private func loadPreview() async {
        guard preview == nil else { return }
        do {
            preview = try await store.api.preview(skill.identifier)
        } catch {
            guard !error.isCancellation else { return }
            previewError = error.dashboardMessage
        }
    }

    private func runScan() async {
        scanning = true
        scanError = nil
        defer { scanning = false }
        do {
            scan = try await store.api.scan(skill.identifier)
        } catch {
            guard !error.isCancellation else { return }
            scanError = error.dashboardMessage
        }
    }
}
