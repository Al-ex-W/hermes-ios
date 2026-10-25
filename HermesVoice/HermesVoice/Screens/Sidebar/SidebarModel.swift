import Combine
import SwiftUI

/// Where the split view's detail column points.
enum SidebarDestination: Hashable {
    /// The new chat being drafted (`SidebarModel.draft`).
    case draft
    /// A stored session, by id.
    case session(String)
    case capabilities, messaging, artifacts, scheduledJobs
}

/// How the sidebar lists sessions (the desktop's `store/layout.ts` view atoms), remembered on this device.
struct SidebarOptions: Codable, Equatable {
    static let allProfiles = "all"

    var grouping: SidebarGrouping = .date
    var ordering: SidebarOrdering = .updated
    var statusFilter: Set<SessionStatus> = []
    /// Narrows the all-profiles list to these profiles.
    var profileFilter: Set<String> = []
    /// Lists the archived sessions instead, a flat list of their own.
    var showArchived = false
    /// The profile whose sessions are listed, or `allProfiles`.
    var profileScope = SidebarOptions.allProfiles
    /// Collapsed sections and dividers.
    var collapsed: Set<String> = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case grouping, ordering, statusFilter, profileFilter, showArchived, profileScope, collapsed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        grouping = (try? container.decode(SidebarGrouping.self, forKey: .grouping)) ?? .date
        ordering = (try? container.decode(SidebarOrdering.self, forKey: .ordering)) ?? .updated
        statusFilter = (try? container.decode(Set<SessionStatus>.self, forKey: .statusFilter)) ?? []
        profileFilter = (try? container.decode(Set<String>.self, forKey: .profileFilter)) ?? []
        showArchived = (try? container.decode(Bool.self, forKey: .showArchived)) ?? false
        profileScope = (try? container.decode(String.self, forKey: .profileScope)) ?? Self.allProfiles
        collapsed = (try? container.decode(Set<String>.self, forKey: .collapsed)) ?? []
    }

    var filtersActive: Bool { !statusFilter.isEmpty || !profileFilter.isEmpty || showArchived }
    /// Anything moved off the view as it ships, which makes a reset worth offering.
    var isCustomized: Bool { grouping != .date || ordering != .updated || filtersActive }
}

/// The session sidebar (`apps/desktop/src/app/chat/sidebar`): the lists from REST, search, the view options, row
/// actions, and each row's live state. Running and waiting-on-input come from the gateway's live sessions
/// (`session.active_list`), this app's open prompts and the chats in use here; unread is the backend's read
/// watermark. Lists refresh on `sessions.changed`. Edits show at once and outrank the lists for `editHold`,
/// since the dashboard caches the sidebar answer for a few seconds.
@MainActor
final class SidebarModel: ObservableObject {
    static let pageSize = 50
    static let editHold: TimeInterval = 10

    struct SearchRow: Identifiable {
        var session: SessionInfo
        /// The matched text, for hits from the server.
        var snippet: String?
        var id: String { session.id }
    }

    @Published private(set) var recents: [SessionInfo] = []
    @Published private(set) var messaging: [SessionInfo] = []
    @Published private(set) var archived: [SessionInfo] = []
    @Published private(set) var profiles: [ProfileInfo] = []
    /// More recents exist than the page holds.
    @Published private(set) var hasMore = false
    @Published private(set) var loading = false
    /// The list came back at least once for this scope.
    @Published private(set) var loaded = false
    /// Why the last refresh failed; the lists keep their last good rows.
    @Published private(set) var loadError: String?
    /// Profiles whose sessions couldn't be read (missing from the list, not gone).
    @Published private(set) var unreadableProfiles: [String] = []
    /// Why the last row action failed.
    @Published var actionError: String?

    @Published var query = ""
    @Published private(set) var searchHits: [SessionSearchHit] = []
    /// The query `searchHits` answer; while it isn't the current one, a search is on its way.
    @Published private(set) var searchedQuery = ""

