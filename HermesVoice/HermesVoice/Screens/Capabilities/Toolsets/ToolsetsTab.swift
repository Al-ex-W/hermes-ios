import SwiftUI

/// The Tools tab's state for one profile (`toolsets-tab.tsx`, `tool-calls.ts`): the toolsets with their switches
/// and the per-tool call counts that rank them.
@MainActor
final class ToolsetsStore: ObservableObject {
    @Published private(set) var toolsets: [CapabilityToolset]?
    @Published private(set) var loadError: String?
    /// Tool name → calls over the last year; nil until the scan lands, empty when it isn't available.
    @Published private(set) var calls: [String: Int]?
    @Published private(set) var bulkBusy = false
    @Published var failure: String?
    @Published var notice: String?

    let api: ToolsetsAPI
    private var loaded = false

    init(api: ToolsetsAPI) {
        self.api = api
    }

    func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        await load()
    }

    func load() async {
        async let list: Void = reload()
        async let counts: Void = loadCalls()
        _ = await (list, counts)
    }

    func reload() async {
        do {
            toolsets = try await api.toolsets()
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if toolsets == nil { loadError = error.dashboardMessage } else { failure = "Toolsets failed to refresh. \(error.dashboardMessage)" }
        }
    }

    /// Cosmetic: a failed scan just leaves the counts out.
    private func loadCalls() async {
        calls = (try? await api.toolCalls()) ?? [:]
    }

    /// The toolsets the tab lists (curated and stripped), filtered by `query`, most called first.
    func visible(query: String) -> [CapabilityToolset] {
        ToolsetCuration.filter(toolsets ?? [], query: query, calls: calls ?? [:])
    }

    func toolset(named name: String) -> CapabilityToolset? {
        toolsets?.first { $0.name == name }
    }

    /// Shows the change at once, reverting it when the save fails. Turning a toolset on may start its backend's
    /// install on the host.
    func setEnabled(_ toolset: CapabilityToolset, _ enabled: Bool) async {
        patch(toolset.name) { $0.enabled = enabled }
        do {
            if let started = try await api.setEnabled(toolset.name, enabled) {
                notice = "\(toolset.label) is on. Hermes is installing what it needs (\(started)) on the host."
            }
        } catch {
            patch(toolset.name) { $0.enabled = !enabled }
            failure = "Failed to update \(toolset.label). \(error.dashboardMessage)"
        }
    }

    /// The tab's "All" switch: every listed toolset, never just what the search shows; one at a time, since each
    /// is a config read-modify-write on the host.
    func setAll(_ enabled: Bool) async {
        guard !bulkBusy else { return }
        let targets = (toolsets ?? []).filter { ToolsetCuration.isVisible($0.name) && $0.enabled != enabled }
        guard !targets.isEmpty else { return }
        bulkBusy = true
        defer { bulkBusy = false }
        var done = 0
        for target in targets {
            do {
                try await api.setEnabled(target.name, enabled)
                patch(target.name) { $0.enabled = enabled }
                done += 1
            } catch {
                failure = "Failed to update Tools. \(error.dashboardMessage)"
                break
            }
        }
        if done > 0 { notice = "Updated \(done) \(done == 1 ? "item" : "items") for new sessions." }
    }

    var allEnabled: Bool {
        let listed = (toolsets ?? []).filter { ToolsetCuration.isVisible($0.name) }
        return !listed.isEmpty && listed.allSatisfy(\.enabled)
    }

    private func patch(_ name: String, _ change: (inout CapabilityToolset) -> Void) {
        guard let index = toolsets?.firstIndex(where: { $0.name == name }) else { return }
        change(&toolsets![index])
    }
}

/// Capabilities ▸ Tools (`toolsets/toolsets-tab.tsx`): the feature row, then the toolsets grouped by what they
/// let the agent do, each with its switch; a toolset's page holds its backends and keys.
struct ToolsetsTab: View {
    let context: CapabilitiesContext
    @Binding var query: String
    @StateObject private var store: ToolsetsStore
    @State private var opened: String?

