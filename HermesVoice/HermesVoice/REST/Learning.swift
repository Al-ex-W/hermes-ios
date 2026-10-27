import Foundation

// The learning graph behind the desktop's star map ("Memory Graph", `app/starmap`): `GET /api/learning/graph`
// (`agent/learning_graph.py`) for a profile's learned skills and memory notes, and `/api/learning/node` to read,
// rewrite, archive (a skill) or delete (a memory) one of them (`agent/learning_mutations.py`). Decoders are lenient.

/// One node: a learned skill or a memory note.
struct LearningNode: Identifiable, Hashable {
    enum Kind: String, Hashable { case skill, memory }

    var id: String
    var label: String
    var kind: Kind
    /// `memory` (MEMORY.md) or `profile` (USER.md) for a memory note.
    var memorySource: String?
    /// When it was made or last changed (epoch seconds); nil when unknown.
    var timestamp: Double?
    var category: String
    var useCount: Int
    /// `active`, `stale` or `archived`.
    var state: String
    /// `agent`/`learn` for a skill Hermes learned.
    var createdBy: String?
    var pinned: Bool

    init(id: String, label: String, kind: Kind, memorySource: String? = nil, timestamp: Double? = nil,
         category: String = "", useCount: Int = 0, state: String = "active", createdBy: String? = nil, pinned: Bool = false) {
        self.id = id
        self.label = label
        self.kind = kind
        self.memorySource = memorySource
        self.timestamp = timestamp
        self.category = category
        self.useCount = useCount
        self.state = state
        self.createdBy = createdBy
        self.pinned = pinned
    }

    init?(row: JSON) {
        guard let id = LenientField.text(row["id"]) else { return nil }
        let kind = Kind(rawValue: LenientField.text(row["kind"]) ?? "") ?? .skill
        var timestamp = (row["timestamp"] as? NSNumber)?.doubleValue
        if let value = timestamp, !value.isFinite { timestamp = nil }
        self.init(id: id, label: LenientField.text(row["label"]) ?? id, kind: kind,
                  memorySource: LenientField.text(row["memorySource"]), timestamp: timestamp,
                  category: LenientField.text(row["category"]) ?? (kind == .memory ? "memory" : "general"),
                  useCount: max(0, LenientField.int(row["useCount"])), state: LenientField.text(row["state"]) ?? "active",
                  createdBy: LenientField.text(row["createdBy"]), pinned: LenientField.bool(row["pinned"]))
    }

    /// Learned by Hermes rather than written by hand.
    var learned: Bool { createdBy == "agent" || createdBy == "learn" }

    /// The tooltip's tags (`metaBadges`): date first, then what it is.
    func badges(formatter: (Double?) -> String = LearningGraph.formatDate) -> [String] {
        var out = [formatter(timestamp)]
        if kind == .memory {
            out.append(memorySource == "profile" ? "profile memory" : "memory")
        } else {
            out.append(category)
            if learned { out.append("learned") }
            if pinned { out.append("pinned") }
        }
        return out.filter { !$0.isEmpty }
    }

    /// "x12" for a used skill (`countLabel`).
    var countLabel: String? { kind == .skill && useCount > 0 ? "x\(useCount)" : nil }
}

/// The whole graph for a profile.
struct LearningGraph: Hashable {
    struct Edge: Hashable {
        var source: String
        var target: String
    }

    struct Cluster: Hashable {
        var category: String
        var count: Int
    }

    var nodes: [LearningNode] = []
    /// Declared `related_skills` links (and memory ↔ skill mentions); both ends are nodes.
    var edges: [Edge] = []
    var clusters: [Cluster] = []

    init(nodes: [LearningNode] = [], edges: [Edge] = [], clusters: [Cluster] = []) {
        self.nodes = nodes
        self.edges = edges
        self.clusters = clusters
    }

    init(response: JSON) {
        nodes = (response["nodes"] as? [JSON] ?? []).compactMap(LearningNode.init(row:))
        let ids = Set(nodes.map(\.id))
        edges = (response["edges"] as? [JSON] ?? []).compactMap { row in
            guard let source = LenientField.text(row["source"]), let target = LenientField.text(row["target"]),
                  ids.contains(source), ids.contains(target), source != target else { return nil }
            return Edge(source: source, target: target)
        }
        clusters = (response["clusters"] as? [JSON] ?? []).compactMap { row in
            LenientField.text(row["category"]).map { Cluster(category: $0, count: LenientField.int(row["count"])) }
        }
    }

    var skillCount: Int { nodes.filter { $0.kind == .skill }.count }
    var memoryCount: Int { nodes.filter { $0.kind == .memory }.count }

    /// "Mar 3, 2026"; "unknown" without a date.
    static func formatDate(_ timestamp: Double?) -> String {
        guard let timestamp, timestamp > 0 else { return "unknown" }
        return Date(timeIntervalSince1970: timestamp).formatted(date: .abbreviated, time: .omitted)
    }
}

/// A node's text, for reading and editing (`GET /api/learning/node`).
struct LearningNodeDetail: Hashable {
    var id: String
    var kind: LearningNode.Kind
    var label: String
    var content: String
}

/// The learning routes, scoped to one profile.
struct LearningAPI: CapabilityRoutes {
    let transport: CapabilitiesTransport
    let profile: String?

    /// The scan reads the skills catalog, the usage ledger and the memory files.
    static let graphTimeout: TimeInterval = 60

    func graph() async throws -> LearningGraph {
        LearningGraph(response: try await get("/api/learning/graph", timeout: Self.graphTimeout) as? JSON ?? [:])
    }

    func node(_ id: String) async throws -> LearningNodeDetail {
        let result = try await get("/api/learning/node", ["id": id]) as? JSON ?? [:]
        guard LenientField.bool(result["ok"]) else {
            throw DashboardError.rpc(LenientField.text(result["message"]) ?? "Hermes couldn't read \(id).")
        }
        let kind = LearningNode.Kind(rawValue: LenientField.text(result["kind"]) ?? "") ?? .skill
        return LearningNodeDetail(id: id, kind: kind, label: LenientField.text(result["label"]) ?? id,
                                  content: result["content"] as? String ?? "")
    }

    /// Rewrites a skill's SKILL.md or a memory note; Hermes' message on success.
    @discardableResult
    func edit(_ id: String, content: String) async throws -> String {
        try Self.outcome(try await send("PUT", "/api/learning/node", ["id": id, "content": content]), fallback: "Hermes didn't save it.")
    }

    /// Archives a skill (`hermes curator restore` brings it back) or deletes a memory note for good.
    @discardableResult
    func delete(_ id: String) async throws -> String {
        try Self.outcome(try await send("DELETE", "/api/learning/node", ["id": id]), fallback: "Hermes didn't remove it.")
    }

    private static func outcome(_ answer: Any, fallback: String) throws -> String {
        let result = answer as? JSON ?? [:]
        let message = LenientField.text(result["message"])
        guard LenientField.bool(result["ok"]) else { throw DashboardError.rpc(message ?? fallback) }
        return message ?? ""
    }
}
