import SwiftUI

/// Capabilities › Connectors (`app/capabilities/connectors/connectors-tab.tsx` with `connectors-directory.tsx`): the
/// managed apps of the profile's Nous account (over the gateway's `connectors.*` RPCs), the MCP servers Hermes runs
/// on its host, the catalog entries it can install, and "Add your own", in the desktop's groups (Connected, On the
/// Hermes host, Available, Turned off). `profile` is the Capabilities scope (`?profile=`; nil is the dashboard's
/// own). The desktop's raw mcp.json editor isn't on the phone; the structured editor covers the server entry without
/// showing secrets.
struct ConnectorsScreen: View {
    let client: DashboardClient
    var profile: String?
    /// The live gateway, for `reload.mcp` after each change; nil while it isn't connected.
    var gateway: GatewayClient?

    init(client: DashboardClient, profile: String? = nil, gateway: GatewayClient? = nil) {
        self.client = client
        self.profile = profile
        self.gateway = gateway
    }

    /// The Capabilities tab's entry: its scoped connection and profile.
    init(context: CapabilitiesContext) {
        self.init(client: context.client, profile: context.profile, gateway: context.gateway)
    }

    var body: some View {
        // A new scope is a new page: nothing of the previous profile's servers, probes or sign-ins carries over.
        ConnectorsDirectory(api: MCPAPI(transport: client, profile: profile),
                            hostedAPI: gateway.map { HostedConnectorsAPI(gateway: $0.transport, profile: profile) },
                            reloadSessions: gateway.map(Self.reload), client: client, profile: profile)
            .id(profile ?? "")
    }

    /// `reload.mcp` with the prompt-cache question already answered (the desktop's `silentReload`). Hermes
    /// rediscovers every live session's servers, each profile's own; a reload can take a while.
    static func reload(_ gateway: GatewayClient) -> () async throws -> Void {
        { _ = try await gateway.reloadMcp(.init(confirm: true), timeout: 90) }
    }
}

/// A card the detail sheet shows (`sheet(item:)` wants an identity).
private struct OpenCard: Identifiable, Hashable {
    let key: String
    var id: String { key }
}

private struct ConnectorsDirectory: View {
    @StateObject private var model: ConnectorsModel
    @State private var query = ""
    @State private var segment: ConnectorSegment = .all
    @State private var opened: OpenCard?
    @State private var adding = false
    /// The server just added, opened once the add sheet is gone.
    @State private var added: String?
    @State private var removing: ConnectorCard?

    /// For the Nous sign-in link (Settings ▸ Providers for the scoped profile).
    let client: DashboardClient
    let profile: String?

    init(api: MCPAPI, hostedAPI: HostedConnectorsAPI?, reloadSessions: (() async throws -> Void)?,
         client: DashboardClient, profile: String?) {
        _model = StateObject(wrappedValue: ConnectorsModel(api: api, hostedAPI: hostedAPI, reloadSessions: reloadSessions))
        self.client = client
        self.profile = profile
    }