    init(context: CapabilitiesContext, query: Binding<String>) {
        self.context = context
        _query = query
        _store = StateObject(wrappedValue: ToolsetsStore(api: context.toolsets))
    }

    var body: some View {
        List {
            if store.toolsets != nil {
                let visible = store.visible(query: query)
                if visible.isEmpty {
                    CapabilityEmpty(noun: "tools", query: query)
                } else {
                    ForEach(ToolsetCuration.sections(visible, query: query, calls: store.calls)) { section in
                        Section {
                            ForEach(section.toolsets) { toolset in row(toolset) }
                        } header: {
                            FormNote(section.label)
                        } footer: {
                            FormNote(section.blurb)
                        }
                        .hermesFormRows()
                    }
                }
            } else if let error = store.loadError {
                CapabilityLoadFailure(title: "Toolsets failed to load", message: error) { Task { await store.load() } }
            } else {
                CapabilityLoader()
            }
        }
        .capabilityList()
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
        .refreshable { await store.load() }
        .task { await store.loadOnce() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { Task { await store.setAll(true) } } label: { Label("Turn all on", systemImage: "checkmark.circle") }
                        .disabled(store.bulkBusy || store.toolsets == nil || store.allEnabled)
                    Button { Task { await store.setAll(false) } } label: { Label("Turn all off", systemImage: "circle") }
                        .disabled(store.bulkBusy || store.toolsets == nil)
                } label: {
                    if store.bulkBusy { ProgressView() } else { Image(systemName: Theme.Icon.more) }
                }
                .accessibilityLabel("Tool actions")
            }
        }
        .navigationDestination(item: $opened) { name in
            ToolsetDetailScreen(store: store, context: context, name: name)
        }
        .failureAlert($store.failure)
        .capabilityNotice($store.notice)
    }

    /// "Search tools…", nudged with a tool name (`toolsetSearchTerms`): search reads tool names, not just titles.
    private var prompt: String {
        let hint = (store.toolsets ?? []).first { ToolsetCuration.isVisible($0.name) && !$0.tools.isEmpty }?.tools.first
        return hint.map { "Search tools… Try “\($0)”" } ?? "Search tools…"
    }

    private func row(_ toolset: CapabilityToolset) -> some View {
        let calls = store.calls.map(toolset.calls) ?? 0
        let tools = toolset.tools.count
        let meta = calls > 0 ? "\(calls.formatted(.number.notation(.compactName))) \(calls == 1 ? "call" : "calls")"
            : tools > 0 ? "\(tools) \(tools == 1 ? "tool" : "tools")" : nil
        return CapabilityRow(label: CapabilityRowLabel(title: toolset.label, subtitle: toolset.description,
                                                       tags: toolset.configured ? [] : [CapabilityTag(text: "Needs keys", tone: .warning)],
                                                       meta: meta),
                             open: { opened = toolset.name }) {
            Toggle("Turn \(toolset.label) toolset \(toolset.enabled ? "off" : "on")",
                   isOn: Binding(get: { toolset.enabled }, set: { on in Task { await store.setEnabled(toolset, on) } }))
                .labelsHidden()
                .disabled(store.bulkBusy)
        }
        .swipeActions(edge: .trailing) {
            Button(toolset.enabled ? "Turn off" : "Turn on") { Task { await store.setEnabled(toolset, !toolset.enabled) } }
                .tint(toolset.enabled ? Theme.Text.tertiary : Theme.primary)
        }
        .contextMenu {
            Button { opened = toolset.name } label: { Label("Configure \(toolset.label)", systemImage: Theme.Icon.settings) }
            Button { Task { await store.setEnabled(toolset, !toolset.enabled) } } label: {
                Label(toolset.enabled ? "Turn off" : "Turn on", systemImage: toolset.enabled ? "pause.circle" : "play.circle")
            }
        }
    }
}
