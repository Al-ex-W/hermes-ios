import SwiftUI
import UIKit

/// The sidebar column (`app/chat/sidebar/index.tsx`): navigation rows, search, Pinned, the sessions under their
/// dividers, one section per messaging platform, and the profile switcher in the title.
struct SidebarView: View {
    @ObservedObject var sidebar: SidebarModel
    @EnvironmentObject private var calls: CallController
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showSettings = false
    @State private var showProfiles = false
    @State private var renaming: SessionInfo?
    @State private var renameText = ""
    @State private var deleting: SessionInfo?
    @State private var moving: SessionInfo?
    @State private var moveChoices: [SessionProject] = []
    @State private var exported: URL?
    /// Messaging platforms showing all their rows.
    @State private var expandedPlatforms: Set<String> = []

    /// A busy platform shows this many rows until asked for more.
    private static let platformRows = 3

    private var searching: Bool { !sidebar.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The Command Center shows beside the sidebar (iPad), so its button reads as on.
    private var commandCenterOpen: Bool { sizeClass != .compact && sidebar.selection == .commandCenter }

    var body: some View {
        List(selection: $sidebar.selection) {
            navigation
            if searching {
                results
            } else {
                sessions
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.sidebar)
        .environment(\.defaultMinListRowHeight, 28)
        .modifier(SidebarSearch(query: $sidebar.query, compact: sizeClass == .compact))
        .task(id: sidebar.query) {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await sidebar.search()
        }
        .task { await sidebar.refresh() }
        .refreshable { await sidebar.refresh() }
        .navigationTitle(sidebar.scopeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu { profileSwitcher }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: Theme.Icon.settings) }
                    .accessibilityLabel("Settings")
                // The desktop's statusbar Command Center button: it opens in the detail column (pushed on iPhone),
                // and on iPad pressing it again goes back to what was open.
                Button { sidebar.toggleCommandCenter() } label: {
                    Image(systemName: commandCenterOpen ? "command.square.fill" : Theme.Icon.commandCenter)
                }
                .accessibilityLabel(commandCenterOpen ? "Close Command Center" : "Open Command Center")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                SidebarFilterMenu(sidebar: sidebar)
                Button { sidebar.newSession() } label: { Image(systemName: Theme.Icon.newSession) }
                    .accessibilityLabel("New session")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let call = calls.active {
                if let chat = call.chat {
                    ActiveCallBanner(call: call) { sidebar.open(chat) }
                        .padding(.bottom, Theme.Spacing.md)
                } else {
                    // A call whose session the app can't open has no chat to show it in: its controls show here.
                    CallPanel(call: call)
                        .padding(.horizontal, Theme.Spacing.lg)
                        .padding(.bottom, Theme.Spacing.md)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView(profile: sidebar.options.profileScope == SidebarOptions.allProfiles ? nil : sidebar.options.profileScope)
            }
        }
        // A session opened from elsewhere (a tapped notification) shows above any open sheet. Only that: the
        // selection also changes when a sent draft settles into its listed row, which must not close a sheet.
        .onChange(of: sidebar.externalOpens) {
            showSettings = false
            showProfiles = false
        }
        // A sheet covers the chat beside the sidebar: its alerts show as banners meanwhile.
        .onChange(of: showSettings || showProfiles, initial: true) { _, covered in
            model.notifications.covered = covered
        }
        .sheet(isPresented: $showProfiles) {
            NavigationStack {
                ProfilesPage()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Done") { showProfiles = false }
                        }
                    }
            }
        }
        .alert("Rename session", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
               presenting: renaming) { session in
            TextField("Untitled session", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                let title = renameText
                Task { await sidebar.rename(session, to: title) }
            }
        } message: { _ in
            Text("Leave empty to clear.")
        }
        .confirmationDialog("Delete session?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { session in
            Button("Delete", role: .destructive) { Task { await sidebar.delete(session) } }
        } message: { session in
            Text("This will permanently delete “\(session.displayTitle)”. This cannot be undone.")
        }
        .confirmationDialog("Move to project", isPresented: Binding(get: { moving != nil }, set: { if !$0 { moving = nil } }),
                            titleVisibility: .visible, presenting: moving) { session in
            ForEach(moveChoices) { project in
                Button(project.name) { Task { await sidebar.move(session, to: project) } }
            }
        } message: { _ in
            Text(moveChoices.isEmpty ? "No other projects." : "The session's workspace moves to the project's folder.")
        }
        .sheet(item: Binding(get: { exported.map(SharedFile.init) }, set: { if $0 == nil { exported = nil } })) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Hermes", isPresented: Binding(get: { sidebar.actionError != nil }, set: { if !$0 { sidebar.actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sidebar.actionError ?? "")
        }
    }

    // MARK: Sections

    private var navigation: some View {
        Section {
            Button { sidebar.newSession() } label: {
                SidebarNavRow(title: SidebarDestination.draft.title, icon: Theme.Icon.newSession)
            }
            .buttonStyle(.plain)
            .sidebarRow(background: .clear)
            ForEach(SidebarDestination.screens, id: \.self) { destination in
                NavigationLink(value: destination) {
                    SidebarNavRow(title: destination.title, icon: destination.icon)
                }
                .sidebarRow(background: background(destination))
            }
        }
    }

    @ViewBuilder private var sessions: some View {
        let pinned = sidebar.pinned
        let groups = sidebar.sessionGroups
        if !pinned.isEmpty {
            Section(isExpanded: sidebar.expanded("pinned")) {
                ForEach(pinned) { sessionRow($0) }
            } header: {
                SidebarHeader(title: "Pinned")
            }
        }
        Section(isExpanded: sidebar.expanded("sessions")) {
            if let draft = sidebar.visibleDraft {
                NavigationLink(value: SidebarDestination.draft) {
                    DraftSessionRow(chat: draft, status: sidebar.draftStatus(draft))
                }
                .sidebarRow(background: background(.draft))
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { sidebar.discardDraft() } label: { Label("Discard", systemImage: Theme.Icon.delete) }
                }
            }
            ForEach(groups) { group in
                if let title = group.title {
                    GroupDivider(title: title, open: sidebar.expanded("group:\(group.id)"))
                }
                if group.title == nil || sidebar.expanded("group:\(group.id)").wrappedValue {
                    ForEach(group.sessions) { sessionRow($0) }
                }
            }
            listState(empty: groups.isEmpty && pinned.isEmpty && sidebar.visibleDraft == nil)
        } header: {
            SidebarHeader(title: sidebar.options.showArchived ? "Archived" : "Sessions")
        }
        ForEach(sidebar.messagingGroups) { group in
            Section(isExpanded: sidebar.expanded(group.id)) {
                let expanded = expandedPlatforms.contains(group.id)
                ForEach(expanded ? group.sessions : Array(group.sessions.prefix(Self.platformRows))) { sessionRow($0) }
                if group.sessions.count > Self.platformRows {
                    Button(expanded ? "Show fewer" : "Show \(group.sessions.count - Self.platformRows) more") {
                        if expanded { expandedPlatforms.remove(group.id) } else { expandedPlatforms.insert(group.id) }
                    }
                    .buttonStyle(.plain)
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
                    .sidebarRow(background: .clear)
                }
            } header: {
                SidebarHeader(title: group.title ?? "Messaging")
            }
        }
    }

    /// Loading, failure, empty and "load more" rows under the sessions.
    @ViewBuilder private func listState(empty: Bool) -> some View {
        if empty {
            Group {
                if !sidebar.loaded, sidebar.loading || sidebar.loadError == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                } else if let error = sidebar.loadError {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Couldn't load sessions").hermesText(.body).foregroundStyle(Theme.Text.secondary)
                        Text(error).hermesText(.meta).foregroundStyle(Theme.Text.tertiary).lineLimit(3)
                        Button("Retry") { Task { await sidebar.refresh() } }.hermesText(.button)
                    }
                } else {
                    Text(sidebar.options.filtersActive && !sidebar.options.showArchived
                         ? "No sessions match these filters" : sidebar.options.showArchived ? "No archived sessions" : "No sessions yet")
                        .hermesText(.body)
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .sidebarRow(background: .clear)
        }
        if sidebar.hasMore, !sidebar.options.showArchived {
            Button { Task { await sidebar.loadMore() } } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Load more")
                    if sidebar.loading { ProgressView().controlSize(.mini) }
                }
            }
            .buttonStyle(.plain)
            .hermesText(.meta)
            .foregroundStyle(Theme.Text.tertiary)
            .disabled(sidebar.loading)
            .sidebarRow(background: .clear)
        }
        if !sidebar.unreadableProfiles.isEmpty {
            Text("Couldn't read the sessions of \(sidebar.unreadableProfiles.map(sidebar.profileLabel).joined(separator: ", ")). They weren't deleted.")
                .hermesText(.meta)
                .foregroundStyle(Theme.Semantic.attention)
                .sidebarRow(background: .clear)
        }
    }

    private var results: some View {
        let rows = sidebar.searchResults
        return Section {
            if rows.isEmpty, !sidebar.searchPending {
                Text("No sessions match “\(sidebar.query.trimmingCharacters(in: .whitespacesAndNewlines))”.")
                    .hermesText(.body)
                    .foregroundStyle(Theme.Text.tertiary)
                    .sidebarRow(background: .clear)
            }
            ForEach(rows) { sessionRow($0.session, snippet: $0.snippet) }
        } header: {
            HStack(spacing: Theme.Spacing.sm) {
                SidebarHeader(title: "Results")
                if sidebar.searchPending { ProgressView().controlSize(.mini) }
            }
        }
    }

    /// The title menu (`profile-dropdown-switcher.tsx`): the profile the list shows, then the Profiles page.
    @ViewBuilder private var profileSwitcher: some View {
        if sidebar.profiles.count > 1 {
            Picker("Profile", selection: sidebar.binding(\.profileScope)) {
                Text("All profiles").tag(SidebarOptions.allProfiles)
                ForEach(sidebar.profiles) { profile in
                    Text(profile.label).tag(profile.name)
                }
            }
        }
        Section {
            Button { showProfiles = true } label: {
                Label("Manage profiles…", systemImage: Theme.Icon.settings)
            }
        }
    }

    // MARK: Rows

    private func sessionRow(_ session: SessionInfo, snippet: String? = nil) -> some View {
        NavigationLink(value: SidebarDestination.session(session.id)) {
            SessionRow(session: session, status: sidebar.status(of: session), profile: sidebar.profileTag(session),
                       snippet: snippet)
        }
        .sidebarRow(background: background(.session(session.id)))
        .contextMenu { actions(for: session) }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { deleting = session } label: { Label("Delete", systemImage: Theme.Icon.delete) }
            Button { Task { await sidebar.setArchived(session, !session.archived) } } label: {
                Label(session.archived ? "Unarchive" : "Archive",
                      systemImage: session.archived ? Theme.Icon.unarchive : Theme.Icon.archive)
            }
            .tint(Theme.Text.tertiary)
        }
        .swipeActions(edge: .leading) {
            Button { Task { await sidebar.setPinned(session, !session.pinned) } } label: {
                Label(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : Theme.Icon.pin)
            }
            .tint(Theme.primary)
            Button { Task { await sidebar.setUnread(session, !session.unread) } } label: {
                Label(session.unread ? "Mark as read" : "Mark as unread",
                      systemImage: session.unread ? Theme.Icon.markRead : Theme.Icon.markUnread)
            }
            .tint(Theme.Semantic.success)
        }
    }

    /// The row menu (`session-actions-menu.tsx`): identity, then put away or destroy, delete last.
    @ViewBuilder private func actions(for session: SessionInfo) -> some View {
        Button {
            renameText = session.title ?? ""
            renaming = session
        } label: {
            Label("Rename…", systemImage: Theme.Icon.rename)
        }
        Button { Task { await sidebar.setPinned(session, !session.pinned) } } label: {
            Label(session.pinned ? "Unpin" : "Pin", systemImage: session.pinned ? "pin.slash" : Theme.Icon.pin)
        }
        Button { Task { await sidebar.setUnread(session, !session.unread) } } label: {
            Label(session.unread ? "Mark as read" : "Mark as unread",
                  systemImage: session.unread ? Theme.Icon.markRead : Theme.Icon.markUnread)
        }
        Button { UIPasteboard.general.string = session.id } label: {
            Label("Copy ID", systemImage: Theme.Icon.copy)
        }
        Divider()
        Button { Task { await sidebar.branch(session) } } label: {
            Label("Branch", systemImage: Theme.Icon.branch)
        }
        Button { Task { exported = await sidebar.export(session) } } label: {
            Label("Export JSON", systemImage: Theme.Icon.export)
        }
        Button {
            Task {
                moveChoices = await sidebar.projects(for: session)
                moving = session
            }
        } label: {
            Label("Move to project…", systemImage: "folder")
        }
        Divider()
        Button { Task { await sidebar.setArchived(session, !session.archived) } } label: {
            Label(session.archived ? "Unarchive" : "Archive",
                  systemImage: session.archived ? Theme.Icon.unarchive : Theme.Icon.archive)
        }
        Button(role: .destructive) { deleting = session } label: {
            Label("Delete", systemImage: Theme.Icon.delete)
        }
    }

    /// The open row's fill. Stacked on iPhone, the open row is off screen.
    private func background(_ destination: SidebarDestination) -> Color {
        sizeClass != .compact && sidebar.selection == destination ? Theme.Fill.rowActive : .clear
    }
}

