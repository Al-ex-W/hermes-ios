import Foundation

// The Connectors directory's model (`app/capabilities/connectors/derive.ts`, `derive-page.ts`, `data/join.ts`,
// `connector-kind.ts`), for the servers Hermes runs on its host and the catalog entries it could install. The
// desktop's managed (Nous account) apps aren't part of this page on the phone.

enum ConnectorState: String, Hashable {
    case available, broken, connected, connecting, expired, off, unknown

    /// `STATE_RANK`: broken connections first, the turned-off last.
    var rank: Int {
        switch self {
        case .broken: return 0
        case .expired: return 1
        case .unknown: return 2
        case .connecting: return 3
        case .connected: return 4
        case .available: return 5
        case .off: return 6
        }
    }
}

enum ConnectorVerb: String, Hashable {
    case authenticate, install, openLogs

    var label: String {
        switch self {
        case .authenticate: return "Authenticate"
        case .install: return "Install"
        case .openLogs: return "Open logs"
        }
    }
}

enum ConnectorReason: String, Hashable {
    case serverError, serverNeedsAuth

    var text: String {
        switch self {
        case .serverError: return "The server refused the connection."
        case .serverNeedsAuth: return "Sign in to let this server answer."
        }
    }
}

/// The tool count a connected server's card shows instead of its state word.
struct ConnectorFact: Hashable {
    enum Key: Hashable { case tools, toolsOn, toolsSomeOn }
    var key: Key
    var count: Int
    var on = 0

    var text: String {
        switch key {
        case .tools: return Self.tools(count)
        case .toolsOn: return "\(Self.tools(count)) on"
        case .toolsSomeOn: return "\(count) tools, \(on) on"
        }
    }

    static func tools(_ count: Int) -> String { "\(count) tool\(count == 1 ? "" : "s")" }
}

/// One server (or installable catalog entry) on the page.
struct ConnectorCard: Identifiable, Hashable {
    /// `local:<slug>`, the card's identity across reloads.
    var key: String
    /// The server's config key, or the catalog entry's name.
    var slug: String
    var name: String
    var description: String?
    var inCatalog: Bool
    var plugin: String?
    var state: ConnectorState
    var reason: ConnectorReason?
    var verb: ConnectorVerb?
    var fact: ConnectorFact?
    /// A configured server (false: a catalog entry that isn't installed).
    var installed: Bool
    var serverEnabled: Bool
    var serverName: String?
    var entryName: String?
    var needsEnv: Bool
    var target: String?
    var unused: Bool

    var id: String { key }

    /// The state word (`LOCAL_WORDS` / `localWord`).
    var stateWord: String {
        if reason == .serverNeedsAuth { return "Needs authentication" }
        switch state {
        case .available: return "Available"
        case .broken, .expired: return "Error"
        case .connected: return unused ? "On, unused" : "On"
        case .connecting, .unknown: return "Connecting…"
        case .off: return "Off"
        }
    }

    /// What the card's lane says: the tool count while connected, else the state word.
    var stateLabel: String { fact?.text ?? stateWord }

    /// `connectorKindWord` for a server on the host.
    var kindWord: String {
        if let plugin { return "MCP · Plugin \(plugin)" }
        return inCatalog ? "MCP · Catalog" : "MCP · Custom"
    }

    /// `showsCatalogMark`.
    var showsCatalogMark: Bool { inCatalog && plugin == nil }

    /// The switch belongs to a configured server Hermes owns (a plugin's servers are the plugin's).
    var hasSwitch: Bool { installed && plugin == nil }
}

/// One configured server joined with its catalog entry, probe and usage (`LocalServerInput`).
struct ConnectorServerInput: Hashable {
    var server: MCPServerSummary
    var status: MCPServerStatus
    var toolsOn: Int?
    var toolsTotal: Int?
    var uses: Int?
    var catalog: MCPCatalogEntry?
}

enum ConnectorCards {
    static func key(_ slug: String) -> String { "local:\(slug)" }

    /// `joinLocalServers`: each configured server with what the probes and usage know of it.
    static func inputs(servers: [MCPServerSummary], catalog: [MCPCatalogEntry], probes: [String: MCPTestResult],
                       probing: Set<String>, calls: [String: Int]?) -> [ConnectorServerInput] {
        servers.map { server in
            let probe = probes[server.name]
            let tools = probe.flatMap { $0.ok ? $0.tools.map(\.name) : nil }
            return ConnectorServerInput(
                server: server,
                status: MCPServerStatus.of(enabled: server.enabled, probing: probing.contains(server.name), probe: probe),
                toolsOn: tools.map { server.tools.enabledCount($0) },
                toolsTotal: tools?.count,
                uses: calls.map { MCPCost.uses(server.name, calls: $0) },
                catalog: catalog.first { $0.name == server.name })
        }
    }

