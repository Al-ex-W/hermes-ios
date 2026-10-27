import Foundation

// The dashboard's webhook routes (`hermes_cli/web_routers/ops.py`): the webhook receiver is its own gateway
// platform, and its subscriptions live in the JSON store the CLI also drives. Enabling the receiver writes config and
// restarts the gateway; subscription changes hot-reload. A route's HMAC secret is never read back: the host answers
// it exactly once, when the route is created. Decoders are lenient.

/// One subscription (`WebhookRoute`): where events arrive and what the agent does with them.
struct WebhookRoute: Hashable, Identifiable {
    var name: String
    var description = ""
    var events: [String] = []
    /// `log`, or a channel (`telegram`, `discord`, …).
    var deliver = "log"
    /// Sends the payload to the channel as is, without the agent.
    var deliverOnly = false
    var prompt = ""
    var script = ""
    var skills: [String] = []
    var createdAt: String?
    /// The URL to point the sender at.
    var url: String
    var secretSet = false
    var enabled = true

    var id: String { name }

    init(name: String, url: String) {
        self.name = name
        self.url = url
    }

    init?(row: JSON) {
        guard let name = LenientField.text(row["name"]) else { return nil }
        self.name = name
        description = LenientField.text(row["description"]) ?? ""
        events = LenientField.strings(row["events"])
        deliver = LenientField.text(row["deliver"]) ?? "log"
        deliverOnly = LenientField.bool(row["deliver_only"])
        prompt = LenientField.text(row["prompt"]) ?? ""
        script = LenientField.text(row["script"]) ?? ""
        skills = LenientField.strings(row["skills"])
        createdAt = LenientField.text(row["created_at"])
        url = LenientField.text(row["url"]) ?? ""
        secretSet = LenientField.bool(row["secret_set"])
        // Default-enabled: only an explicit false turns a route off.
        enabled = LenientField.optionalBool(row["enabled"]) ?? true
    }

    /// The search (`visible`): name, description, delivery target and events.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        return ([name, description, deliver] + events).contains { $0.lowercased().contains(q) }
    }

    var deliverLabel: String { WebhookDelivery.label(deliver) }
}

/// `GET /api/webhooks`: whether the receiver is on, its base URL, and the subscriptions.
struct WebhooksSnapshot: Hashable {
    var enabled: Bool
    var baseURL: String
    var subscriptions: [WebhookRoute]

    init(response: JSON) {
        enabled = LenientField.bool(response["enabled"])
        baseURL = LenientField.text(response["base_url"]) ?? ""
        subscriptions = (response["subscriptions"] as? [Any] ?? []).compactMap { ($0 as? JSON).flatMap(WebhookRoute.init(row:)) }
    }

    func route(_ name: String) -> WebhookRoute? { subscriptions.first { $0.name == name } }
}

/// Where a subscription can deliver (`DELIVER_OPTIONS`).
enum WebhookDelivery {
    static let options = ["log", "telegram", "discord", "slack", "email", "github_comment"]

    static func label(_ value: String) -> String {
        switch value {
        case "log": return "Log"
        case "telegram": return "Telegram"
        case "discord": return "Discord"
        case "slack": return "Slack"
        case "email": return "Email"
        case "github_comment": return "GitHub comment"
        default: return value
        }
    }
}

/// The new-subscription form (`WebhookCreatePayload`).
struct WebhookDraft: Equatable {
    var name = ""
    var description = ""
    var prompt = ""
    /// Comma-separated; empty takes every event.
    var events = ""
    /// Comma-separated skill names.
    var skills = ""
    var deliver = "log"
    var deliverOnly = false

    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The request body: blanks left out, so the host fills its defaults.
    var body: JSON {
        var body: JSON = ["name": trimmedName, "deliver": deliver, "deliver_only": deliverOnly]
        let description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if !description.isEmpty { body["description"] = description }
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { body["prompt"] = prompt }
        let events = Self.list(events)
        if !events.isEmpty { body["events"] = events }
        let skills = Self.list(skills)
        if !skills.isEmpty { body["skills"] = skills }
        return body
    }

    static func list(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

/// `POST /api/webhooks`: the new route and its secret, shown this once.
struct WebhookCreated: Hashable {
    var route: WebhookRoute
    var secret: String

    init?(response: JSON) {
        guard let route = WebhookRoute(row: response), let secret = response["secret"] as? String, !secret.isEmpty else { return nil }
        self.route = route
        self.secret = secret
    }
}

/// `POST /api/webhooks/enable`: the receiver is on in config; whether the host restarted the gateway for it.
struct WebhookEnableResult: Hashable {
    var restartStarted: Bool
    var restartError: String?

    init(response: JSON) {
        restartStarted = LenientField.bool(response["restart_started"])
        restartError = LenientField.text(response["restart_error"])
    }
}

/// How a secret shows while hidden: dots only, none of its characters, in a length that doesn't give it away.
enum WebhookSecretMask {
    static func masked(_ secret: String) -> String {
        String(repeating: "•", count: min(max(secret.count, 8), 24))
    }
}

/// The webhook routes for one profile (`?profile=`; nil is the dashboard's own).
struct WebhooksAPI: CapabilityRoutes {
    let transport: CapabilitiesTransport
    let profile: String?

    func list() async throws -> WebhooksSnapshot {
        WebhooksSnapshot(response: try await get("/api/webhooks") as? JSON ?? [:])
    }

    /// Turns the receiver on and (best effort) restarts the gateway.
    func enable() async throws -> WebhookEnableResult {
        let result = try await transport.request("POST", "/api/webhooks/enable", query: scopeQuery, body: nil,
                                                 timeout: MessagingAPI.onboardingTimeout) as? JSON
        return WebhookEnableResult(response: result ?? [:])
    }

    /// The new route and its one-time secret. The secret never comes back in an error.
    func create(_ draft: WebhookDraft) async throws -> WebhookCreated {
        let result = try await send("POST", "/api/webhooks", draft.body) as? JSON ?? [:]
        guard let created = WebhookCreated(response: result) else {
            throw DashboardError.rpc("The webhook was created, but Hermes didn't answer its secret. Delete it and create it again.")
        }
        return created
    }

    /// Hermes refuses an unnamed profile here while it serves several (`destructive_profile`), so the dashboard's own
    /// profile goes by name (`GET /api/profiles/active`).
    func delete(_ name: String) async throws {
        let path = "/api/webhooks/\(try MessagingAPI.segment(name))"
        var query = scopeQuery
        if profile == nil {
            let active = try await transport.request("GET", "/api/profiles/active", query: [:], body: nil) as? JSON
            query["profile"] = ProfileActivity(response: active ?? [:]).current
        }
        _ = try await transport.request("DELETE", path, query: query, body: nil)
    }

    /// A disabled route stays on disk; the gateway rejects its events with 403 until it is enabled again.
    func setEnabled(_ name: String, _ enabled: Bool) async throws {
        _ = try await send("PUT", "/api/webhooks/\(try MessagingAPI.segment(name))/enabled", ["enabled": enabled])
    }
}
