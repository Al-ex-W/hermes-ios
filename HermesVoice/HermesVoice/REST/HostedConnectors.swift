import Foundation

// The Connectors page's managed (hosted) apps: the Nous account's connectors, their accounts and the member's
// switches, over the gateway's `connectors.*` RPCs for the scoped profile (`data/rpc.ts`, `data/join.ts`,
// `derive.ts` `hostedWay`). They follow the Nous account the profile is signed in with, and run on Nous, not on
// the phone or the Hermes host: everything here works against a remote Hermes. Rows decode leniently from the raw
// JSON, so an older or newer backend's rows still list.

// MARK: - Rows

/// One hosted account (`ConnectorAccountRow`).
struct HostedAccount: Identifiable, Hashable {
    var connectionID: String
    var connector: String
    /// pending, active, failed, expired, revoked, inactive.
    var status: String
    var statusReason: String?
    var label: String
    var alias: String?
    var active: Bool
    var createdAt: String
    /// An account a reconnect replaced: listed, never counted, never offered for reconnect.
    var retired: Bool

    var id: String { connectionID }

    init?(row: JSON) {
        guard let id = LenientField.text(row["connection_id"]), let connector = LenientField.text(row["connector"]) else { return nil }
        connectionID = id
        self.connector = connector
        status = LenientField.text(row["status"])?.lowercased() ?? "active"
        statusReason = LenientField.text(row["status_reason"])
        label = LenientField.text(row["label"]) ?? connector
        alias = LenientField.text(row["alias"])
        active = LenientField.bool(row["active"])
        createdAt = LenientField.text(row["created_at"]) ?? ""
        retired = LenientField.bool(row["disabled"])
    }

    /// `accountName`: the alias the user gave it, else the provider's label.
    var name: String { alias ?? label }

    /// What its row says next to the name.
    var statusWord: String {
        switch status {
        case "active": return "Connected"
        case "pending": return "Connecting"
        case "failed": return "Could not connect"
        case "expired", "revoked", "inactive": return "Access expired"
        default: return "State unknown"
        }
    }

    /// A broken sign-in that a reconnect repairs.
    var needsReconnect: Bool { ["failed", "expired", "revoked", "inactive"].contains(status) }
}

/// `connectors.list {owner: account}`: one connector's state for the account (`ConnectorRow`).
struct HostedListRow: Hashable {
    var connector: String
    var enabled: Bool
    var connected: Bool
    var connectionStatus: String?
    var statusReason: String?
    var gatewayDisabledTools: [String]

    init?(row: JSON) {
        guard let connector = LenientField.text(row["connector"]) else { return nil }
        self.connector = connector
        enabled = LenientField.optionalBool(row["enabled"]) ?? true
        connected = LenientField.bool(row["connected"])
        connectionStatus = LenientField.text(row["connection_status"])?.lowercased()
        statusReason = LenientField.text(row["status_reason"])
        gatewayDisabledTools = LenientField.strings(row["gateway_disabled_tools"])
    }
}

/// `connectors.catalog`: an app the account can connect (`ConnectorCatalogRow`).
struct HostedCatalogRow: Hashable {
    var slug: String
    var name: String
    var description: String
    var category: String

    init?(row: JSON) {
        guard let slug = LenientField.text(row["slug"]) else { return nil }
        self.slug = slug
        name = LenientField.text(row["name"]) ?? MCPText.title(slug)
        description = LenientField.text(row["description"]) ?? ""
        category = LenientField.text(row["category"]) ?? ""
    }
}

/// `connectors.policy.get`, read as the desktop reads it (`readPolicy`): the member's own layer, which the
/// "Hermes can use" switch writes, and the layers above it (organisation, role), which can only lock.
struct HostedPolicy: Hashable {
    struct Rules: Hashable {
        /// nil: every connector allowed (`unrestricted` / `deny`).
        var allowed: Set<String>?
        var denied: Set<String>
        var revision: String
        var tools: [String: [String]]

        init(layer: JSON) {
            revision = LenientField.text(layer["revision"]) ?? ""
            let body = layer["body"] as? JSON ?? [:]
            var tools: [String: [String]] = [:]
            for (slug, names) in body["tools"] as? JSON ?? [:] { tools[slug] = LenientField.strings(names) }
            self.tools = tools
            switch LenientField.text(body["mode"]) ?? "unrestricted" {
            case "deny-all":
                allowed = []
                denied = []
            case "allow":
                allowed = Set(LenientField.strings(body["connectors"]))
                denied = []
            case "deny":
                allowed = nil
                denied = Set(LenientField.strings(body["disabled_connectors"]))
            default:
                allowed = nil
                denied = []
            }
        }

        func allows(_ slug: String) -> Bool { (allowed?.contains(slug) ?? true) && !denied.contains(slug) }
    }

    var member: Rules?
    var others: [Rules] = []

    init(member: Rules? = nil, others: [Rules] = []) {
        self.member = member
        self.others = others
    }

