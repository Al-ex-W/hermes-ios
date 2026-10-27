import Foundation

/// The Skills tab's state for one profile (`SkillsTab` + `SkillCatalog` + `store/hub-actions.ts`): the installed
/// list, the built-in optional catalog, hub searches, and the background installs it starts. Built per profile,
/// so one profile's pending writes never land in another's list.
@MainActor
final class SkillsStore: ObservableObject {
    /// One hub action in flight or just finished, keyed by the hub identifier (installs), the skill name
    /// (uninstalls) or `updateAllKey`.
    struct HubAction: Hashable {
        enum Kind { case install, uninstall, update }

        var kind: Kind
        var running: Bool
        var lines: [String]
    }

    static let updateAllKey = "__update_all__"

    @Published private(set) var skills: [CapabilitySkill]?
    @Published private(set) var loadError: String?
    @Published private(set) var official: [OfficialSkill] = []
    @Published private(set) var officialError: String?
    /// A toggle or bulk change is saving: the backend keeps one disabled list, so changes go one at a time.
    @Published private(set) var busy = false
    @Published private(set) var hubActions: [String: HubAction] = [:]
    @Published private(set) var hubResults: HubSearchResponse?
    /// The query `hubResults` answer.
    @Published private(set) var hubQuery: String?
    @Published private(set) var hubSearching = false
    @Published private(set) var hubError: String?
    @Published var failure: String?
    @Published var notice: String?

    let api: SkillsAPI
    let actions: CapabilityActionsAPI
    private var loaded = false

    init(api: SkillsAPI, actions: CapabilityActionsAPI) {
        self.api = api
        self.actions = actions
    }

    func loadOnce() async {
        guard !loaded else { return }
        loaded = true
        await load()
    }

    /// The installed list and the optional catalog, side by side.
    func load() async {
        async let installed: Void = reloadSkills()
        async let catalog: Void = reloadOfficial()
        _ = await (installed, catalog)
    }

    func reloadSkills() async {
        do {
            skills = try await api.skills()
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if skills == nil { loadError = error.dashboardMessage } else { failure = "Skills failed to refresh. \(error.dashboardMessage)" }
        }
    }

    func reloadOfficial() async {
        do {
            official = try await api.official()
            officialError = nil
        } catch {
            guard !error.isCancellation else { return }
            officialError = error.dashboardMessage
        }
    }

    // MARK: Lists

    /// Catalog rows that aren't installed yet (by identifier or by name: skills install by name).
    var available: [OfficialSkill] {
        let names = Set((skills ?? []).map(\.name))
        return official.filter { !$0.installed && !names.contains($0.name) }
    }

    func isInstalled(identifier: String, name: String) -> Bool {
        if (skills ?? []).contains(where: { $0.name == name }) { return true }
        if hubResults?.installed.contains(identifier) == true { return true }
        return official.contains { $0.identifier == identifier && $0.installed }
    }

    func skill(named name: String) -> CapabilitySkill? {
        skills?.first { $0.name == name }
    }

    /// Every category of the installed and available skills, A–Z.
    var categories: [String] {
        Set((skills ?? []).map(\.category) + official.map(\.category)).sorted()
    }

    // MARK: Enable and disable

    /// Turns skills on or off one at a time, showing the change at once and reverting a row whose save fails.
    /// `bulk` reports how many changed.
    func setEnabled(_ targets: [CapabilitySkill], _ enabled: Bool, bulk: Bool = false) async {
        guard !busy, skills != nil, !targets.isEmpty else { return }
        busy = true
        defer { busy = false }
        var done = 0
        for target in targets {
            let previous = skill(named: target.name)?.enabled ?? target.enabled
            patch(target.name) { $0.enabled = enabled }
            do {
                try await api.setEnabled(target.name, enabled)
                done += 1
            } catch {
                patch(target.name) { if $0.enabled == enabled { $0.enabled = previous } }
                failure = "Failed to update \(bulk ? "Skills" : target.name). \(error.dashboardMessage)"
                break
            }
        }
        if bulk, done > 0 { notice = "Updated \(done) \(done == 1 ? "item" : "items") for new sessions." }
        await reloadSkills()
    }

    /// The desktop's "All" switch: the whole profile, never just what the search shows.
    func setAll(_ enabled: Bool) async {
        await setEnabled((skills ?? []).filter { $0.enabled != enabled }, enabled, bulk: true)
    }

