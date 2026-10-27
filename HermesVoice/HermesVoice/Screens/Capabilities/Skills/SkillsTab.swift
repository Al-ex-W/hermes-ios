import SwiftUI

/// Capabilities ▸ Skills (`skills/skills-tab.tsx`, `catalog/skill-catalog.tsx`): the profile's skills by category
/// with their switches, the built-in catalog to install from, and a search of the skill hub. Filters narrow by
/// source and category; bulk switches always mean the whole profile.
struct SkillsTab: View {
    let context: CapabilitiesContext
    @Binding var query: String
    @StateObject private var store: SkillsStore
    @State private var source: SkillProvenance?
    @State private var category: String?
    @State private var opened: String?
    @State private var previewing: HubSkill?
    @State private var creating = false
    @State private var confirmation: CapabilityConfirmation?

    init(context: CapabilitiesContext, query: Binding<String>) {
        self.context = context
        _query = query
        _store = StateObject(wrappedValue: SkillsStore(api: context.skills, actions: context.actions))
    }

    private var searching: Bool { !CapabilitySearch.normalize(query).isEmpty }

    var body: some View {
        List {
            if let skills = store.skills {
                content(skills)
            } else if let error = store.loadError {
                CapabilityLoadFailure(title: "Skills failed to load", message: error) { Task { await store.load() } }
            } else {
                CapabilityLoader()
            }
        }
        .capabilityList()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        .onSubmit(of: .search) { Task { await store.searchHub(query) } }
        .refreshable { await store.load() }
        .task { await store.loadOnce() }
        .toolbar { toolbar }
        .navigationDestination(item: $opened) { name in
            SkillDetailScreen(store: store, name: name)
        }
        .sheet(item: $previewing) { skill in
            NavigationStack { HubSkillSheet(store: store, skill: skill) }
        }
        .sheet(isPresented: $creating) {
            NavigationStack { SkillCreateSheet(store: store, categories: store.categories) }
        }
        .capabilityConfirmation($confirmation)
        .failureAlert($store.failure)
        .capabilityNotice($store.notice)
    }

    /// "Search skills…", with a nudge from the user's busiest category (`skillSearchTerms`).
    private var prompt: String {
        guard let hint = CapabilitySearch.skillHints(store.skills ?? []).first else { return "Search skills…" }
        return "Search skills… Try “\(hint)”"
    }

    // MARK: Lists

    @ViewBuilder private func content(_ skills: [CapabilitySkill]) -> some View {
        let installed = CapabilitySearch.skills(skills.filter(matchesFilters), query: query)
        let available = source == nil ? CapabilitySearch.official(store.available.filter { category == nil || $0.category == category }, query: query) : []
        if installed.isEmpty && available.isEmpty && !searching {
            CapabilityEmpty(noun: "skills", query: query)
        } else if installed.isEmpty && available.isEmpty {
            Section {
                ContentUnavailableView.search(text: query).listRowBackground(Color.clear)
            }
        }
        let groups = Dictionary(grouping: installed, by: \.category)
            .sorted { $0.key.localizedCompare($1.key) == .orderedAscending }
        ForEach(Array(groups.enumerated()), id: \.element.key) { index, group in
            Section {
                ForEach(group.value) { skill in row(skill) }
            } header: {
                FormNote("\(CapabilitySearch.label(group.key)) · \(group.value.count)")
            } footer: {
                if index == groups.count - 1 { FormNote("Changes apply to new sessions.") }
            }
            .hermesFormRows()
        }
        if !available.isEmpty {
            Section {
                ForEach(available) { skill in availableRow(skill) }
            } header: {
                FormNote("Available to install")
            } footer: {
                if let error = store.officialError { FormNote("The catalog failed to load. \(error)", color: Theme.destructive) }
            }
            .hermesFormRows()
        }
        if searching { hubSection }
    }

    private func matchesFilters(_ skill: CapabilitySkill) -> Bool {
        (source == nil || skill.provenance == source) && (category == nil || skill.category == category)
    }

    private func row(_ skill: CapabilitySkill) -> some View {
        CapabilityRow(label: CapabilityRowLabel(title: skill.name, subtitle: skill.description,
                                                tags: [CapabilityTag(text: skill.provenance.label)],
                                                meta: skill.usage > 0 ? "used \(skill.usage)×" : nil),
                      open: { opened = skill.name }) {
            Toggle(skill.name, isOn: Binding(get: { skill.enabled },
                                             set: { on in Task { await store.setEnabled([skill], on) } }))
                .labelsHidden()
                .disabled(store.busy)
        }
        .swipeActions(edge: .trailing) {
            Button(skill.enabled ? "Disable" : "Enable") { Task { await store.setEnabled([skill], !skill.enabled) } }
                .tint(skill.enabled ? Theme.Text.tertiary : Theme.primary)
        }
        .contextMenu {
            Button { opened = skill.name } label: { Label("Open", systemImage: "doc.text") }
            Button { Task { await store.setEnabled([skill], !skill.enabled) } } label: {
                Label(skill.enabled ? "Disable" : "Enable", systemImage: skill.enabled ? "pause.circle" : "play.circle")
            }
            if skill.provenance.editable {
                Button(role: .destructive) { confirmArchive(skill.name) } label: { Label("Archive", systemImage: Theme.Icon.archive) }
            }
        }
    }

