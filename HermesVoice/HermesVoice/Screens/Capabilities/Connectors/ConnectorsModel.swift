import Foundation

/// The Connectors page's state for one profile (`use-mcp-servers.ts`, `use-mcp-probes.ts`): the configured
/// servers, the catalog, a probe per server, 30-day usage, and the OAuth runs.
@MainActor
final class ConnectorsModel: ObservableObject {
    let api: MCPAPI

    /// nil until the first read answers.
    @Published private(set) var servers: [MCPServerSummary]?
    @Published private(set) var catalog: [MCPCatalogEntry] = []
    @Published private(set) var loadError: String?
    @Published private(set) var probes: [String: MCPTestResult] = [:]
    @Published private(set) var probing: Set<String> = []
    @Published private(set) var calls30d: [String: Int]?
    /// Card keys with an install or a switch in flight.
    @Published private(set) var busy: Set<String> = []
    /// OAuth runs by server name.
    @Published private(set) var auth: [String: MCPOAuthMachine] = [:]
    /// The authorization page open in the browser sheet, and whose run it belongs to.
    @Published var browser: WebPage?
    @Published var failure: String?

    private var browserOwner: String?
    private var polls: [String: Task<Void, Never>] = [:]

    /// A probe connects (or spawns) the server for real, so a fresh one is reused across visits (`probeCache`).
    private static var probeCache: [String: (at: Date, result: MCPTestResult)] = [:]
    static let probeTTL: TimeInterval = 5 * 60

    init(api: MCPAPI) {
        self.api = api
    }

    var dashboard: URL { api.transport.dashboardBase }

    // MARK: Derived

    var inputs: [ConnectorServerInput] {
        ConnectorCards.inputs(servers: servers ?? [], catalog: catalog, probes: probes, probing: probing, calls: calls30d)
    }

    var cards: [ConnectorCard] {
        guard servers != nil else { return [] }
        return ConnectorCards.cards(inputs: inputs, catalog: catalog)
    }

    func card(_ key: String) -> ConnectorCard? { cards.first { $0.key == key } }

    func server(_ name: String?) -> MCPServerSummary? {
        guard let name else { return nil }
        return servers?.first { $0.name == name }
    }

    func entry(_ name: String?) -> MCPCatalogEntry? {
        guard let name else { return nil }
        return catalog.first { $0.name == name }
    }

    /// Every name a new server can't take.
    var names: [String] { servers?.map(\.name) ?? [] }

    // MARK: Loading

    /// Reads the servers, the catalog and usage; then probes every enabled server without a fresh probe
    /// (`force`: every enabled server, as a pull-to-refresh asks).
    func load(force: Bool = false) async {
        async let catalogRead = try? api.catalog()
        async let callsRead = api.toolCalls30d()
        await reloadServers()
        if let catalog = await catalogRead { self.catalog = catalog.entries }
        if let calls = await callsRead { calls30d = calls }
        probeAll(force: force)
    }

    func reloadServers() async {
        do {
            servers = try await api.servers()
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if servers == nil { loadError = error.dashboardMessage } else { failure = error.dashboardMessage }
        }
    }

    private func cacheKey(_ server: MCPServerSummary) -> String {
        "\(api.profile ?? "")::\(server.name)::\(server.fingerprint)"
    }

    private func probeAll(force: Bool) {
        for server in servers ?? [] where server.enabled {
            if !force, let cached = Self.probeCache[cacheKey(server)], Date().timeIntervalSince(cached.at) < Self.probeTTL {
                probes[server.name] = cached.result
                continue
            }
            if !force, probes[server.name] != nil { continue }
            Task { await probe(server.name) }
        }
    }

    /// `POST …/test`; a failed call reads as a failed probe.
    func probe(_ name: String) async {
        guard !probing.contains(name) else { return }
        probing.insert(name)
        defer { probing.remove(name) }
        let result: MCPTestResult
        do {
            result = try await api.test(name)
        } catch {
            guard !error.isCancellation else { return }
            result = MCPTestResult(ok: false, error: error.dashboardMessage)
        }
        probes[name] = result
        if let server = server(name) { Self.probeCache[cacheKey(server)] = (Date(), result) }
    }

    // MARK: Writes

    func setEnabled(_ name: String, _ enabled: Bool) async {
        guard let index = servers?.firstIndex(where: { $0.name == name }) else { return }
        let key = ConnectorCards.key(name)
        busy.insert(key)
        defer { busy.remove(key) }
        servers?[index].enabled = enabled
        do {
            try await api.setEnabled(name, enabled)
            if enabled { await probe(name) }
        } catch {
            if let index = servers?.firstIndex(where: { $0.name == name }) { servers?[index].enabled = !enabled }
            failure = "\(enabled ? "Couldn't turn on" : "Couldn't turn off") \(name). \(error.dashboardMessage)"
        }
    }

    /// Removes the server from the profile's config. Answers whether it went.
    func remove(_ name: String) async -> Bool {
        do {
            try await api.remove(name)
            probes[name] = nil
            servers?.removeAll { $0.name == name }
            await reloadServers()
            if let catalog = try? await api.catalog() { self.catalog = catalog.entries }
            return true
        } catch {
            failure = "Remove failed. \(error.dashboardMessage)"
            return false
        }
    }

