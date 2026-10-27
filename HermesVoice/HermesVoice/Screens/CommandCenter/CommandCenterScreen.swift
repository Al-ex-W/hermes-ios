import SwiftUI

/// The Command Center's sections, in the desktop's order (`SECTIONS`).
enum CommandCenterSection: String, CaseIterable, Identifiable, Hashable {
    case sessions, system, usage, maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sessions: return "Sessions"
        case .system: return "System"
        case .usage: return "Usage"
        case .maintenance: return "Maintenance"
        }
    }

    var detail: String {
        switch self {
        case .sessions: return "Search, pin, and manage sessions"
        case .system: return "Gateway status, logs, restart/update"
        case .usage: return "Token, cost, and skill activity"
        case .maintenance: return "Diagnostics, backup, curator, and memory"
        }
    }

    var systemImage: String {
        switch self {
        case .sessions: return "bubble.left"
        case .system: return "waveform.path.ecg"
        case .usage: return "chart.bar"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }
}

/// What the Sessions section does to a row. The app wires these to the sidebar (`SidebarModel.trySetPinned`,
/// `tryDelete`, `tryExport`) so the sidebar stays in step; a failure is thrown back here and shown. Without them pin
/// and delete go straight to the dashboard, and export isn't offered.
struct CommandCenterSessionActions {
    var setPinned: ((SessionInfo, Bool) async throws -> Void)?
    var export: ((SessionInfo) async throws -> URL)?
    var delete: ((SessionInfo) async throws -> Void)?

    init(setPinned: ((SessionInfo, Bool) async throws -> Void)? = nil, export: ((SessionInfo) async throws -> URL)? = nil,
         delete: ((SessionInfo) async throws -> Void)? = nil) {
        self.setPinned = setPinned
        self.export = export
        self.delete = delete
    }
}

/// The desktop's Command Center (`app/command-center/index.tsx`): Sessions, System (status, health, host stats,
/// logs, restart and update), Usage and Maintenance. The desktop's section rail becomes a list that pushes each
/// section.
struct CommandCenterScreen: View {
    let client: DashboardClient
    /// A profile name, or `SidebarOptions.allProfiles`: the sessions listed, and the profile the system, usage and
    /// maintenance routes act on ("all" acts on the dashboard's own profile).
    let profileScope: String
    let openSession: (_ sessionID: String, _ profile: String?) -> Void
    var sessionActions = CommandCenterSessionActions()
    /// "Import session" (the desktop palette's Command Center item, `/session-import`); nil hides it.
    var sessionImport: SessionImportScreen.Context?

    @State private var opened: CommandCenterSection?
    @State private var importing = false
    private let initialSection: CommandCenterSection?

    init(client: DashboardClient, profileScope: String = SidebarOptions.allProfiles,
         initialSection: CommandCenterSection? = nil, sessionActions: CommandCenterSessionActions = CommandCenterSessionActions(),
         sessionImport: SessionImportScreen.Context? = nil,
         openSession: @escaping (_ sessionID: String, _ profile: String?) -> Void) {
        self.client = client
        self.profileScope = profileScope
        self.initialSection = initialSection
        self.sessionActions = sessionActions
        self.sessionImport = sessionImport
        self.openSession = openSession
        _opened = State(initialValue: initialSection)
    }

    /// The profile the system routes act on; nil is the dashboard's own.
    private var profile: String? { profileScope == SidebarOptions.allProfiles ? nil : profileScope }

    var body: some View {
        List {
            Section {
                ForEach(CommandCenterSection.allCases) { section in
                    row(title: section.title, detail: section.detail, systemImage: section.systemImage) { opened = section }
                    // The desktop lists Import session right after Sessions.
                    if section == .sessions, sessionImport != nil {
                        row(title: "Import session", detail: "Bring a conversation into Hermes and pick up where you left off.",
                            systemImage: Theme.Icon.sessionImport) { importing = true }
                    }
                }
            } footer: {
                FormNote(profile.map { "Acts on the \($0) profile." } ?? "Acts on the dashboard's own profile.")
            }
            .hermesFormRows()
        }
        .hermesForm()
        .navigationTitle("Command Center")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .navigationDestination(item: $opened) { section in
            switch section {
            case .sessions:
                CommandCenterSessionsView(client: client, profileScope: profileScope, actions: sessionActions,
                                          openSession: openSession)
            case .system:
                CommandCenterSystemView(client: client, profile: profile)
            case .usage:
                CommandCenterUsageView(client: client, profile: profile)
            case .maintenance:
                CommandCenterMaintenanceView(client: client, profile: profile)
            }
        }
        .navigationDestination(isPresented: $importing) {
            if let sessionImport { SessionImportScreen(context: sessionImport) }
        }
    }

    private func row(title: String, detail: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                PageRow(title: title, detail: detail, systemImage: systemImage)
                Spacer(minLength: 0)
                Image(systemName: Theme.Icon.disclosure)
                    .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                    .foregroundStyle(Theme.Text.quaternary)
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(Theme.Text.primary)
    }
}

// MARK: - Sessions

/// Every recent session, newest first, to search, open, pin, export or delete.
struct CommandCenterSessionsView: View {
    let client: DashboardClient
    let profileScope: String
    let actions: CommandCenterSessionActions
    let openSession: (_ sessionID: String, _ profile: String?) -> Void

