import Foundation

/// The Connectors page's state for one profile (`use-mcp-servers.ts`, `use-mcp-probes.ts`, `use-hosted-connectors`):
/// the managed apps of the profile's Nous account, the configured servers, the catalog, a probe per server, 30-day
/// usage, and the OAuth and connect runs.
@MainActor
final class ConnectorsModel: ObservableObject {
    let api: MCPAPI
    /// The managed apps' RPCs; nil while the gateway socket isn't up.
    let hostedAPI: HostedConnectorsAPI?

    @Published private(set) var hostedPhase: HostedPhase = .loading
    @Published private(set) var hosted: [HostedConnector] = []
    /// The member's policy layer, for the "Hermes can use" switch.
    @Published private(set) var hostedPolicy = HostedPolicy()
    /// Open sign-ins by app slug.
    @Published private(set) var operations: [String: HostedOperation] = [:]
    private var operationPolls: [String: Task<Void, Never>] = [:]

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

    /// `reload.mcp`: Hermes tears down and rediscovers the MCP servers of every live session, so a change made here
    /// reaches running chats too (the desktop's `silentReload` after each persist). nil while the gateway socket
    /// isn't up: new chats still pick the change up.
    let reloadSessions: (() async throws -> Void)?
    /// A reload is going; another change waits for it and reloads once more.
    private var reloading: Task<Void, Never>?
    private var reloadAgain = false

    init(api: MCPAPI, hostedAPI: HostedConnectorsAPI? = nil, reloadSessions: (() async throws -> Void)? = nil) {
        self.api = api
        self.hostedAPI = hostedAPI
        self.reloadSessions = reloadSessions
        if hostedAPI == nil { hostedPhase = .unavailable }
    }

    /// Whether changes reach running chats on their own.
    var reloadsLiveSessions: Bool { reloadSessions != nil }

    /// Reloads the live sessions' MCP servers after a write; changes made while one runs share one more reload.
    func reloadLiveSessions() {
        guard let reloadSessions else { return }
        guard reloading == nil else {
            reloadAgain = true
            return
        }
        reloading = Task { [weak self] in
            repeat {
                self?.reloadAgain = false
                do {
                    try await reloadSessions()
                } catch {
                    guard !error.isCancellation else { break }
                    self?.failure = "MCP reload failed. Running chats keep their servers until they reload; new chats " +
                        "get the change. \(error.dashboardMessage)"
                }
            } while self?.reloadAgain == true
            self?.reloading = nil
        }
    }

    /// Waits for the reload in flight (tests).
    func settleReload() async {
        while let reloading { await reloading.value }
    }

    var dashboard: URL { api.transport.dashboardBase }

    // MARK: Derived

    var inputs: [ConnectorServerInput] {
        ConnectorCards.inputs(servers: servers ?? [], catalog: catalog, probes: probes, probing: probing, calls: calls30d)
    }

    var cards: [ConnectorCard] {
        guard servers != nil else { return [] }
        return ConnectorCards.cards(hosted: hostedPhase == .ready ? hosted : [], inputs: inputs, catalog: catalog)
    }

    func hostedApp(_ slug: String?) -> HostedConnector? {
        guard let slug else { return nil }
        return hosted.first { $0.slug == slug }
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
        async let hostedRead: Void = reloadHosted()
        await reloadServers()
        if let catalog = await catalogRead { self.catalog = catalog.entries }
        if let calls = await callsRead { calls30d = calls }
        await hostedRead
        probeAll(force: force)
    }

    // MARK: Managed apps

    /// Reads the managed apps: list, catalog, accounts and the member's rules side by side (`useHostedConnectors`).
    /// Not signed in to Nous, or no managed apps for the account, is a state of the page, not an error.
    func reloadHosted() async {
        guard let hostedAPI else { return }
        do {
            async let listRead = hostedAPI.list()
            async let catalogRead = hostedAPI.catalog()
            async let accountsRead = hostedAPI.accounts()
            async let policyRead = hostedAPI.policy()
            let list = try await listRead
            guard list.available else {
                hosted = []
                hostedPhase = .unavailable
                return
            }
            let catalog = try await catalogRead
            let accounts = (try? await accountsRead) ?? []
            // Without a Nous sign-in the list and catalog still answer (empty, public); the member's rules say so.
            var policy: HostedPolicy?
            do {
                policy = try await policyRead
            } catch where HostedRefusal.needsSignIn(error) {
                throw error
            } catch {
                policy = nil
            }
            hostedPolicy = policy ?? HostedPolicy()
            hosted = HostedConnector.join(list: list.rows, catalog: catalog, accounts: accounts, policy: hostedPolicy,
                                          rulesReadable: policy != nil)
            hostedPhase = .ready
        } catch {
            guard !error.isCancellation else { return }
            if HostedRefusal.needsSignIn(error) {
                hosted = []
                hostedPhase = .signedOut
            } else if HostedRefusal.unavailable(error) {
                hosted = []
                hostedPhase = .unavailable
            } else {
                hostedPhase = .failed(error.dashboardMessage)
            }
        }
    }