    var body: some View {
        let cards = model.cards
        let page = ConnectorPage(cards: cards, query: query, segment: segment)
        // The Capabilities page around it owns the title; this tab brings its search and its Add button.
        content(cards: cards, page: page)
            .searchable(text: $query, prompt: cards.isEmpty ? "Search apps" : "Search \(cards.count) apps")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add your own", systemImage: "plus")
                    }
                    .disabled(model.servers == nil)
                }
            }
            .task { await model.load() }
            .refreshable { await model.load(force: true) }
            .onDisappear { model.stopAllAuth() }
            .sheet(item: $opened) { open in
                if open.key.hasPrefix("hosted:") {
                    HostedConnectorSheet(model: model, slug: String(open.key.dropFirst("hosted:".count)))
                } else {
                    ConnectorDetailSheet(model: model, cardKey: open.key)
                }
            }
            // A sign-in started from the list opens here; with a detail open, that sheet shows it instead.
            .sheet(item: Binding(get: { opened == nil ? model.browser : nil }, set: { model.browser = $0 }),
                   onDismiss: { model.browserClosed() }) { page in
                SafariSheet(url: page.url).ignoresSafeArea()
            }
            .sheet(isPresented: $adding, onDismiss: {
                if let added { opened = OpenCard(key: ConnectorCards.key(added)) }
                added = nil
            }) {
                NavigationStack {
                    MCPServerForm(model: model, mode: .add) { name in added = name }
                }
            }
            .confirmationDialog("Remove \(removing?.name ?? "")?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { card in
                Button("Remove", role: .destructive) {
                    guard let name = card.serverName else { return }
                    Task { _ = await model.remove(name) }
                }
            } message: { _ in
                Text(ConnectorCopy.removeBody)
            }
            .failureAlert($model.failure)
    }

    @ViewBuilder
    private func content(cards: [ConnectorCard], page: ConnectorPage) -> some View {
        if model.servers == nil {
            if let error = model.loadError {
                ContentUnavailableView {
                    Label("Couldn't read the MCP servers", systemImage: Theme.Icon.error)
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                }
            } else {
                VStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Reading the catalog and the servers on the Hermes host")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.sidebar)
            }
        } else if cards.isEmpty {
            ContentUnavailableView {
                Label("No apps here yet", systemImage: "powerplug")
            } description: {
                Text("Add a server on the Hermes host to get started.")
            } actions: {
                Button("Add your own") { adding = true }
            }
        } else if page.sections.isEmpty {
            ContentUnavailableView {
                Label("No matching apps", systemImage: Theme.Icon.search)
            } description: {
                Text("Nothing here matches. Point Hermes at your own MCP server to add it.")
            } actions: {
                Button("Clear the search") {
                    query = ""
                    segment = .all
                }
                Button("Add your own") { adding = true }
            }
        } else {
            list(page)
        }
    }

    /// Where the managed apps stand when they can't list (`signInLine`, `managedUnavailable`, `hostedFailed`).
    @ViewBuilder private var hostedNotice: some View {
        switch model.hostedPhase {
        case .signedOut:
            Section {
                NavigationLink {
                    ProvidersScreen(client: client, scope: profile)
                } label: {
                    Label("Sign in to Nous to use managed apps.", systemImage: "person.crop.circle.badge.checkmark")
                }
            } footer: {
                FormNote("Nous apps follow your account, not the profile.")
            }
            .hermesFormRows()
        case let .failed(message):
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Could not reach the managed apps.").foregroundStyle(Theme.Text.primary)
                    Text("The servers on the Hermes host are unaffected and still running. Nothing was turned off. \(message)")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                }
                Button("Retry") { Task { await model.reloadHosted() } }
            }
            .hermesFormRows()
        case .unavailable, .loading, .ready:
            EmptyView()
        }
    }

    private func list(_ page: ConnectorPage) -> some View {
        List {
            hostedNotice
            if page.showsSegments || page.segment != segment || page.hiddenMatches > 0 {
                Section {
                    if page.showsSegments {
                        Picker("Group", selection: $segment) {
                            ForEach(page.segments, id: \.segment) { item in
                                Text("\(item.segment.title) \(item.count)").tag(item.segment)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    if page.segment != segment {
                        FormNote("No match in \(segment.title), so every match is shown.")
                    }
                    if page.hiddenMatches > 0 {
                        HStack {
                            FormNote("\(page.hiddenMatches) more match\(page.hiddenMatches == 1 ? "" : "es") in other groups.")
                            Spacer()
                            Button("Show all matches") { segment = .all }
                                .hermesText(.caption)
                                .buttonStyle(.borderless)
                        }
                    }
                }
                .hermesFormRows()
            }
            ForEach(page.sections) { section in
                Section {
                    ForEach(section.cards) { card in
                        row(card)
                    }
                } header: {
                    HStack(spacing: Theme.Spacing.md) {
                        Text(section.group.title)
                        Text("\(section.cards.count)").monospacedDigit().foregroundStyle(Theme.Text.quaternary)
                    }
                    .hermesText(.label)
                    .textCase(nil)
                }
                .hermesFormRows()
            }
            Section {
            } footer: {
                FormNote(model.reloadsLiveSessions
                         ? "These servers run on the Hermes host, not on this phone. Changes reach new chats and running ones."
                         : "These servers run on the Hermes host, not on this phone. Changes apply to new chats; /reload-mcp applies them to a running one.")
            }
        }
        .hermesForm()
    }

    private func row(_ card: ConnectorCard) -> some View {
        ConnectorCardRow(card: card, busy: model.busy.contains(card.key)) {
            opened = OpenCard(key: card.key)
        } onToggle: { next in
            guard let name = card.serverName else { return }
            Task { await model.setEnabled(name, next) }
        } onVerb: {
            runVerb(card)
        }
        .swipeActions(edge: .trailing) {
            if card.hasSwitch {
                Button("Remove", role: .destructive) { removing = card }
            }
        }
        .swipeActions(edge: .leading) {
            if card.hasSwitch, let name = card.serverName {
                Button(card.serverEnabled ? "Turn off" : "Turn on") {
                    Task { await model.setEnabled(name, !card.serverEnabled) }
                }
                .tint(card.serverEnabled ? Theme.Text.tertiary : Theme.primary)
            }
        }
        .contextMenu {
            Button("Open", systemImage: "arrow.up.right.square") { opened = OpenCard(key: card.key) }
            if card.residency == .hosted, let verb = card.verb {
                Button(verb.label, systemImage: "arrow.triangle.2.circlepath") { runVerb(card) }
            }
            if card.installed, let name = card.serverName {
                Button("Test connection", systemImage: "bolt.horizontal") { Task { await model.probe(name) } }
            }
            if card.hasSwitch, let name = card.serverName {
                Button(card.serverEnabled ? "Turn \(card.name) off" : "Turn \(card.name) on",
                       systemImage: card.serverEnabled ? "power" : "power.circle") {
                    Task { await model.setEnabled(name, !card.serverEnabled) }
                }
                Divider()
                Button("Remove", systemImage: Theme.Icon.delete, role: .destructive) { removing = card }
            }
            if !card.installed {
                Button("Install", systemImage: "arrow.down.circle") { runVerb(card) }
            }
        }
    }

    /// `runVerb`: Authenticate signs in from the detail (the browser sheet lives there); an install that needs no
    /// values runs at once; everything else opens the detail.
    private func runVerb(_ card: ConnectorCard) {
        if model.runHostedVerb(card) { return }
        switch card.verb {
        case .authenticate?:
            if let name = card.serverName { model.authenticate(name) }
            opened = OpenCard(key: card.key)
        case .install? where !card.needsEnv:
            guard let entry = model.entry(card.entryName) else { return }
            Task {
                if await model.install(entry, env: [:]) { opened = OpenCard(key: card.key) }
            }
        default:
            opened = OpenCard(key: card.key)
        }
    }
}

// MARK: - Row

/// One card of the directory (`connector-row-card.tsx`): tile, name, kind, catalog mark, the reason or
/// description, and a lane with the state and the server's switch.
struct ConnectorCardRow: View {
    let card: ConnectorCard
    var busy = false
    let onOpen: () -> Void
    let onToggle: (Bool) -> Void
    let onVerb: () -> Void

    private static let tileSize: CGFloat = 32

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Button(action: onOpen) {
                    HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                        ConnectorTile(name: card.name, size: Self.tileSize)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            ConnectorTitleLine(card: card)
                            if let line = secondLine {
                                Text(line)
                                    .hermesText(.caption)
                                    .foregroundStyle(card.reason != nil ? ConnectorStyle.reasonTone(card.state) : Theme.Text.secondary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens \(card.name)")

                if let verb = card.verb {
                    Button(action: onVerb) {
                        HStack(spacing: Theme.Spacing.xs) {
                            if busy { ProgressView().controlSize(.mini) }
                            Text(verb.label)
                        }
                        .hermesText(.button)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(card.state == .available ? Theme.Text.secondary : Theme.primary)
                    .disabled(busy)
                    .padding(.leading, Self.tileSize + Theme.Spacing.lg)
                }
            }

            VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                ConnectorStateLabel(card: card)
                if card.hasSwitch {
                    Toggle(card.serverEnabled ? "Turn \(card.name) off" : "Turn \(card.name) on",
                           isOn: Binding(get: { card.serverEnabled }, set: onToggle))
                        .labelsHidden()
                        .disabled(busy)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
    }

    private var secondLine: String? {
        card.secondLine
    }
}

struct ConnectorTitleLine: View {
    let card: ConnectorCard

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(card.name)
                .hermesText(.rowTitle)
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
            Text(card.kindWord)
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.tertiary)
                .lineLimit(1)
            if card.showsCatalogMark { CatalogMark() }
            if let twin = card.twin {
                Image(systemName: card.residency == .hosted ? "server.rack" : "cloud")
                    .font(.system(size: Theme.IconSize.xs))
                    .foregroundStyle(Theme.Text.tertiary)
                    .accessibilityLabel(twin)
            }
        }
    }
}

/// The state dot and word (or tool count).
struct ConnectorStateLabel: View {
    let card: ConnectorCard

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            if card.state != .available {
                Circle()
                    .fill(ConnectorStyle.dot(card.state))
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(card.stateLabel)
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
        }
    }
}

/// The local app's tile: its initial on a quiet square (the desktop's letter logo).
struct ConnectorTile: View {
    let name: String
    var size: CGFloat = 32

    var body: some View {
        Text(String(name.first.map { String($0).uppercased() } ?? "?"))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(Theme.Text.secondary)
            .frame(width: size, height: size)
            .background(Theme.Fill.secondary, in: RoundedRectangle(cornerRadius: size * 0.26))
            .accessibilityHidden(true)
    }
}

/// "In the Hermes catalog" (`catalog-mark.tsx`, codicon `verified-filled`).
struct CatalogMark: View {
    var body: some View {
        Image(systemName: "checkmark.seal.fill")
            .font(.system(size: Theme.IconSize.xs * 0.85))
            .foregroundStyle(Theme.Text.quaternary)
            .accessibilityLabel("In the Hermes catalog")
    }
}

enum ConnectorStyle {
    /// `STATE_DOT`.
    static func dot(_ state: ConnectorState) -> Color {
        switch state {
        case .broken: return Theme.Semantic.red
        case .connected: return Theme.Semantic.green
        case .connecting: return Theme.Semantic.yellow
        case .expired: return Theme.Semantic.orange
        case .available, .off, .unknown: return Theme.Text.quaternary
        }
    }

    /// `REASON_TONE`.
    static func reasonTone(_ state: ConnectorState) -> Color {
        switch state {
        case .broken: return Theme.Semantic.red
        case .expired: return Theme.Semantic.orange
        default: return Theme.Text.secondary
        }
    }
}

enum ConnectorCopy {
    static let removeBody = "The entry leaves the MCP servers in the host's config. Nothing else is deleted."
}