    static let pageSize = 50

    @State private var sessions: [SessionInfo]?
    @State private var loadError: String?
    @State private var limit = Self.pageSize
    @State private var loadingMore = false
    @State private var query = ""
    @State private var pendingDelete: SessionInfo?
    @State private var exported: SharedFile?
    @State private var failure: String?
    @State private var notice: OpsNotice?

    private var filtered: [SessionInfo] {
        let rows = (sessions ?? []).sorted { $0.recency > $1.recency }
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { "\($0.displayTitle) \($0.id)".lowercased().contains(needle) }
    }

    var body: some View {
        Group {
            if let sessions {
                if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No sessions yet." : "No matching results found.",
                                           systemImage: query.isEmpty ? "bubble.left" : Theme.Icon.search)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.background)
                } else {
                    List {
                        Section {
                            ForEach(filtered) { session in row(session) }
                            if sessions.count >= limit, query.isEmpty {
                                Button {
                                    Task { await loadMore() }
                                } label: {
                                    HStack {
                                        Text("Load more")
                                        if loadingMore { Spacer(); ProgressView() }
                                    }
                                }
                                .disabled(loadingMore)
                            }
                        }
                        .hermesFormRows()
                    }
                }
            } else if let loadError {
                ContentUnavailableView {
                    Label("Couldn't load sessions", systemImage: Theme.Icon.warning)
                } description: {
                    Text(loadError)
                } actions: {
                    Button("Try again") { Task { await load() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
            } else {
                List { OpsLoaderRow() }
            }
        }
        .hermesForm()
        .searchable(text: $query, prompt: "Search sessions")
        .navigationTitle("Sessions")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Delete session?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible, presenting: pendingDelete) { session in
            Button("Delete", role: .destructive) { Task { await delete(session) } }
        } message: { session in
            Text("\"\(session.displayTitle)\" and its transcript are deleted for good.")
        }
        .opsShareSheet($exported)
        .failureAlert($failure)
        .opsToast($notice)
    }

    private func row(_ session: SessionInfo) -> some View {
        Button {
            openSession(session.id, session.profile)
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(session.displayTitle).hermesText(.rowTitle).lineLimit(1)
                    Text(subtitle(session))
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if session.pinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: Theme.IconSize.xs))
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityLabel("Pinned")
                }
            }
            .contentShape(Rectangle())
        }
        .foregroundStyle(Theme.Text.primary)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { pendingDelete = session } label: { Label("Delete session", systemImage: Theme.Icon.delete) }
            if actions.export != nil {
                Button { Task { await export(session) } } label: { Label("Export session", systemImage: Theme.Icon.export) }
            }
        }
        .swipeActions(edge: .leading) {
            Button { Task { await setPinned(session, !session.pinned) } } label: {
                Label(session.pinned ? "Unpin session" : "Pin session", systemImage: session.pinned ? "pin.slash" : "pin")
            }
            .tint(Theme.primary)
        }
        .contextMenu {
            Button { Task { await setPinned(session, !session.pinned) } } label: {
                Label(session.pinned ? "Unpin session" : "Pin session", systemImage: session.pinned ? "pin.slash" : "pin")
            }
            if actions.export != nil {
                Button { Task { await export(session) } } label: { Label("Export session", systemImage: Theme.Icon.export) }
            }
            Divider()
            Button(role: .destructive) { pendingDelete = session } label: { Label("Delete session", systemImage: Theme.Icon.delete) }
        }
    }

    private func subtitle(_ session: SessionInfo) -> String {
        var parts: [String] = []
        if let date = session.lastActive ?? session.startedAt { parts.append(date.formatted(date: .abbreviated, time: .shortened)) }
        if profileScope == SidebarOptions.allProfiles, let profile = session.profile { parts.append(profile) }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        do {
            sessions = try await client.profileSessions(profile: profileScope, limit: limit, minMessages: 1,
                                                        excludeSources: SessionSource.recentsExcluded).rows
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if sessions == nil { loadError = error.dashboardMessage } else { failure = error.dashboardMessage }
        }
    }

    private func loadMore() async {
        loadingMore = true
        defer { loadingMore = false }
        limit += Self.pageSize
        await load()
    }

    private func setPinned(_ session: SessionInfo, _ pinned: Bool) async {
        do {
            if let setPinned = actions.setPinned {
                try await setPinned(session, pinned)
            } else {
                _ = try await client.updateSession(session.id, profile: session.profile, pinned: pinned)
            }
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
            return
        }
        await load()
    }

    private func export(_ session: SessionInfo) async {
        guard let export = actions.export else { return }
        do {
            exported = SharedFile(url: try await export(session))
        } catch {
            if !error.isCancellation { failure = "Couldn't export the session: \(error.dashboardMessage)" }
        }
    }

    private func delete(_ session: SessionInfo) async {
        do {
            if let delete = actions.delete {
                try await delete(session)
            } else {
                try await client.deleteSession(session.id, profile: session.profile)
            }
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
            return
        }
        sessions?.removeAll { $0.id == session.id }
        notice = OpsNotice(title: "Session deleted", message: session.displayTitle)
        await load()
    }
}