    @Published var selection: SidebarDestination? {
        didSet { if selection != oldValue { selectionChanged(from: oldValue) } }
    }
    /// A new chat that hasn't shown up in the list yet.
    @Published private(set) var draft: ChatModel?
    @Published private(set) var options: SidebarOptions

    /// Stored ids whose turn is running, and those waiting on an answer.
    @Published private(set) var workingIDs: Set<String> = []
    @Published private(set) var needsInputIDs: Set<String> = []

    private weak var app: AppModel?
    private let client: DashboardClient
    private let connection: GatewayConnection
    private var listeners: [UUID] = []
    private var subscriptions: Set<AnyCancellable> = []

    /// The chat on screen, set by the detail column.
    private var openChat: ChatModel?
    /// The draft, the open chat and the one in a call: their busy state and runtime ids feed the rows.
    private var watched: [ChatModel] = []
    private var watchedSubscriptions: [AnyCancellable] = []
    /// `session.active_list`: status per stored id, and runtime id → stored id.
    private var liveStatus: [String: LiveSessionStatus] = [:]
    private var liveRuntime: [String: String] = [:]
    /// `liveRuntime` plus the watched chats' runtime ids.
    private var runtimeToStored: [String: String] = [:]
    /// Runtime (or stored) ids with a prompt open in this app.
    private var promptSessions: Set<String> = []

    private var refreshing: Task<Void, Never>?
    private var refreshAgain = false
    private var refreshSoon: Task<Void, Never>?
    private var liveSoon: Task<Void, Never>?
    private var recentsLimit = SidebarModel.pageSize
    private var archivedLoaded = false

    /// A change made here that a cached list may not show yet.
    private struct Edit {
        var row: SessionInfo
        /// Archived or restored: it moves between the lists.
        var moved = false
        var deleted = false
        var at = Date()
    }

    private var edits: [String: Edit] = [:]
    /// Sessions marked unread while open; they aren't marked read again until left.
    private var keptUnread: Set<String> = []
    /// Rows as they were when opened, so the detail can still name one that left its list.
    private var opened: [String: SessionInfo] = [:]

    private static let optionsKey = "sidebar.options"

