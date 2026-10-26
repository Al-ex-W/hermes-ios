import Foundation

/// The config record behind the schema-driven settings pages. Every edit is saved on its own, at once: the row
/// shows the new value immediately, a sparse `PUT /api/config` carries just that field, and a failed save puts
/// back the value the dashboard last confirmed (unless a newer edit of the field is already on its way) and says
/// why on the row. Saves run one after another, so an older save never lands after a newer one.
@MainActor
final class SettingsStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    /// An edit that needs a yes first (clearing every enabled toolset disables most tools).
    struct Confirmation: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
        let entries: [Entry]

        static func == (lhs: Confirmation, rhs: Confirmation) -> Bool { lhs.id == rhs.id }
    }

    struct Entry: Equatable {
        var key: String
        var value: JSONValue
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var schema = ConfigSchema()
    /// The record as the pages show it: what the dashboard sent, with every edit applied at once.
    @Published private(set) var config: JSONValue = .object([:])
    /// Fields with a save in flight.
    @Published private(set) var saving: Set<String> = []
    /// Why the last save of a field failed; cleared by the next edit of it.
    @Published private(set) var errors: [String: String] = [:]
    /// Fields saved this session whose schema says they apply after a restart.
    @Published private(set) var restartPending: Set<String> = []
    @Published var confirmation: Confirmation?

    let transport: ConfigTransport
    /// The record as the dashboard last confirmed it: what a failed save rolls back to.
    private var confirmed: JSONValue = .object([:])
    /// Bumped per field on every edit, so a failed older save doesn't roll back a newer value.
    private var revisions: [String: Int] = [:]
    /// Saves of each field not yet answered.
    private var inFlight: [String: Int] = [:]
    private var queue: Task<Void, Never>?

    init(transport: ConfigTransport) {
        self.transport = transport
    }

    /// The local key a local `/reasoning show|hide` writes, which local surfaces read before the global one.
    static let localShowReasoningKey = "display.platforms.cli.show_reasoning"

    // MARK: Loading

    /// Loads (or reloads) the schema and the record. A reload keeps the pages up while it runs; edits still on
    /// their way are kept over the fresh record so a row never flips back while its save is pending.
    func load() async {
        if phase != .loaded { phase = .loading }
        do {
            async let schema = transport.schema()
            async let config = transport.config()
            let (loadedSchema, loadedConfig) = try await (schema, config)
            self.schema = loadedSchema
            confirmed = loadedConfig
            var shown = loadedConfig
            for key in inFlight.keys {
                if let pending = self.config.value(atPath: key) { shown = shown.settingPath(key, to: pending) }
            }
            self.config = shown
            phase = .loaded
        } catch {
            guard !error.isCancellation else { return }
            if phase != .loaded { phase = .failed(error.localizedDescription) }
        }
    }

    // MARK: Reading

    /// The value a field shows. Reasoning Blocks reads the local key first, as the desktop does.
    func value(_ key: String) -> JSONValue? {
        if key == "display.show_reasoning" {
            let local = config.value(atPath: Self.localShowReasoningKey)
            let value = (local == nil || local == .null) ? config.value(atPath: key) : local
            return value.map { .bool($0.truthy) }
        }
        return config.value(atPath: key)
    }

    /// The schema entry of a field, or one inferred from its value.
    func field(_ key: String) -> ConfigFieldSchema? {
        schema.resolvedField(key, in: config)
    }

    /// The section's fields that exist on this host (in the schema or the config) and show for this config,
    /// limited to one subpage when given (`sectionFieldEntries` + `configSubpageForField`).
    func fields(in section: SettingsSection, subpage: SettingsSubpage? = nil) -> [(key: String, field: ConfigFieldSchema)] {
        let keys = subpage.map { section.keys(in: $0) } ?? section.keys
        return keys.compactMap { key in
            guard SettingsCatalog.isVisible(key, config: config), let field = field(key) else { return nil }
            return (key, field)
        }
    }

    func control(_ key: String) -> FieldControl? {
        guard let field = field(key) else { return nil }
        return FieldControl.resolve(key: key, field: field, value: value(key), config: config)
    }

    // MARK: Writing

    /// Sets one field.
    func set(_ key: String, _ value: JSONValue) {
        set([Entry(key: key, value: value)])
    }

    /// Sets fields together in one save (a route's provider and model). Clearing every enabled toolset asks
    /// first. Stripped keys (voice) are never written.
    func set(_ entries: [Entry], confirmed isConfirmed: Bool = false) {
        let entries = entries.filter { !SettingsCatalog.isStripped($0.key) }
        guard !entries.isEmpty else { return }
        if !isConfirmed, entries.contains(where: { $0.key == "toolsets" && Self.clearsToolsets(from: value("toolsets"), to: $0.value) }) {
            confirmation = Confirmation(
                title: "Remove all enabled toolsets?",
                message: "This disables memory, terminal, web search, delegation, and most other tools until you re-enable them.",
                entries: entries
            )
            return
        }
        // Reasoning Blocks writes the local key too, so the value the row shows is the one saved.
        let expanded = entries.flatMap { entry -> [Entry] in
            entry.key == "display.show_reasoning"
                ? [entry, Entry(key: Self.localShowReasoningKey, value: entry.value)] : [entry]
        }
        var stamps: [String: Int] = [:]
        for entry in expanded {
            config = config.settingPath(entry.key, to: entry.value)
            revisions[entry.key, default: 0] += 1
            stamps[entry.key] = revisions[entry.key]
            inFlight[entry.key, default: 0] += 1
        }
        let keys = entries.map(\.key)
        for key in keys {
            saving.insert(key)
            errors[key] = nil
        }
        let patch = ConfigPatch.make(expanded.map { ($0.key, $0.value) })
        let earlier = queue
        queue = Task { [weak self] in
            await earlier?.value
            guard let self else { return }
            do {
                try await self.transport.save(patch)
                for entry in expanded { self.confirmed = self.confirmed.settingPath(entry.key, to: entry.value) }
                for key in keys where self.field(key)?.restartRequired == true { self.restartPending.insert(key) }
            } catch {
                for entry in expanded where self.revisions[entry.key] == stamps[entry.key] {
                    let old = self.confirmed.value(atPath: entry.key)
                    self.config = old.map { self.config.settingPath(entry.key, to: $0) } ?? self.config.removingPath(entry.key)
                }
                // An older save's failure says nothing about a newer edit of the field.
                let message = error.localizedDescription
                for key in keys where self.revisions[key] == stamps[key] { self.errors[key] = message }
            }
            for entry in expanded {
                let left = (self.inFlight[entry.key] ?? 1) - 1
                self.inFlight[entry.key] = left > 0 ? left : nil
            }
            for key in keys where self.inFlight[key] == nil { self.saving.remove(key) }
        }
    }

    /// Applies a confirmed edit.
    func confirm(_ confirmation: Confirmation) {
        self.confirmation = nil
        set(confirmation.entries, confirmed: true)
    }

    /// Waits for every save sent so far (tests, and pages that reload after saving).
    func settle() async {
        while let task = queue {
            await task.value
            if queue == task { break }
        }
    }

    /// A non-empty list becoming an explicit empty one (`clearsEnabledToolsets`); a missing key isn't a clear.
    static func clearsToolsets(from old: JSONValue?, to new: JSONValue) -> Bool {
        guard let before = old?.arrayValue, !before.isEmpty, let after = new.arrayValue else { return false }
        return after.isEmpty
    }

    // MARK: Search

    /// Every schema field of every section, as search entries (`buildConfigSearchEntries`).
    func searchEntries() -> [SettingsSearchEntry] {
        SettingsCatalog.sections.flatMap { section in
            fields(in: section).compactMap { key, field -> SettingsSearchEntry? in
                guard let subpage = section.subpage(for: key) else { return nil }
                return SettingsSearchEntry(
                    id: "config-field:\(key)", label: SettingsCatalog.label(for: key),
                    description: SettingsCatalog.description(for: key, schema: field),
                    context: "\(section.title) · \(subpage.title)", icon: section.page.icon,
                    keywords: ["settings", section.page.rawValue, section.title, key],
                    target: SettingsTarget(page: section.page, subpage: subpage.id, anchor: key)
                )
            }
        }
    }
}

extension JSONValue {
    /// This record without the value at the dot path (the key was absent before an edit that failed).
    func removingPath(_ path: String) -> JSONValue {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        return Self.removing(parts[...], from: self)
    }

    private static func removing(_ parts: ArraySlice<String>, from node: JSONValue) -> JSONValue {
        guard let head = parts.first, var object = node.objectValue else { return node }
        if parts.count == 1 {
            object[head] = nil
        } else if let child = object[head] {
            object[head] = removing(parts.dropFirst(), from: child)
        }
        return .object(object)
    }
}
