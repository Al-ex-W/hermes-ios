import SwiftUI

/// The desktop's "Continue from another app" (`app/session-import`, the `/session-import` overlay): Claude Code and
/// Codex conversations found on the Hermes host, by source and day, searchable, each previewed before it is copied
/// into a profile's history and opened as a Hermes session. Only logs on the host are offered: the gateway methods
/// take the host's own handles, not uploads.
struct SessionImportScreen: View {
    /// What the screen needs from the shell.
    struct Context {
        /// For the profile list behind "Import into".
        let client: DashboardClient
        /// The `session.foreign.*` calls go over it.
        let connection: GatewayConnection
        /// The sidebar's profile, or `SidebarOptions.allProfiles` (then the dashboard's own profile).
        var profileScope: String = SidebarOptions.allProfiles
        /// Opens a stored session (id, profile) in the detail column.
        let openSession: (_ sessionID: String, _ profile: String?) -> Void
    }

    let context: Context
    @StateObject private var store: SessionImportStore
    @StateObject private var profiles = ProfileScopeModel()
    @State private var query = ""
    /// The conversation whose preview is pushed. An item destination, not a value one: this screen is itself
    /// pushed (from the Command Center), and SwiftUI ignores value destinations declared below the stack's root.
    @State private var previewing: ForeignSessionRow?

    init(context: Context) {
        self.context = context
        let scope = context.profileScope == SidebarOptions.allProfiles ? nil : context.profileScope
        _store = StateObject(wrappedValue: SessionImportStore(calls: context.connection.client, destination: scope))
    }

    /// For tests and previews: the store over any calls.
    init(context: Context, store: SessionImportStore) {
        self.context = context
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        List {
            header
            Section {
                Picker("Source", selection: sourceBinding) {
                    ForEach(SessionImportSource.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.page, bottom: 0, trailing: Theme.Spacing.page))
            }
            listContent
        }
        .listStyle(.insetGrouped)
        .hermesForm()
        .searchable(text: $query, prompt: "Search loaded sessions")
        .navigationTitle("Import session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if store.refreshing {
                    ProgressView().accessibilityLabel("Finding conversations")
                } else {
                    Button { Task { await store.load() } } label: { Image(systemName: Theme.Icon.retry) }
                        .accessibilityLabel("Refresh")
                }
            }
        }
        .refreshable { await store.load() }
        .task {
            if store.rows.isEmpty, store.phase == .loading { await store.load() }
        }
        .task { await profiles.load(context.client) }
        .navigationDestination(item: $previewing) { row in
            SessionImportPreviewScreen(store: store, row: row, openSession: context.openSession)
        }
    }

    private var sourceBinding: Binding<SessionImportSource> {
        Binding(get: { store.source }, set: { next in Task { await store.select(next) } })
    }

    // MARK: Header

    private var header: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Continue from another app")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Text.primary)
                Text("Bring a conversation into Hermes and pick up where you left off.")
                    .hermesText(.body)
                    .foregroundStyle(Theme.Text.secondary)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.page, bottom: Theme.Spacing.md,
                                      trailing: Theme.Spacing.page))
            Label {
                Text("Reading from \(store.host ?? "the connected computer")")
            } icon: {
                Image(systemName: Theme.Icon.symbol(codicon: "device-desktop"))
            }
            .hermesText(.caption)
            .foregroundStyle(Theme.Text.secondary)
            .hermesFormRows()
            destinationRow
        }
    }

    @ViewBuilder private var destinationRow: some View {
        if profiles.profiles.count > 1 {
            Picker(selection: destinationBinding) {
                ForEach(profiles.profiles) { profile in
                    Text(ProfileScopeSection.label(profile)).tag(profile.name)
                }
            } label: {
                Label("Import into", systemImage: Theme.Icon.profile)
            }
            .hermesText(.caption)
            .foregroundStyle(Theme.Text.secondary)
            .hermesFormRows()
        } else {
            Label {
                Text("Import into \(store.destination ?? profiles.dashboardProfile)")
            } icon: {
                Image(systemName: Theme.Icon.profile)
            }
            .hermesText(.caption)
            .foregroundStyle(Theme.Text.secondary)
            .hermesFormRows()
        }
    }

    /// nil (the dashboard's own profile) shows as that profile's name.
    private var destinationBinding: Binding<String> {
        Binding(get: { store.destination ?? profiles.dashboardProfile },
                set: { store.setDestination($0 == profiles.dashboardProfile ? nil : $0) })
    }

    // MARK: List

    @ViewBuilder private var listContent: some View {
        switch store.phase {
        case .loading:
            Section {
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Finding conversations").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.xxl)
                .listRowBackground(Color.clear)
            }
        case let .failed(message):
            Section {
                ContentUnavailableView {
                    Label("Could not find sessions", systemImage: Theme.Icon.error)
                } description: {
                    Text("Check your backend connection, then try again. Older backends may need an update.\n\(message)")
                } actions: {
                    Button("Retry") { Task { await store.load() } }
                }
                .listRowBackground(Color.clear)
            }
        case .loaded:
            let visible = SessionImportList.filter(store.rows, query: query)
            if visible.isEmpty {
                Section {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "No conversations found" : "No matching conversations",
                              systemImage: Theme.Icon.symbol(codicon: "comment-discussion"))
                    } description: {
                        Text(query.isEmpty ? "Claude Code and Codex sessions on this backend will appear here."
                                           : "Try another title or folder, or load more sessions.")
                    }
                    .listRowBackground(Color.clear)
                }
            } else {
                ForEach(SessionImportList.days(visible)) { day in
                    Section {
                        ForEach(day.rows) { row in
                            Button { previewing = row } label: {
                                HStack {
                                    SessionImportRow(row: row)
                                    Image(systemName: Theme.Icon.disclosure)
                                        .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                                        .foregroundStyle(Theme.Text.quaternary)
                                }
                                .contentShape(Rectangle())
                            }
                            .foregroundStyle(Theme.Text.primary)
                        }
                    } header: {
                        Text(day.title)
                    }
                    .hermesFormRows()
                }
            }
            if store.unreadable > 0 || store.hasMore {
                Section {
                    if store.hasMore {
                        Button {
                            Task { await store.loadMore() }
                        } label: {
                            HStack {
                                Text("Load more sessions")
                                if store.loadingMore {
                                    Spacer()
                                    ProgressView()
                                }
                            }
                        }
                        .disabled(store.loadingMore)
                    }
                } footer: {
                    if store.unreadable > 0 { FormNote("Some logs were empty, unreadable, or too large to preview.") }
                }
                .hermesFormRows()
            }
        }
    }
}

/// A conversation in the list: its source and message count, title, and folder or opening words.
struct SessionImportRow: View {
    let row: ForeignSessionRow

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: Theme.Icon.symbol(codicon: "comment-discussion"))
                Text(row.label)
                Spacer(minLength: Theme.Spacing.md)
                Text("\(row.messages) messages").monospacedDigit()
            }
            .hermesText(.meta)
            .foregroundStyle(Theme.Text.tertiary)
            Text(row.displayTitle)
                .hermesText(.rowTitle)
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(2)
            if !row.detail.isEmpty {
                Text(row.detail)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}