    /// Installs a catalog entry (declared values go to the host's `.env`); a git-bootstrap entry runs in the
    /// background and is polled until it exits (`installBundledEntry`).
    func install(_ entry: MCPCatalogEntry, env: [String: String]) async -> Bool {
        let key = ConnectorCards.key(entry.name)
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let result = try await api.install(entry, env: env)
            if result.background, let action = result.action {
                let deadline = Date().addingTimeInterval(10 * 60)
                while true {
                    try await Task.sleep(for: .seconds(1.5))
                    let status = try await api.actionStatus(action)
                    if !status.running {
                        if let code = status.exitCode, code != 0 { throw DashboardError.rpc("Failed to install \(entry.name).") }
                        break
                    }
                    if Date() > deadline { throw DashboardError.rpc("Installing \(entry.name) is taking too long. Check the host.") }
                }
            }
            await reloadServers()
            if let catalog = try? await api.catalog() { self.catalog = catalog.entries }
            if server(entry.name)?.enabled == true { await probe(entry.name) }
            return true
        } catch {
            guard !error.isCancellation else { return false }
            failure = "Failed to install \(entry.name). \(error.dashboardMessage)"
            return false
        }
    }

    /// Adds a server, then probes it. Throws for the form to show.
    func create(_ draft: MCPServerDraft) async throws {
        do {
            try await api.create(draft)
        } catch {
            // The create route may have saved the server before a follow-up failed: show what is there now.
            await reloadServers()
            throw error
        }
        await reloadServers()
        await probe(MCPServerDraft.trim(draft.name))
    }

    /// Saves the edit form, then probes the server again.
    func update(_ name: String, draft: MCPServerDraft) async throws {
        try await api.update(name, draft: draft)
        await reloadServers()
        if server(name)?.enabled == true { await probe(name) }
    }

    /// The edit form for a saved server: values arrive masked, so no secret stays on the phone.
    func editDraft(_ name: String) async throws -> MCPServerDraft {
        guard let entry = try await api.storedServers()[name]?.objectValue else {
            throw DashboardError.rpc("Server ‘\(name)’ is no longer configured.")
        }
        return MCPServerDraft(editing: name, entry: entry)
    }

    /// Writes the server's tool switches. Answers whether they were saved.
    func saveTools(_ name: String, disabled: [String], discovered: [String]) async -> Bool {
        do {
            try await api.setDisabledTools(name, disabled: disabled, discovered: discovered)
            await reloadServers()
            return true
        } catch {
            failure = "Those tool rules were not saved. \(error.dashboardMessage)"
            return false
        }
    }

    // MARK: OAuth

    func authenticate(_ name: String) {
        guard auth[name]?.isRunning != true else { return }
        var machine = MCPOAuthMachine()
        machine.start(at: Date())
        auth[name] = machine
        Task {
            do {
                let flow = try await api.startOAuth(name)
                let dashboard = dashboard
                step(name) { $0.started(flow, dashboard: dashboard) }
            } catch {
                let message = error.dashboardMessage
                step(name) { machine in
                    machine.startFailed(message)
                    return []
                }
            }
        }
    }

    /// "Stop waiting", or the detail closed.
    func stopAuth(_ name: String) {
        polls[name]?.cancel()
        polls[name] = nil
        step(name) { $0.stop() }
    }

    /// "Open the link again": the flow's current authorization URL.
    func reopenAuth(_ name: String) {
        guard case let .waiting(_, url)? = auth[name]?.phase else { return }
        browserOwner = name
        browser = WebPage(url: url)
    }

    /// Clears a finished run's message.
    func dismissAuth(_ name: String) {
        auth[name]?.reset()
        if auth[name]?.phase == .idle { auth[name] = nil }
    }

    private func step(_ name: String, _ transition: (inout MCPOAuthMachine) -> [MCPOAuthMachine.Effect]) {
        guard var machine = auth[name] else { return }
        let wasApproved: Bool
        if case .approved = machine.phase { wasApproved = true } else { wasApproved = false }
        let effects = transition(&machine)
        auth[name] = machine
        for effect in effects { perform(effect, for: name) }
        if !wasApproved, case let .approved(tools) = machine.phase { finishAuth(name, tools: tools) }
    }

    private func perform(_ effect: MCPOAuthMachine.Effect, for name: String) {
        switch effect {
        case let .open(url):
            browserOwner = name
            browser = WebPage(url: url)
        case .closeBrowser:
            if browserOwner == name {
                browser = nil
                browserOwner = nil
            }
        case let .cancel(flowID):
            let api = api
            Task { await api.cancelOAuth(flowID) }
        case let .poll(delay):
            guard let flowID = auth[name]?.flowID else { return }
            polls[name]?.cancel()
            polls[name] = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, let self else { return }
                do {
                    let flow = try await self.api.pollOAuth(flowID)
                    guard !Task.isCancelled else { return }
                    self.step(name) { $0.polled(flow, at: Date()) }
                } catch {
                    guard !Task.isCancelled else { return }
                    self.step(name) { $0.pollFailed(error.dashboardMessage, at: Date()) }
                }
            }
        }
    }

    /// The host has the token and probed the server: show its tools, then read the list again.
    private func finishAuth(_ name: String, tools: [MCPProbedTool]) {
        polls[name] = nil
        let result = MCPTestResult(ok: true, tools: tools)
        probes[name] = result
        Task {
            await reloadServers()
            if let server = server(name) { Self.probeCache[cacheKey(server)] = (Date(), result) }
        }
    }

    /// The page went away: release every flow still waiting on the host.
    func stopAllAuth() {
        for (name, machine) in auth where machine.isRunning { stopAuth(name) }
    }
}