    init(app: AppModel, client: DashboardClient, connection: GatewayConnection) {
        self.app = app
        self.client = client
        self.connection = connection
        options = Self.savedOptions()
        listeners = [
            connection.addListener { [weak self] event, sessionID, _ in self?.handle(event, sessionID: sessionID) },
            connection.addStateListener { [weak self] state in
                if state == .connected { self?.scheduleLive() }
            },
        ]
        app.prompts?.$prompts
            .map { Set($0.compactMap(\.sessionID)) }
            .removeDuplicates()
            .sink { [weak self] ids in
                self?.promptSessions = ids
                self?.recomputeLive()
                self?.scheduleLive()
            }
            .store(in: &subscriptions)
        app.calls.$active
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.watch() }
            .store(in: &subscriptions)
    }

    deinit {
        let connection = connection, listeners = listeners
        Task { @MainActor in for listener in listeners { connection.removeListener(listener) } }
    }

    // MARK: What the list shows

    func status(of session: SessionInfo) -> SessionStatus {
        let ids = session.allIDs
        if ids.contains(where: needsInputIDs.contains) { return .needsInput }
        if ids.contains(where: workingIDs.contains) { return .working }
        return session.unread ? .unread : .idle
    }

    /// The draft's row, until the list shows its session.
    var visibleDraft: ChatModel? {
        guard let draft, !isListed(draft) else { return nil }
        return options.statusFilter.isEmpty || options.statusFilter.contains(draftStatus(draft)) ? draft : nil
    }

    func draftStatus(_ chat: ChatModel) -> SessionStatus {
        chat.busy ? .working : chat.hasContent ? .idle : .draft
    }

    var pinned: [SessionInfo] {
        guard !options.showArchived else { return [] }
        return sorted(recents.filter { $0.pinned && passesFilters($0) })
    }

    /// The Sessions section under its dividers. Archived and size-ranked lists have none.
    var sessionGroups: [SessionGroup] {
        let pool = options.showArchived ? archived : recents.filter { !$0.pinned }
        let rows = sorted(pool.filter(passesFilters))
        guard !rows.isEmpty else { return [] }
        if options.showArchived || options.ordering.ranksGlobally {
            return [SessionGroup(id: "all", title: nil, sessions: rows)]
        }
        switch options.grouping {
        case .date: return SessionGroups.byRecency(rows)
        case .status: return SessionGroups.byStatus(rows) { status(of: $0).hasLiveTurn }
        case .project: return SessionGroups.byProject(rows)
        case .profile: return SessionGroups.byProfile(rows, label: profileLabel)
        }
    }

    /// One section per messaging platform.
    var messagingGroups: [SessionGroup] {
        guard !options.showArchived else { return [] }
        return SessionGroups.bySource(sorted(messaging.filter(passesFilters)))
    }

    /// Ranked server hits (id matches first), then loaded rows the server didn't return. Until the server
    /// answers the current query, the loaded rows that match.
    var searchResults: [SearchRow] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        let pool = options.showArchived ? archived : recents + messaging
        let local = SessionGroups.sorted(pool.filter { SessionGroups.matches($0, query: text) }, by: .updated, status: status(of:))
        guard searchedQuery == text else { return local.map { SearchRow(session: $0) } }
        var byID: [String: SessionInfo] = [:]
        for row in pool { for id in row.allIDs where byID[id] == nil { byID[id] = row } }
        var rows: [SearchRow] = []
        var seen: Set<String> = []
        for hit in searchHits {
            var row = byID[hit.session.id] ?? hit.session
            if let edit = edits[row.id] {
                if edit.deleted { continue }
                row = merged(row, edit)
            }
            if seen.insert(row.id).inserted { rows.append(SearchRow(session: row, snippet: hit.snippet)) }
        }
        for row in local where seen.insert(row.id).inserted { rows.append(SearchRow(session: row)) }
        return rows
    }

    var searchPending: Bool {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && searchedQuery != text
    }

    var hasUnread: Bool { (recents + messaging).contains(where: \.unread) }

    /// "All profiles", or the profile listed.
    var scopeTitle: String {
        guard options.profileScope != SidebarOptions.allProfiles else { return profiles.count > 1 ? "All profiles" : "Hermes" }
        return profileLabel(options.profileScope)
    }

    func profileLabel(_ name: String) -> String {
        profiles.first { $0.name == name }?.label ?? name
    }

    /// The owning profile to tag a row with, when the list spans several and isn't grouped by them. Rows of the
    /// default profile go untagged.
    func profileTag(_ session: SessionInfo) -> String? {
        guard options.profileScope == SidebarOptions.allProfiles, profiles.count > 1, options.grouping != .profile,
              let name = session.profile, name != (profiles.first(where: \.isDefault)?.name ?? "default") else { return nil }
        return profileLabel(name)
    }

    /// The row for `id` from any list (or as it was opened); `summary(for:)` opens it.
    func row(_ id: String) -> SessionInfo? {
        for list in [recents, messaging, archived] {
            if let row = list.first(where: { $0.id == id }) { return row }
        }
        return searchHits.first { $0.session.id == id }?.session ?? opened[id]
    }

    func summary(for id: String) -> SessionSummary? { row(id)?.summary }

    private func sorted(_ rows: [SessionInfo]) -> [SessionInfo] {
        SessionGroups.sorted(rows, by: options.ordering, status: status(of:))
    }

    private func passesFilters(_ session: SessionInfo) -> Bool {
        if !options.statusFilter.isEmpty, !options.statusFilter.contains(status(of: session)) { return false }
        if options.profileScope == SidebarOptions.allProfiles, !options.profileFilter.isEmpty,
           !options.profileFilter.contains(session.profile ?? "default") {
            return false
        }
        return true
    }

    private func isListed(_ chat: ChatModel) -> Bool {
        let ids = chat.sessionIDs.union(chat.storedID.map { [$0] } ?? [])
        return (recents + messaging).contains { row in row.allIDs.contains(where: ids.contains) }
    }

    // MARK: View options

    func update(_ change: (inout SidebarOptions) -> Void) {
        let old = options
        var next = old
        change(&next)
        // Grouping by owner asks to see every owner; one profile has nothing to group or narrow.
        if next.grouping == .profile, old.grouping != .profile { next.profileScope = SidebarOptions.allProfiles }
        if next.profileScope != SidebarOptions.allProfiles {
            if next.grouping == .profile { next.grouping = .date }
            next.profileFilter = []
        }
        guard next != old else { return }
        options = next
        if let data = try? JSONEncoder().encode(next) { UserDefaults.standard.set(data, forKey: Self.optionsKey) }
        if next.profileScope != old.profileScope {
            recents = []
            messaging = []
            archived = []
            archivedLoaded = false
            loaded = false
            hasMore = false
            recentsLimit = Self.pageSize
            searchHits = []
            searchedQuery = ""
            Task {
                await refresh()
                await search()
            }
        } else if next.showArchived, !old.showArchived {
            Task { await loadArchived() }
        }
    }

    func binding<Value>(_ keyPath: WritableKeyPath<SidebarOptions, Value>) -> Binding<Value> {
        Binding(get: { self.options[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func filterBinding(_ status: SessionStatus) -> Binding<Bool> {
        Binding(get: { self.options.statusFilter.contains(status) }, set: { on in
            self.update { if on { $0.statusFilter.insert(status) } else { $0.statusFilter.remove(status) } }
        })
    }

    func filterBinding(profile name: String) -> Binding<Bool> {
        Binding(get: { self.options.profileFilter.contains(name) }, set: { on in
            self.update { if on { $0.profileFilter.insert(name) } else { $0.profileFilter.remove(name) } }
        })
    }

    /// Open unless collapsed; sections and dividers start open.
    func expanded(_ key: String) -> Binding<Bool> {
        Binding(get: { !self.options.collapsed.contains(key) }, set: { open in
            self.update { if open { $0.collapsed.remove(key) } else { $0.collapsed.insert(key) } }
        })
    }

    /// Grouping, ordering and filters as they ship; the profile listed and collapsed sections stay.
    func resetView() {
        update { options in
            var fresh = SidebarOptions()
            fresh.profileScope = options.profileScope
            fresh.collapsed = options.collapsed
            options = fresh
        }
    }

    private static func savedOptions() -> SidebarOptions {
        guard let data = UserDefaults.standard.data(forKey: optionsKey),
              let options = try? JSONDecoder().decode(SidebarOptions.self, from: data) else { return SidebarOptions() }
        return options
    }

    // MARK: Loading

    /// Fetches the lists (and the archived one while shown), the profiles and the live state. Single flight;
    /// a refresh asked for meanwhile runs once more after it.
    func refresh() async {
        if let refreshing {
            refreshAgain = true
            return await refreshing.value
        }
        let task = Task {
            repeat {
                refreshAgain = false
                await load()
            } while refreshAgain
            refreshing = nil
        }
        refreshing = task
        await task.value
    }

    func loadMore() async {
        recentsLimit += Self.pageSize
        await refresh()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        let scope = options.profileScope
        do {
            let page = try await client.sidebarSessions(profile: scope, recentsLimit: recentsLimit)
            // The scope changed meanwhile; its own refresh follows.
            guard scope == options.profileScope else { return }
            recents = applyEdits(page.recents, archivedList: false, inserting: true)
            messaging = applyEdits(page.messaging, archivedList: false, inserting: false)
            hasMore = page.truncated
            unreadableProfiles = page.unreadable
            loadError = page.failed ? "Hermes couldn't read the session list." : nil
            loaded = true
        } catch {
            if !error.isCancellation { loadError = error.localizedDescription }
        }
        if let profiles = try? await client.profiles(), !profiles.isEmpty {
            self.profiles = profiles
            if scope != SidebarOptions.allProfiles, !profiles.contains(where: { $0.name == scope }) {
                update { $0.profileScope = SidebarOptions.allProfiles }
            }
        }
        if options.showArchived { await loadArchived() }
        settleDraft()
        readOpenSession()
        // Not awaited: an unreachable gateway mustn't hold up the list (or pull to refresh).
        scheduleLive(after: 0)
    }

    private func loadArchived() async {
        let scope = options.profileScope
        guard let rows = try? await client.archivedSessions(profile: scope), scope == options.profileScope else { return }
        archived = applyEdits(rows, archivedList: true, inserting: true)
        archivedLoaded = true
    }

    private func scheduleRefresh(after delay: TimeInterval = 1) {
        refreshSoon?.cancel()
        refreshSoon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: Search

    /// Searches the profile listed, or every profile. Call it after `query` changes.
    func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            searchHits = []
            searchedQuery = ""
            return
        }
        let scope = options.profileScope
        var hits: [SessionSearchHit] = []
        do {
            if scope == SidebarOptions.allProfiles, profiles.count > 1 {
                hits = await searchEveryProfile(text)
            } else {
                hits = try await client.searchSessions(text, profile: scope == SidebarOptions.allProfiles ? nil : scope)
            }
        } catch {
            if error.isCancellation { return }
        }
        guard text == query.trimmingCharacters(in: .whitespacesAndNewlines), scope == options.profileScope else { return }
        searchHits = hits
        searchedQuery = text
    }

    /// Each profile's ranked hits, interleaved by rank, so every profile's id matches come first.
    private func searchEveryProfile(_ text: String) async -> [SessionSearchHit] {
        let client = client, names = profiles.map(\.name)
        let pages = await withTaskGroup(of: (Int, [SessionSearchHit]).self) { group in
            for (index, name) in names.enumerated() {
                group.addTask { (index, (try? await client.searchSessions(text, profile: name)) ?? []) }
            }
            var pages = Array(repeating: [SessionSearchHit](), count: names.count)
            for await (index, hits) in group { pages[index] = hits }
            return pages
        }
        var merged: [SessionSearchHit] = []
        var seen: Set<String> = []
        for rank in 0..<(pages.map(\.count).max() ?? 0) {
            for page in pages where rank < page.count {
                let hit = page[rank]
                if seen.insert("\(hit.session.profile ?? "")/\(hit.session.id)").inserted { merged.append(hit) }
            }
        }
        return merged
    }

    // MARK: Navigation

    /// Opens the draft of a new session, starting one unless the current draft is still empty.
    func newSession() {
        if draft.map({ $0.hasContent || isListed($0) }) ?? true {
            draft = app?.chat(for: nil, profile: options.profileScope == SidebarOptions.allProfiles ? nil : options.profileScope)
        }
        selection = draft == nil ? nil : .draft
        watch()
    }

    /// Lets go of the draft that hasn't been sent.
    func discardDraft() {
        if selection == .draft { selection = nil }
        draft = nil
        watch()
    }

    /// Opens a chat held elsewhere (the one in a call).
    func open(_ chat: ChatModel) {
        if chat === draft || chat.storedID == nil {
            draft = chat
            selection = .draft
        } else if let id = chat.storedID {
            if row(id) == nil { opened[id] = SessionInfo(id: id, title: chat.title, profile: chat.profile) }
            selection = .session(id)
        }
        watch()
    }

    /// The detail column shows `chat`.
    func show(_ chat: ChatModel) {
        guard openChat !== chat else { return }
        openChat = chat
        watch()
    }

    private func selectionChanged(from old: SidebarDestination?) {
        if case let .session(id)? = old { keptUnread.remove(id) }
        switch selection {
        case let .session(id)?:
            if let row = row(id) { opened[id] = row }
            readOpenSession()
        case .draft?:
            openChat = draft
        default:
            openChat = nil
        }
        watch()
    }

    /// The draft's session is in the list now: its row takes over.
    private func settleDraft() {
        guard let draft, isListed(draft) else { return }
        let ids = draft.sessionIDs.union(draft.storedID.map { [$0] } ?? [])
        let row = (recents + messaging).first { $0.allIDs.contains(where: ids.contains) }
        self.draft = nil
        if selection == .draft, let row {
            opened[row.id] = row
            selection = .session(row.id)
        }
    }

    /// Opening a session reads it, as on the desktop.
    private func readOpenSession() {
        guard case let .session(id)? = selection, let row = row(id), row.unread, !keptUnread.contains(id) else { return }
        Task { await setUnread(row, false, quietly: true) }
    }

    // MARK: Row actions

    func rename(_ session: SessionInfo, to title: String) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await mutate(session, { $0.title = title.isEmpty ? nil : title }) { client in
            _ = try await client.updateSession(session.id, profile: session.profile, title: title)
        }
    }

    func setPinned(_ session: SessionInfo, _ pinned: Bool) async {
        await mutate(session, { $0.pinned = pinned }) { client in
            _ = try await client.updateSession(session.id, profile: session.profile, pinned: pinned)
        }
    }

    func setUnread(_ session: SessionInfo, _ unread: Bool, quietly: Bool = false) async {
        if unread, selection == .session(session.id) { keptUnread.insert(session.id) }
        await mutate(session, quietly: quietly, { $0.unread = unread }) { client in
            _ = try await client.updateSession(session.id, profile: session.profile, unread: unread)
        }
    }

    func setArchived(_ session: SessionInfo, _ archived: Bool) async {
        await mutate(session, moved: true, { $0.archived = archived }) { client in
            _ = try await client.updateSession(session.id, profile: session.profile, archived: archived)
        }
    }

    func delete(_ session: SessionInfo) async {
        if selection == .session(session.id) { selection = nil }
        await mutate(session, deleted: true, { _ in }) { client in
            try await client.deleteSession(session.id, profile: session.profile)
        }
        if edits[session.id]?.deleted == true { opened[session.id] = nil }
    }

    /// The chat's session menu already changed `id` on Hermes: the lists show it the same way at once.
    func applied(_ event: SessionMenuEvent, to id: String) async {
        guard let session = row(id) ?? opened[id] else { return scheduleRefresh() }
        switch event {
        case let .renamed(title):
            await mutate(session, { $0.title = title.isEmpty ? nil : title }) { _ in }
        case let .pinned(pinned):
            await mutate(session, { $0.pinned = pinned }) { _ in }
        case let .unread(unread):
            if unread, selection == .session(id) { keptUnread.insert(id) }
            await mutate(session, { $0.unread = unread }) { _ in }
        case let .archived(archived):
            await mutate(session, moved: true, { $0.archived = archived }) { _ in }
        case .deleted:
            if selection == .session(id) { selection = nil }
            await mutate(session, deleted: true, { _ in }) { _ in }
            opened[id] = nil
        case let .moved(cwd):
            await mutate(session, { $0.cwd = cwd }) { _ in }
        case .branched:
            scheduleRefresh()
        }
    }

    func markAllRead() async {
        for row in recents + messaging where row.unread { await setUnread(row, false) }
    }

    /// Shows the change at once, sends it, and puts the lists back if it fails.
    private func mutate(_ session: SessionInfo, moved: Bool = false, deleted: Bool = false, quietly: Bool = false,
                        _ change: (inout SessionInfo) -> Void,
                        request: (DashboardClient) async throws -> Void) async {
        var row = row(session.id) ?? session
        change(&row)
        let before = (recents, messaging, archived, edits[session.id])
        edits[session.id] = Edit(row: row, moved: moved || before.3?.moved == true, deleted: deleted)
        recents = applyEdits(recents, archivedList: false, inserting: true)
        messaging = applyEdits(messaging, archivedList: false, inserting: false)
        archived = applyEdits(archived, archivedList: true, inserting: archivedLoaded)
        do {
            try await request(client)
        } catch {
            edits[session.id] = before.3
            (recents, messaging, archived) = (before.0, before.1, before.2)
            if !quietly, !error.isCancellation { actionError = error.localizedDescription }
        }
    }

    /// Lays the recent edits over a fetched list: deleted and moved-away rows leave, edited ones take the edit,
    /// and with `inserting` rows moved into this list join it.
    private func applyEdits(_ rows: [SessionInfo], archivedList: Bool, inserting: Bool) -> [SessionInfo] {
        let now = Date()
        edits = edits.filter { now.timeIntervalSince($0.value.at) < Self.editHold }
        var result: [SessionInfo] = rows.compactMap { row in
            guard let edit = edits[row.id] else { return row }
            if edit.deleted || edit.row.archived != archivedList { return nil }
            return merged(row, edit)
        }
        guard inserting else { return result }
        let present = Set(result.map(\.id))
        for edit in edits.values where edit.moved && !edit.deleted && edit.row.archived == archivedList
            && !present.contains(edit.row.id) {
            result.append(edit.row)
        }
        return result
    }

    private func merged(_ row: SessionInfo, _ edit: Edit) -> SessionInfo {
        var row = row
        row.title = edit.row.title
        row.pinned = edit.row.pinned
        row.unread = edit.row.unread
        row.archived = edit.row.archived
        return row
    }

    // MARK: Live state

    private func handle(_ event: GatewayEvent, sessionID: String?) {
        switch event {
        case .sessionsChanged:
            scheduleRefresh()
        case .messageStart:
            guard let sessionID else { return }
            if let stored = runtimeToStored[sessionID] {
                liveStatus[stored] = .working
                recomputeLive()
            } else {
                scheduleLive()
            }
        case .messageComplete, .error:
            if sessionID != nil { scheduleLive() }
        default:
            break
        }
    }

    /// Asks the gateway which sessions are live and what they are doing.
    func refreshLive() async {
        do {
            try await connection.connect()
            let result = try await connection.client.sessionActiveList()
            var status: [String: LiveSessionStatus] = [:]
            var runtime: [String: String] = [:]
            for item in result.sessions where !item.sessionKey.isEmpty {
                status[item.sessionKey] = item.status
                runtime[item.id] = item.sessionKey
            }
            liveStatus = status
            liveRuntime = runtime
        } catch {
            // Without the gateway nothing is known to be running; the next refresh asks again.
            if !error.isCancellation {
                liveStatus = [:]
                liveRuntime = [:]
            }
        }
        recomputeLive()
    }

    private func scheduleLive(after delay: TimeInterval = 0.5) {
        liveSoon?.cancel()
        liveSoon = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshLive()
        }
    }

    /// Follows the draft, the open chat and the call's chat.
    private func watch() {
        var chats: [ChatModel] = []
        for chat in [draft, openChat, app?.calls.active?.chat].compactMap({ $0 }) where !chats.contains(where: { $0 === chat }) {
            chats.append(chat)
        }
        guard chats.map(ObjectIdentifier.init) != watched.map(ObjectIdentifier.init) else { return }
        watched = chats
        // `@Published` sends before the value changes: read it on the next turn.
        watchedSubscriptions = chats.map { chat in
            chat.$busy.removeDuplicates().map { _ in () }
                .merge(with: chat.$sessionIDs.removeDuplicates().map { _ in () })
                .receive(on: DispatchQueue.main)
                .sink { [weak self] in self?.recomputeLive() }
        }
        recomputeLive()
    }

    private func recomputeLive() {
        var runtime = liveRuntime
        var working: Set<String> = []
        var waiting: Set<String> = []
        for chat in watched {
            guard let stored = chat.storedID else { continue }
            for id in chat.sessionIDs { runtime[id] = stored }
            if chat.busy { working.insert(stored) }
        }
        for (key, status) in liveStatus {
            switch status {
            case .waiting: waiting.insert(key)
            case .working, .streaming, .starting, .resuming: working.insert(key)
            default: break
            }
        }
        for id in promptSessions { waiting.insert(runtime[id] ?? id) }
        runtimeToStored = runtime
        if working != workingIDs { workingIDs = working }
        if waiting != needsInputIDs { needsInputIDs = waiting }
    }
}