/// A section label (`SidebarSectionHeader`).
private struct SidebarHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .hermesText(.label)
            .foregroundStyle(Theme.Text.tertiary)
            .textCase(nil)
    }
}

/// A date or status divider inside Sessions; tapping it folds the rows below.
private struct GroupDivider: View {
    let title: String
    @Binding var open: Bool

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Theme.Spacing.xs) {
                Text(title)
                Image(systemName: Theme.Icon.disclosure)
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                Spacer(minLength: 0)
            }
            .hermesText(.meta)
            .foregroundStyle(Theme.Text.quaternary)
            .padding(.top, Theme.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRow(background: .clear)
        .accessibilityLabel(title)
        .accessibilityValue(open ? "Expanded" : "Collapsed")
        .accessibilityAddTraits(.isHeader)
    }
}

/// The sidebar's view menu (`filter-menu.tsx`): grouping, ordering, filters, the archived list, reset.
struct SidebarFilterMenu: View {
    @ObservedObject var sidebar: SidebarModel

    var body: some View {
        Menu {
            Picker("Grouping", selection: sidebar.binding(\.grouping)) {
                ForEach(SidebarGrouping.allCases.filter { $0 != .profile || sidebar.profiles.count > 1 }) { grouping in
                    Text(grouping.label).tag(grouping)
                }
            }
            .pickerStyle(.menu)
            Picker("Ordering", selection: sidebar.binding(\.ordering)) {
                ForEach(orderings) { ordering in
                    Text(ordering.label).tag(ordering)
                }
            }
            .pickerStyle(.menu)
            Section("Filters") {
                Menu("Status") {
                    ForEach(SessionStatus.allCases, id: \.self) { status in
                        Toggle(status.label, isOn: sidebar.filterBinding(status))
                    }
                }
                if sidebar.options.profileScope == SidebarOptions.allProfiles, sidebar.profiles.count > 1 {
                    Menu("Profile") {
                        ForEach(sidebar.profiles) { profile in
                            Toggle(profile.label, isOn: sidebar.filterBinding(profile: profile.name))
                        }
                    }
                }
                Toggle("Archived", isOn: sidebar.binding(\.showArchived))
                if sidebar.options.isCustomized {
                    Button("Reset to defaults") { sidebar.resetView() }
                }
            }
            Section {
                Button("Mark all as read") { Task { await sidebar.markAllRead() } }
                    .disabled(!sidebar.hasUnread)
            }
        } label: {
            Image(systemName: sidebar.options.filtersActive
                  ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .accessibilityLabel("View options")
    }

    /// Cost appears once some session reports spend.
    private var orderings: [SidebarOrdering] {
        let hasCost = (sidebar.recents + sidebar.archived).contains { $0.costUSD > 0 }
        return SidebarOrdering.allCases.filter { $0 != .cost || hasCost || sidebar.options.ordering == .cost }
    }
}

private extension View {
    /// Sidebar row chrome: tight insets, no separators, the given fill.
    func sidebarRow(background: Color) -> some View {
        listRowInsets(EdgeInsets(top: 0, leading: Theme.Spacing.lg, bottom: 0, trailing: Theme.Spacing.lg))
            .listRowSeparator(.hidden)
            .listRowBackground(background)
    }
}

/// The session search. Beside the iPad's split view it is the system search field; on iPhone, where the collapsed
/// split view's search drawer doesn't take focus when tapped, it is a field of its own pinned above the list (the
/// desktop's plain search field): tapping it focuses it and raises the keyboard, Cancel clears and closes it.
private struct SidebarSearch: ViewModifier {
    @Binding var query: String
    let compact: Bool
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        if compact {
            content.safeAreaInset(edge: .top, spacing: 0) { field }
        } else {
            content.searchable(text: $query, placement: .sidebar, prompt: "Search sessions")
        }
    }

    private var field: some View {
        HStack(spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Text.tertiary)
                    .accessibilityHidden(true)
                TextField("Search sessions", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm + 1)
            .background(Theme.Fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.icon))
            .hermesOutline(radius: Theme.Radius.icon)
            // The whole field focuses, not just the text: the glyph and padding are part of the target.
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            if focused {
                Button("Cancel") {
                    query = ""
                    focused = false
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.default, value: focused)
        .padding(.horizontal, Theme.Spacing.sidebarInset)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.sidebar)
    }
}