    /// `localWay` + `mergeCard` for a configured server.
    static func card(_ input: ConnectorServerInput) -> ConnectorCard {
        let server = input.server
        let status: MCPServerStatus = server.enabled ? input.status : .off
        var state: ConnectorState
        var reason: ConnectorReason?
        var verb: ConnectorVerb?
        switch status {
        case .error: state = .broken; reason = .serverError; verb = .openLogs
        case .needsAuth:
            state = .broken
            reason = .serverNeedsAuth
            verb = MCPServerStatus.canAuthenticate(server, status: status) ? .authenticate : .openLogs
        case .off: state = .off
        case .ok: state = .connected
        case .probing, .unknown: state = .connecting
        }
        let unused = input.uses.map { $0 == 0 } ?? false
        var fact: ConnectorFact?
        if state == .connected, !unused, let total = input.toolsTotal {
            if let on = input.toolsOn {
                fact = on < total ? ConnectorFact(key: .toolsSomeOn, count: total, on: on) : ConnectorFact(key: .toolsOn, count: on)
            } else {
                fact = ConnectorFact(key: .tools, count: total)
            }
        }
        // A plugin's server is titled after the part past `<plugin>__`.
        let titleSource: String
        if server.isPlugin, let split = server.name.range(of: "__") {
            titleSource = String(server.name[split.upperBound...])
        } else {
            titleSource = server.name
        }
        return ConnectorCard(
            key: key(server.name), slug: server.name, name: MCPText.title(titleSource),
            description: MCPText.nonBlank(input.catalog?.description), inCatalog: input.catalog != nil,
            plugin: server.plugin, state: state, reason: reason, verb: verb, fact: fact, installed: true,
            serverEnabled: server.enabled, serverName: server.name, entryName: nil, needsEnv: false,
            target: MCPText.nonBlank(server.target), unused: unused && state == .connected)
    }

    /// `bundledWay`: a catalog entry that isn't installed.
    static func card(_ entry: MCPCatalogEntry) -> ConnectorCard {
        ConnectorCard(
            key: key(entry.name), slug: entry.name, name: MCPText.title(entry.name),
            description: MCPText.nonBlank(entry.description), inCatalog: true, plugin: nil, state: .available,
            reason: nil, verb: .install, fact: nil, installed: false, serverEnabled: false, serverName: nil,
            entryName: entry.name, needsEnv: entry.needsEnv, target: nil, unused: false)
    }

    /// `deriveCards`: every configured server, plus each catalog entry no server already stands for (same name or
    /// same connector).
    static func cards(inputs: [ConnectorServerInput], catalog: [MCPCatalogEntry]) -> [ConnectorCard] {
        var cards = inputs.map(card)
        let names = Set(inputs.map(\.server.name))
        let slugs = Set(inputs.compactMap { $0.catalog?.connectorSlug })
        for entry in catalog where !entry.installed && !names.contains(entry.name) {
            if let slug = entry.connectorSlug, slugs.contains(slug) { continue }
            cards.append(card(entry))
        }
        return cards
    }
}

// MARK: - Page

enum ConnectorGroup: String, CaseIterable, Hashable, Identifiable {
    /// Servers on the Hermes host (`residencyLocal`; "On this device" on the desktop, where the host is the machine).
    case host
    case available

    var id: String { rawValue }

    var title: String {
        switch self {
        case .host: return "On the Hermes host"
        case .available: return "Available"
        }
    }
}

enum ConnectorSegment: Hashable, Identifiable {
    case all
    case group(ConnectorGroup)

    var id: String {
        switch self {
        case .all: return "all"
        case let .group(group): return group.rawValue
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case let .group(group): return group.title
        }
    }
}

/// What the directory shows for a filter (`derivePage`).
struct ConnectorPage: Hashable {
    struct Section: Hashable, Identifiable {
        var group: ConnectorGroup
        var cards: [ConnectorCard]
        var id: ConnectorGroup { group }
    }

    struct SegmentCount: Hashable {
        var segment: ConnectorSegment
        var count: Int
    }

    var sections: [Section]
    /// Every segment with its count, `All` first; empty when nothing matches.
    var segments: [SegmentCount]
    /// The segment shown: the chosen one, or `All` when it has no match.
    var segment: ConnectorSegment
    /// Matches the chosen segment hides.
    var hiddenMatches: Int

    /// The segmented control earns its place with two or more groups.
    var showsSegments: Bool { segments.count > 2 }

    static func group(of card: ConnectorCard) -> ConnectorGroup {
        card.state == .available ? .available : .host
    }

    static func matches(_ card: ConnectorCard, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty || card.slug.lowercased().contains(needle) || card.name.lowercased().contains(needle)
    }