    /// Starts a sign-in for a managed app (or repairs one), opens its link, and follows the operation until it
    /// settles; the browser closing wakes it.
    func connectHosted(_ slug: String, reconnect: Bool) async {
        guard let hostedAPI else { return }
        let key = ConnectorCards.hostedKey(slug)
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let operation = try await hostedAPI.connect(slug, reconnect: reconnect)
            operations[slug] = operation
            if let url = operation.target(slug)?.connectURL {
                browserOwner = key
                browser = WebPage(url: url)
            }
            followOperation(slug)
            await reloadHosted()
        } catch {
            guard !error.isCancellation else { return }
            failure = "Couldn't connect \(hostedApp(slug)?.name ?? slug). \(error.dashboardMessage)"
        }
    }

    /// Polls an open sign-in every two seconds until it settles or its app connects or fails.
    private func followOperation(_ slug: String) {
        operationPolls[slug]?.cancel()
        operationPolls[slug] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled, let open = self.operations[slug], let hostedAPI = self.hostedAPI else { return }
                guard let next = try? await hostedAPI.operation(open.opID) else { continue }
                guard !Task.isCancelled else { return }
                self.operations[slug] = next
                let target = next.target(slug)
                if next.settled || target?.connected == true || target?.failed == true {
                    self.operationSettled(slug, next)
                    return
                }
                if let deadline = next.deadline, Date() > deadline.addingTimeInterval(5) {
                    self.operationSettled(slug, next)
                    return
                }
            }
        }
    }

    private func operationSettled(_ slug: String, _ operation: HostedOperation) {
        operationPolls[slug] = nil
        if browserOwner == ConnectorCards.hostedKey(slug) {
            browser = nil
            browserOwner = nil
        }
        let target = operation.target(slug)
        if target?.connected == true {
            operations[slug] = nil
        } else if target?.failed == true {
            failure = "The sign-in did not finish.\(target?.detail.map { " \($0)" } ?? "")"
        }
        Task { await reloadHosted() }
    }

    /// The browser sheet closed: ask the operation now instead of at the next tick (`connectors.operation.wake`).
    func browserClosed() {
        guard let owner = browserOwner, owner.hasPrefix("hosted:") else { return }
        let slug = String(owner.dropFirst("hosted:".count))
        browserOwner = nil
        guard let opID = operations[slug]?.opID, let hostedAPI else { return }
        Task { try? await hostedAPI.wake(opID) }
    }

    /// "Stop waiting": settles the open sign-in as the user's Continue; a pending account it left behind goes.
    func stopWaiting(_ slug: String) async {
        guard let hostedAPI else { return }
        operationPolls[slug]?.cancel()
        operationPolls[slug] = nil
        if browserOwner == ConnectorCards.hostedKey(slug) {
            browser = nil
            browserOwner = nil
        }
        do {
            if let open = operations.removeValue(forKey: slug) {
                try await hostedAPI.giveUp(open.opID)
                for target in open.targets where !target.connected {
                    if let id = target.connectionID { try? await hostedAPI.removeAccount(id) }
                }
            } else if let pending = hostedApp(slug)?.accounts.first(where: { $0.status == "pending" }) {
                try await hostedAPI.removeAccount(pending.connectionID)
            }
        } catch {
            guard !error.isCancellation else { return }
            failure = "That change was not saved. \(error.dashboardMessage)"
        }
        await reloadHosted()
    }

    /// The member's "Hermes can use <app>" switch (`connectors.policy.set`). A stale revision reads the rules again.
    func setHostedEnabled(_ slug: String, _ enabled: Bool) async {
        guard let hostedAPI else { return }
        let key = ConnectorCards.hostedKey(slug)
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            var revision = hostedPolicy.member?.revision ?? ""
            if revision.isEmpty, let fresh = try? await hostedAPI.policy() {
                hostedPolicy = fresh
                revision = fresh.member?.revision ?? ""
            }
            try await hostedAPI.setEnabled(slug, enabled, revision: revision)
            reloadLiveSessions()
        } catch {
            guard !error.isCancellation else { return }
            failure = "That change was not saved. \(error.dashboardMessage)"
        }
        await reloadHosted()
    }

    /// Removes one account of a managed app (`connectors.accounts.remove`); answers whether it went.
    func disconnectHosted(_ account: HostedAccount) async -> Bool {
        guard let hostedAPI else { return false }
        let key = ConnectorCards.hostedKey(account.connector)
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await hostedAPI.removeAccount(account.connectionID)
            await reloadHosted()
            return true
        } catch {
            guard !error.isCancellation else { return false }
            failure = HostedRefusal.reason(error) == "CONNECTION_NOT_FOUND"
                ? "Hermes has no account to disconnect here. Refresh the page and try again."
                : "Nous could not remove this sign-in right now. Turn the app off with the switch instead, or try again later."
            await reloadHosted()
            return false
        }
    }

    /// A managed card's verb (`runHostedVerb`); false when the verb is a host server's.
    func runHostedVerb(_ card: ConnectorCard) -> Bool {
        guard card.residency == .hosted else { return false }
        switch card.verb {
        case .connect?: Task { await connectHosted(card.slug, reconnect: false) }
        case .reconnect?, .tryAgain?: Task { await connectHosted(card.slug, reconnect: true) }
        case .stopWaiting?: Task { await stopWaiting(card.slug) }
        case .turnBackOn?: Task { await setHostedEnabled(card.slug, true) }
        default: return false
        }
        return true
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
            reloadLiveSessions()
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
            reloadLiveSessions()
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
                // A failed status read is retried: the install keeps running on the host either way.
                var failures = 0
                while true {
                    try await Task.sleep(for: .seconds(1.5))
                    let status: (running: Bool, exitCode: Int?)
                    do {
                        status = try await api.actionStatus(action)
                        failures = 0
                    } catch {
                        if error.isCancellation { throw error }
                        failures += 1
                        if failures >= Self.statusTolerance {
                            throw CapabilityActionLost(name: action, reason: error.dashboardMessage)
                        }
                        continue
                    }
                    if !status.running {
                        if let code = status.exitCode, code != 0 { throw DashboardError.rpc("Failed to install \(entry.name).") }
                        break
                    }
                    if Date() > deadline { throw DashboardError.rpc("Installing \(entry.name) is taking too long. Check the host.") }
                }
            }
            reloadLiveSessions()
            await reloadServers()
            if let catalog = try? await api.catalog() { self.catalog = catalog.entries }
            if server(entry.name)?.enabled == true { await probe(entry.name) }
            return true
        } catch let lost as CapabilityActionLost {
            failure = "Installing \(entry.name): \(lost.localizedDescription)"
            await reloadServers()
            return false
        } catch {
            guard !error.isCancellation else { return false }
            failure = "Failed to install \(entry.name). \(error.dashboardMessage)"
            return false
        }
    }

    /// Failed status reads in a row a background install survives (as `OpsActionPoll` does).
    static let statusTolerance = 5

    /// Adds a server, then probes it. Throws for the form to show.
    func create(_ draft: MCPServerDraft) async throws {
        do {
            try await api.create(draft)
        } catch {
            // The create route may have saved the server before a follow-up failed: show what is there now.
            await reloadServers()
            throw error
        }
        reloadLiveSessions()
        await reloadServers()
        await probe(MCPServerDraft.trim(draft.name))
    }

    /// Saves the edit form, then probes the server again.
    func update(_ name: String, draft: MCPServerDraft) async throws {
        try await api.update(name, draft: draft)
        reloadLiveSessions()
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
            reloadLiveSessions()
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
        reloadLiveSessions()
        Task {
            await reloadServers()
            if let server = server(name) { Self.probeCache[cacheKey(server)] = (Date(), result) }
        }
    }

    /// The page went away: release every flow still waiting on the host, and stop following sign-ins (they go on
    /// on Nous; the page reads them again when it opens).
    func stopAllAuth() {
        for (name, machine) in auth where machine.isRunning { stopAuth(name) }
        for poll in operationPolls.values { poll.cancel() }
        operationPolls = [:]
    }
}