    private func availableRow(_ skill: OfficialSkill) -> some View {
        CapabilityRow(label: CapabilityRowLabel(title: skill.name, subtitle: skill.description,
                                                tags: [CapabilityTag(text: "Official", tone: .accent)],
                                                meta: skill.categoryLabel),
                      open: { previewing = HubSkill(official: skill) }) {
            HubInstallButton(store: store, identifier: skill.identifier, name: skill.name)
        }
    }

    // MARK: Skill hub

    @ViewBuilder private var hubSection: some View {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        Section {
            if store.hubSearching {
                CapabilityLoader()
            } else if store.hubQuery != trimmed {
                Button {
                    Task { await store.searchHub(trimmed) }
                } label: {
                    Label("Search the skill hub for “\(trimmed)”", systemImage: Theme.Icon.search)
                }
            } else if let error = store.hubError {
                FormNote(error, color: Theme.destructive)
            } else if let results = store.hubResults, !results.results.isEmpty {
                ForEach(results.results) { skill in
                    CapabilityRow(label: CapabilityRowLabel(title: skill.name, subtitle: skill.description,
                                                            tags: hubTags(skill), meta: skill.source),
                                  open: { previewing = skill }) {
                        HubInstallButton(store: store, identifier: skill.identifier, name: skill.name)
                    }
                }
            } else {
                FormNote("No matching skills found in the hub.")
            }
        } header: {
            FormNote("Skill hub")
        } footer: {
            if let timedOut = store.hubResults?.timedOut, !timedOut.isEmpty, store.hubQuery == trimmed {
                FormNote("Timed out: \(timedOut.joined(separator: ", "))")
            } else {
                FormNote("Searches the official index, GitHub and community sources on the Hermes host.")
            }
        }
        .hermesFormRows()
    }

    private func hubTags(_ skill: HubSkill) -> [CapabilityTag] {
        switch skill.trustLevel {
        case "builtin": return [CapabilityTag(text: "builtin", tone: .accent)]
        case "trusted": return [CapabilityTag(text: "trusted", tone: .good)]
        default: return [CapabilityTag(text: "community")]
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Menu {
                Picker("Source", selection: $source) {
                    Text("All sources").tag(SkillProvenance?.none)
                    ForEach(SkillProvenance.allCases, id: \.self) { provenance in
                        Text(provenance.label).tag(Optional(provenance))
                    }
                }
                Picker("Category", selection: $category) {
                    Text("All categories").tag(String?.none)
                    ForEach(store.categories, id: \.self) { category in
                        Text(CapabilitySearch.label(category)).tag(Optional(category))
                    }
                }
            } label: {
                Image(systemName: source == nil && category == nil ? Theme.Icon.filter : "line.3.horizontal.decrease.circle.fill")
            }
            .accessibilityLabel("Filters")
            Menu {
                Button { creating = true } label: { Label("New skill", systemImage: "plus") }
                Button {
                    confirmation = CapabilityConfirmation(
                        title: "Update installed skills?",
                        message: "Hermes updates every skill installed from the hub to its source's latest version. Changes apply to new sessions.",
                        action: "Update", destructive: false) { await store.updateAll() }
                } label: {
                    Label("Update installed", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(store.hubActions[SkillsStore.updateAllKey]?.running == true)
                Divider()
                let skills = store.skills ?? []
                Button { Task { await store.setAll(true) } } label: { Label("Turn all on", systemImage: "checkmark.circle") }
                    .disabled(store.busy || skills.isEmpty || skills.allSatisfy(\.enabled))
                Button { Task { await store.setAll(false) } } label: { Label("Turn all off", systemImage: "circle") }
                    .disabled(store.busy || skills.isEmpty || !skills.contains(where: \.enabled))
                Button { Task { await store.disableUnused() } } label: { Label("Disable unused", systemImage: "moon.zzz") }
                    .disabled(store.busy || store.unused.isEmpty)
            } label: {
                if store.hubActions[SkillsStore.updateAllKey]?.running == true || store.busy {
                    ProgressView()
                } else {
                    Image(systemName: Theme.Icon.more)
                }
            }
            .accessibilityLabel("Skill actions")
        }
    }

    private func confirmArchive(_ name: String) {
        confirmation = CapabilityConfirmation(title: "Archive \(name)?",
                                              message: "The skill is archived and can be restored with `hermes curator restore`.",
                                              action: "Archive") { _ = await store.archive(name) }
    }
}

/// The catalog row's add button (`CatalogAddButton`): Add, a spinner while the install runs, then Installed.
struct HubInstallButton: View {
    @ObservedObject var store: SkillsStore
    let identifier: String
    let name: String

    var body: some View {
        if store.hubActions[identifier]?.running == true {
            ProgressView()
        } else if store.isInstalled(identifier: identifier, name: name) {
            StatusTag("Installed", tone: .good, systemImage: "checkmark")
        } else {
            Button("Add") { Task { await store.install(identifier: identifier, name: name) } }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(store.skills == nil)
                .accessibilityLabel("Add \(name)")
        }
    }
}