    init(response: JSONValue) {
        let layers = (response["layers"]?.arrayValue ?? []).compactMap { $0.anyValue as? JSON }
        member = layers.first { LenientField.text($0["kind"]) == "member" }.map(Rules.init(layer:))
        others = layers.filter { LenientField.text($0["kind"]) != "member" }.map(Rules.init(layer:))
    }

    /// `memberEnables`.
    func memberEnables(_ slug: String) -> Bool { member?.allows(slug) ?? true }
    /// `orgLocks`: a layer above the member's turned it off.
    func orgLocks(_ slug: String) -> Bool { others.contains { !$0.allows(slug) } }
    /// `memberDisabledTools`.
    func memberDisabledTools(_ slug: String) -> [String] { member?.tools[slug] ?? [] }
}

/// One target of a connect operation (`ConnectionOperationTarget`): its state and, while it waits on the user,
/// the sign-in link.
struct HostedTarget: Hashable {
    var name: String
    /// pending, initiated, connected, skipped, failed, expired, not_connected.
    var state: String
    var detail: String?
    var connectURL: URL?
    var connectionID: String?

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        state = LenientField.text(row["state"])?.lowercased() ?? "pending"
        detail = LenientField.text(row["detail"])
        connectURL = LenientField.text(row["connect_url"]).flatMap(URL.init(string:))
        connectionID = LenientField.text(row["connection_id"])
    }

    var connected: Bool { state == "connected" }
    /// Nothing waits on a browser any more; the same request can mint a fresh link.
    var failed: Bool { state == "failed" || state == "expired" }
}

/// A connect operation's snapshot (`ConnectionOperationStatus` / `ConnectorsConnectResult`).
struct HostedOperation: Hashable {
    var opID: String
    var settled: Bool
    var deadline: Date?
    var targets: [HostedTarget]