    init(cards: [ConnectorCard], query: String, segment chosen: ConnectorSegment) {
        let matches = cards.filter { Self.matches($0, query: query) }
        let grouped = Dictionary(grouping: matches, by: Self.group)
        let all = ConnectorGroup.allCases.compactMap { group -> Section? in
            guard let cards = grouped[group], !cards.isEmpty else { return nil }
            return Section(group: group, cards: cards.sorted {
                $0.state.rank != $1.state.rank ? $0.state.rank < $1.state.rank
                    : $0.name.localizedStandardCompare($1.name) == .orderedAscending
            })
        }
        segments = matches.isEmpty ? [] : [SegmentCount(segment: .all, count: matches.count)]
            + all.map { SegmentCount(segment: .group($0.group), count: $0.cards.count) }
        segment = segments.contains { $0.segment == chosen } ? chosen : .all
        if case let .group(group) = segment {
            sections = all.filter { $0.group == group }
        } else {
            sections = all
        }
        let shown = sections.reduce(0) { $0 + $1.cards.count }
        let blank = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        hiddenMatches = segment == .all || blank ? 0 : matches.count - shown
    }
}

// MARK: - Tools editor

/// The per-tool switches of one server (`use-tools-editor.ts`): an edited set of disabled tools against the saved
/// one, written as the server's `tools.include` / `tools.exclude`.
struct ConnectorToolsEditor: Equatable {
    private(set) var disabled: [String]
    private(set) var baseline: [String]

    init(saved: [String] = []) {
        disabled = saved
        baseline = saved
    }

    /// The saved set changed on the host (a reload, another device): start over from it.
    mutating func reset(saved: [String]) {
        disabled = saved
        baseline = saved
    }

    var dirty: Bool { Set(disabled) != Set(baseline) }

    /// `editorCounts`: tools this edit turns off, and tools it turns back on.
    var counts: (off: Int, backOn: Int) {
        let before = Set(baseline), after = Set(disabled)
        return (disabled.filter { !before.contains($0) }.count, baseline.filter { !after.contains($0) }.count)
    }

    /// `footerDirty`.
    var footer: String {
        let (off, backOn) = counts
        return "\(ConnectorFact.tools(off)) off, \(backOn == 0 ? "none" : String(backOn)) back on"
    }

    func isOn(_ tool: String) -> Bool { !disabled.contains(tool) }

    mutating func toggle(_ tool: String) {
        if let index = disabled.firstIndex(of: tool) { disabled.remove(at: index) } else { disabled.append(tool) }
    }

    /// The summary's one switch (every MCP tool shares the unclassified facet): all on, or all off.
    mutating func setAll(_ on: Bool, tools: [String]) {
        let without = disabled.filter { !tools.contains($0) }
        disabled = on ? without : without + tools
    }

    mutating func discard() { disabled = baseline }

    mutating func markSaved() { baseline = disabled }

    /// The summary row: how many are on, and the switch's state.
    func summary(_ tools: [String]) -> (on: Int, total: Int, label: String, switchOn: Bool) {
        let on = tools.filter(isOn).count
        let label = on == tools.count ? "all on" : on == 0 ? "off" : "\(on) of \(tools.count) on"
        return (on, tools.count, label, on > 0)
    }

    /// The tools the saved filter turns off, among the ones a probe found.
    static func savedDisabled(_ filter: MCPToolFilter, discovered: [String]) -> [String] {
        discovered.filter { !filter.isEnabled($0) }
    }
}

enum ConnectorToolText {
    /// `toolDisplayName`: `get_issue` → "Get issue", `listPullRequests` → "List Pull Requests".
    static func displayName(_ slug: String) -> String {
        var spaced = ""
        var previous: Character?
        for character in slug {
            if character.isUppercase, let previous, previous.isLowercase || previous.isNumber { spaced.append(" ") }
            spaced.append(character)
            previous = character
        }
        let words = spaced.replacingOccurrences(of: #"[_.\-/]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard let first = words.first else { return words }
        return first.uppercased() + words.dropFirst()
    }

    /// `capabilitySummary`: "12 tools, 2 prompts enabled".
    static func capabilities(tools: Int, prompts: Int, resources: Int) -> String {
        var parts = ["\(tools) tools"]
        if prompts > 0 { parts.append("\(prompts) prompts") }
        if resources > 0 { parts.append("\(resources) resources") }
        return parts.joined(separator: ", ") + " enabled"
    }
}

// MARK: - OAuth

/// The phone's side of a dashboard MCP OAuth flow (`completeMcpDesktopOAuth`, adapted to a remote host): the
/// host runs the flow and catches the provider's redirect on its own address; the phone opens the authorization
/// URL in a browser sheet and polls until the host has the token. Pure, so every transition is testable; the
/// screen runs the effects.
struct MCPOAuthMachine: Equatable {
    enum Phase: Equatable {
        case idle
        case starting
        /// The browser is (or was) open on `url`; polling the flow.
        case waiting(flowID: String, url: URL)
        case approved(tools: [MCPProbedTool])
        case failed(String)
        /// The provider would send the browser back to `host`, a loopback address the phone can't reach.
        case unreachable(host: String)
        case cancelled
    }