    /// "Disable unused": enabled skills with no recorded activity.
    var unused: [CapabilitySkill] { (skills ?? []).filter { $0.enabled && $0.usage == 0 } }

    func disableUnused() async {
        await setEnabled(unused, false, bulk: true)
    }

    private func patch(_ name: String, _ change: (inout CapabilitySkill) -> Void) {
        guard let index = skills?.firstIndex(where: { $0.name == name }) else { return }
        change(&skills![index])
    }

    // MARK: Edit, create, archive

    func content(_ name: String) async throws -> SkillDocument {
        try await api.content(name)
    }

    func save(_ name: String, content: String) async throws {
        try await api.saveContent(name, content)
        notice = "Skill updated. \(name) applies to new sessions."
        await reloadSkills()
    }

    func create(name: String, category: String?, content: String) async throws {
        try await api.create(name: name, content: content, category: category)
        notice = "Skill created. \(name.trimmingCharacters(in: .whitespaces)) applies to new sessions."
        await reloadSkills()
    }

    /// Archives a learned skill (restorable with `hermes curator restore`); the row leaves the list at once.
    @discardableResult
    func archive(_ name: String) async -> Bool {
        let snapshot = skills
        skills?.removeAll { $0.name == name }
        do {
            try await api.archive(name)
            notice = "Skill archived. Restorable via hermes curator restore."
            await reloadSkills()
            return true
        } catch {
            if let snapshot, skills?.contains(where: { $0.name == name }) == false, let row = snapshot.first(where: { $0.name == name }) {
                skills?.append(row)
            }
            failure = "Couldn't archive \(name). \(error.dashboardMessage)"
            return false
        }
    }

    // MARK: Hub

    func searchHub(_ query: String) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !hubSearching else { return }
        hubSearching = true
        hubError = nil
        defer { hubSearching = false }
        do {
            hubResults = try await api.search(query)
            hubQuery = query
        } catch {
            guard !error.isCancellation else { return }
            hubQuery = query
            hubResults = nil
            hubError = "Hub search failed. \(error.dashboardMessage)"
        }
    }

    func install(identifier: String, name: String) async {
        guard hubActions[identifier]?.running != true, !isInstalled(identifier: identifier, name: name) else { return }
        await run(key: identifier, kind: .install, label: name) { try await self.api.install(identifier) }
    }

    func uninstall(_ name: String) async -> Bool {
        await run(key: name, kind: .uninstall, label: name) { try await self.api.uninstall(name) }
    }

    func updateAll() async {
        await run(key: Self.updateAllKey, kind: .update, label: "Installed skills") { try await self.api.updateAll() }
    }

    /// Spawns the action, tails its log into `hubActions[key]`, then refreshes the lists. A non-zero exit is a
    /// failure with the log's last lines, so a refused install never reads as "did nothing".
    @discardableResult
    private func run(key: String, kind: HubAction.Kind, label: String,
                     spawn: @escaping () async throws -> CapabilityAction) async -> Bool {
        guard hubActions[key]?.running != true else { return false }
        hubActions[key] = HubAction(kind: kind, running: true, lines: [])
        defer { hubActions[key]?.running = false }
        do {
            let started = try await spawn()
            guard started.ok else { throw DashboardError.rpc("Hermes didn't start the action.") }
            // The desktop tails hub actions until they stop; ten minutes covers a slow clone.
            let finished = try await actions.follow(started.name, attempts: 500) { [weak self] status in
                self?.hubActions[key]?.lines = status.lines
            }
            await load()
            if let query = hubQuery { await refreshHubInstalled(query) }
            if finished.failed || finished.running {
                let tail = finished.lines.suffix(4).joined(separator: "\n")
                failure = "\(Self.verb(kind)) \(label) didn't finish\(finished.running ? " in time" : "").\(tail.isEmpty ? "" : "\n\n\(tail)")"
                return false
            }
            switch kind {
            case .install: notice = "\(label) installed. It applies to new sessions."
            case .uninstall: notice = "\(label) uninstalled."
            case .update: notice = "Installed skills are up to date."
            }
            return true
        } catch {
            guard !error.isCancellation else { return false }
            failure = "Skill action failed. \(error.dashboardMessage)"
            return false
        }
    }

    private func refreshHubInstalled(_ query: String) async {
        if let fresh = try? await api.search(query) { hubResults = fresh }
    }

    private static func verb(_ kind: HubAction.Kind) -> String {
        switch kind {
        case .install: return "Installing"
        case .uninstall: return "Uninstalling"
        case .update: return "Updating"
        }
    }
}