    init?(response: JSONValue) {
        guard let row = response.anyValue as? JSON, let opID = LenientField.text(row["op_id"]) else { return nil }
        self.opID = opID
        settled = LenientField.bool(row["settled"])
        deadline = (row["deadline_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        targets = (row["targets"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(HostedTarget.init(row:)) }
    }

    func target(_ slug: String) -> HostedTarget? { targets.first { $0.name == slug } }
}

// MARK: - Routes

/// Why a connectors RPC was refused (`ConnectorErrorReason`, from the error's `data.reason`).
enum HostedRefusal {
    static func reason(_ error: Error) -> String? {
        (error as? GatewayRPCError)?.data?["reason"]?.stringValue
    }

    /// The profile isn't signed in to Nous.
    static func needsSignIn(_ error: Error) -> Bool { reason(error) == "NEEDS_NOUS_AUTH" }
    /// Managed apps aren't offered to this account (or the backend has none).
    static func unavailable(_ error: Error) -> Bool { reason(error) == "CONNECTORS_UNAVAILABLE" }
}

/// The hosted connector RPCs for one profile (nil: the gateway's launch profile), always as the account owner,
/// like the desktop's Connectors page.
struct HostedConnectorsAPI {
    let gateway: GatewayCalling
    let profile: String?

    /// The desktop's `CONNECTOR_TIMEOUT_MS`: Nous answers over the network.
    static let timeout: TimeInterval = 45
    static let owner: JSONValue = ["type": "account"]

    static func params(_ fields: [String: JSONValue], profile: String?) -> JSONValue {
        var object = fields
        if let profile { object["profile"] = .string(profile) }
        return .object(object)
    }

    private func call(_ method: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        try await gateway.call(method, params: Self.params(fields, profile: profile), timeout: Self.timeout)
    }

    /// `connectors.list`: whether managed apps are available, and each connector's state.
    func list() async throws -> (available: Bool, rows: [HostedListRow]) {
        let result = try await call("connectors.list", ["owner": Self.owner])
        let rows = (result["connectors"]?.arrayValue ?? []).compactMap { ($0.anyValue as? JSON).flatMap(HostedListRow.init(row:)) }
        return (result["available"]?.boolValue ?? true, rows)
    }

    func catalog() async throws -> [HostedCatalogRow] {
        let result = try await call("connectors.catalog")
        return (result["connectors"]?.arrayValue ?? []).compactMap { ($0.anyValue as? JSON).flatMap(HostedCatalogRow.init(row:)) }
    }

    func accounts() async throws -> [HostedAccount] {
        let result = try await call("connectors.accounts")
        return (result["accounts"]?.arrayValue ?? []).compactMap { ($0.anyValue as? JSON).flatMap(HostedAccount.init(row:)) }
    }

    func policy() async throws -> HostedPolicy {
        HostedPolicy(response: try await call("connectors.policy.get"))
    }

    /// The member's switch for one app (`connectors.policy.set` with a connector change). `revision` is the
    /// member layer's: a stale one is refused (`POLICY_CONFLICT`), and the page reads the rules again.
    func setEnabled(_ slug: String, _ enabled: Bool, revision: String) async throws {
        _ = try await call("connectors.policy.set", [
            "change": ["type": "connector", "connector": .string(slug), "enabled": .bool(enabled)],
            "expected_revision": .string(revision),
        ])
    }

    /// Starts (or, with `reconnect`, repairs) a sign-in: the operation carries the link to open.
    func connect(_ slug: String, reconnect: Bool) async throws -> HostedOperation {
        let result = try await call("connectors.connect", ["owner": Self.owner, "connectors": [.string(slug)],
                                                           "reconnect": .bool(reconnect)])
        guard let operation = HostedOperation(response: result) else { throw DashboardError.rpc("Hermes didn't start the sign-in.") }
        return operation
    }

    func operation(_ opID: String) async throws -> HostedOperation {
        let result = try await call("connectors.operation.status", ["owner": Self.owner, "op_id": .string(opID)])
        guard let operation = HostedOperation(response: result) else { throw DashboardError.rpc("Hermes sent no sign-in state.") }
        return operation
    }

    /// The browser came back: read the accounts now, not at the next tick.
    func wake(_ opID: String) async throws {
        _ = try await call("connectors.operation.wake", ["owner": Self.owner, "op_id": .string(opID)])
    }

    /// "Stop waiting": settles the operation as the user's Continue (`giveUp`).
    func giveUp(_ opID: String) async throws {
        _ = try await call("connection.respond", ["owner": Self.owner, "op_id": .string(opID),
                                                  "result": ["settled_by": "continue"]])
    }

    func removeAccount(_ connectionID: String) async throws {
        _ = try await call("connectors.accounts.remove", ["connection_id": .string(connectionID)])
    }
}

// MARK: - Join

/// One hosted app, joined from the list, catalog, accounts and policy (`joinHostedConnectors`).
struct HostedConnector: Hashable {
    var slug: String
    var name: String
    var description: String?
    var inCatalog: Bool
    /// Live accounts, active first, then newest; retired ones apart.
    var accounts: [HostedAccount]
    var retiredAccounts: [HostedAccount]
    var connected: Bool
    var connectionStatus: String?
    var statusReason: String?
    var enabled: Bool
    var orgLocked: Bool
    var toolsOff: Int

    /// The account the summary speaks for.
    var account: HostedAccount? { accounts.first }

    static func join(list: [HostedListRow], catalog: [HostedCatalogRow], accounts: [HostedAccount],
                     policy: HostedPolicy, rulesReadable: Bool = true) -> [HostedConnector] {
        var slugs = catalog.map(\.slug)
        for row in list where !slugs.contains(row.connector) { slugs.append(row.connector) }
        return slugs.map { slug in
            let entry = catalog.first { $0.slug == slug }
            let row = list.first { $0.connector == slug }
            let mine = accounts.filter { $0.connector == slug && !$0.retired }
                .sorted { ($0.active ? 0 : 1, $1.createdAt) < ($1.active ? 0 : 1, $0.createdAt) }
            let off = rulesReadable ? policy.memberDisabledTools(slug) : (row?.gatewayDisabledTools ?? [])
            return HostedConnector(
                slug: slug, name: MCPText.nonBlank(entry?.name) ?? MCPText.title(slug),
                description: MCPText.nonBlank(entry?.description), inCatalog: entry != nil,
                accounts: mine, retiredAccounts: accounts.filter { $0.connector == slug && $0.retired },
                connected: !mine.isEmpty || row?.connected == true,
                connectionStatus: mine.first?.status ?? row?.connectionStatus,
                statusReason: MCPText.nonBlank(mine.first?.statusReason) ?? MCPText.nonBlank(row?.statusReason),
                enabled: policy.memberEnables(slug) && row?.enabled != false,
                orgLocked: policy.orgLocks(slug), toolsOff: off.count)
        }
    }

    /// `hostedWay`: the app's state, what its button does, and why.
    var way: (state: ConnectorState, verb: ConnectorVerb?, reason: ConnectorReason?, offByOrg: Bool) {
        if orgLocked { return (.off, nil, nil, true) }
        if !enabled { return (.off, .turnBackOn, nil, false) }
        guard connected else { return (.available, .connect, nil, false) }
        switch connectionStatus ?? "active" {
        case "active": return (.connected, nil, nil, false)
        case "expired", "inactive", "revoked": return (.expired, .reconnect, .reconnect, false)
        case "failed": return (.broken, .tryAgain, .reconnect, false)
        case "pending": return (.connecting, .stopWaiting, .finishSignIn, false)
        default: return (.unknown, nil, nil, false)
        }
    }
}

/// Where the managed half of the page stands (`hostedPhase`).
enum HostedPhase: Equatable {
    case loading
    case ready
    /// The profile isn't signed in to Nous.
    case signedOut
    /// Managed apps aren't offered to this account.
    case unavailable
    case failed(String)
}