    enum Effect: Equatable {
        case open(URL)
        case poll(after: TimeInterval)
        case cancel(flowID: String)
        case closeBrowser
    }

    static let timeout: TimeInterval = 360
    static let pollInterval: TimeInterval = 1.5
    static let maxPollFailures = 3

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var pollFailures = 0

    var isRunning: Bool {
        switch phase {
        case .starting, .waiting: return true
        default: return false
        }
    }

    var flowID: String? {
        if case let .waiting(flowID, _) = phase { return flowID }
        return nil
    }

    mutating func start(at now: Date) {
        phase = .starting
        startedAt = now
        pollFailures = 0
    }

    /// `POST /api/mcp/servers/{name}/auth` answered.
    mutating func started(_ flow: MCPOAuthFlow, dashboard: URL) -> [Effect] {
        guard phase == .starting else {
            // Stopped while the host was starting: release the flow it made.
            return [.cancel(flowID: flow.flowID)]
        }
        switch flow.status {
        case .approved:
            phase = .approved(tools: flow.tools)
            return []
        case .error:
            phase = .failed(flow.error ?? "OAuth authorization failed")
            return [.cancel(flowID: flow.flowID)]
        default:
            guard let url = flow.authorizationURL else {
                phase = .failed(flow.error ?? "The server didn't provide an authorization URL.")
                return [.cancel(flowID: flow.flowID)]
            }
            if flow.callbackUnreachable(from: dashboard) {
                phase = .unreachable(host: flow.redirectURI?.host ?? "")
                return [.cancel(flowID: flow.flowID)]
            }
            phase = .waiting(flowID: flow.flowID, url: url)
            return [.open(url), .poll(after: Self.pollInterval)]
        }
    }

    mutating func startFailed(_ message: String) {
        guard phase == .starting else { return }
        phase = .failed(message)
    }

    /// A poll answered; nil is a flow the host no longer knows (expired or restarted).
    mutating func polled(_ flow: MCPOAuthFlow?, at now: Date) -> [Effect] {
        guard case let .waiting(flowID, url) = phase, flow == nil || flow?.flowID == flowID else { return [] }
        pollFailures = 0
        guard let flow else {
            phase = .failed("The sign-in expired. Start it again.")
            return [.closeBrowser]
        }
        switch flow.status {
        case .approved:
            phase = .approved(tools: flow.tools)
            return [.closeBrowser]
        case .error:
            phase = .failed(flow.error ?? "OAuth authorization failed")
            return [.closeBrowser, .cancel(flowID: flowID)]
        default:
            if timedOut(now) { return fail("Timed out waiting for the sign-in.", flowID) }
            // A re-minted attempt has a new URL: "Open the link again" opens that one.
            if let fresh = flow.authorizationURL, fresh != url { phase = .waiting(flowID: flowID, url: fresh) }
            return [.poll(after: Self.pollInterval)]
        }
    }

    /// A poll didn't reach the host; three in a row end the wait.
    mutating func pollFailed(_ message: String, at now: Date) -> [Effect] {
        guard case let .waiting(flowID, _) = phase else { return [] }
        pollFailures += 1
        if pollFailures >= Self.maxPollFailures { return fail(message, flowID) }
        if timedOut(now) { return fail("Timed out waiting for the sign-in.", flowID) }
        return [.poll(after: 1)]
    }

    /// "Stop waiting", or the page went away.
    mutating func stop() -> [Effect] {
        switch phase {
        case let .waiting(flowID, _):
            phase = .cancelled
            return [.closeBrowser, .cancel(flowID: flowID)]
        case .starting:
            phase = .cancelled
            return []
        default:
            return []
        }
    }

    /// Clears a finished run (the next Authenticate starts over).
    mutating func reset() {
        guard !isRunning else { return }
        phase = .idle
        startedAt = nil
        pollFailures = 0
    }

    private func timedOut(_ now: Date) -> Bool {
        startedAt.map { now.timeIntervalSince($0) >= Self.timeout } ?? false
    }

    private mutating func fail(_ message: String, _ flowID: String) -> [Effect] {
        phase = .failed(message)
        return [.closeBrowser, .cancel(flowID: flowID)]
    }
}
