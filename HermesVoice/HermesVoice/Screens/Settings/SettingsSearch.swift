import Foundation

/// Where a search hit (or a deep link) opens: a page, one of its subpages, and the row to scroll to.
struct SettingsTarget: Hashable {
    var page: SettingsPageID
    var subpage: String?
    /// The row's anchor: a config key, a manifest setting id (`sessions.auto-archive`) or a credential name.
    var anchor: String?
}

/// One searchable row (`SettingsSearchEntry` in `settings-search.ts`).
struct SettingsSearchEntry: Identifiable, Hashable {
    let id: String
    let label: String
    var description: String?
    /// The page (and subpage) the row lives on, shown under the label.
    let context: String
    let icon: String
    var keywords: [String] = []
    let target: SettingsTarget
}

/// The rows that aren't config-schema fields or credentials (`settings-manifest.ts`), for the ones this app has.
/// A row's id is its anchor on the page, so a hit scrolls to it.
enum SettingsManifest {
    struct Row {
        let page: SettingsPageID
        let subpage: String?
        let id: String
        let label: String
        var description: String?
        var keywords: [String]
    }

    static let rows: [Row] = [
        Row(page: .model, subpage: "main", id: "model.main-model", label: "Default Model",
            description: SettingsCatalog.descriptions["model"], keywords: ["model", "provider", "default", "main"]),
        Row(page: .model, subpage: "main", id: "model.reasoning", label: "Reasoning",
            description: "Default reasoning effort for new chats.", keywords: ["effort", "thinking", "reasoning"]),
        Row(page: .model, subpage: "main", id: "model.fast", label: "Fast",
            description: "Priority processing on models that offer it.",
            keywords: ["speed", "service tier", "priority", "ultrafast", "standard"]),
        Row(page: .model, subpage: "auxiliary", id: "model.auxiliary", label: "Auxiliary models",
            description: "Models for side tasks such as compression, titles and vision.",
            keywords: ["auxiliary", "side task", "compression", "vision", "title"]),
        Row(page: .model, subpage: "moa", id: "model.moa", label: "Mixture of Agents",
            description: "Reference models and the aggregator that merges their answers.",
            keywords: ["moa", "mixture", "aggregator", "reference"]),
        Row(page: .appearance, subpage: "theme", id: "appearance.theme", label: "Theme",
            description: "Light, dark, or follow the system.", keywords: ["color mode", "skin", "light", "dark"]),
        Row(page: .vault, subpage: "credentials", id: "vault.credentials", label: "Saved credentials",
            description: "Logins, cards and addresses the browser fills without showing them to the model.",
            keywords: ["vault", "password", "login", "card", "address", "autofill"]),
        Row(page: .vault, subpage: "sources", id: "vault.sources", label: "Password managers",
            keywords: ["1password", "bitwarden", "keychain", "unlock", "vault"]),
        Row(page: .notifications, subpage: nil, id: "notifications.approval", label: "Approval needed",
            description: "A command waits for your approval.", keywords: ["notification", "alert", "approval"]),
        Row(page: .notifications, subpage: nil, id: "notifications.clarify", label: "Question asked",
            description: "Hermes asks you a question.", keywords: ["notification", "alert", "clarify", "question"]),
        Row(page: .notifications, subpage: nil, id: "notifications.turn-done", label: "Turn finished",
            description: "A reply finished while you were elsewhere.", keywords: ["notification", "alert", "done", "complete"]),
        Row(page: .notifications, subpage: nil, id: "notifications.test", label: "Send test notification",
            description: "Checks that iOS lets Hermes notify this iPhone.", keywords: ["notification", "test", "banner"]),
        Row(page: .safety, subpage: "privacy", id: "safety.shared-metrics", label: "Share usage stats with Nous",
            description: "Counts only, sent once a day with a random ID for this profile.",
            keywords: ["telemetry", "metrics", "analytics", "privacy", "usage"]),
        Row(page: .billing, subpage: nil, id: "billing.overview", label: "Billing overview",
            description: "Plan, credits and payment method.", keywords: ["billing", "credits", "plan", "subscription", "usage"]),
        Row(page: .providers, subpage: nil, id: "providers", label: "Providers",
            description: "Sign in to model providers, add API keys and custom endpoints.",
            keywords: ["provider", "account", "oauth", "api key", "endpoint", "openrouter", "anthropic"]),
        Row(page: .profiles, subpage: nil, id: "profiles", label: "Profiles",
            description: "Separate Hermes environments, each with its own config, skills and SOUL.md.",
            keywords: ["profile", "soul", "persona", "system prompt", "clone", "import", "export"]),
        Row(page: .connection, subpage: nil, id: "connection.address", label: "Hermes dashboard",
            description: "The address and user this app signs in with.",
            keywords: ["gateway", "connection", "url", "host", "tailscale", "sign out", "account"]),
        Row(page: .calls, subpage: nil, id: "calls.settings", label: "Calls",
            description: "Speech recognition, language and incoming calls.",
            keywords: ["call", "voice", "speech", "push", "ring"]),
        Row(page: .sessions, subpage: "archived", id: "sessions.auto-archive", label: "Auto-archive stale chats",
            description: SettingsCatalog.descriptions["sessions.auto_archive"],
            keywords: ["archive", "stale", "cleanup", "old chats", "days", "after"]),
        Row(page: .sessions, subpage: "default-directory", id: "sessions.default-directory", label: "Default project folder",
            description: "The folder new chats start in.", keywords: ["folder", "directory", "cwd", "project", "workspace"]),
        Row(page: .about, subpage: nil, id: "about.versions", label: "Version",
            keywords: ["version", "update", "release", "about"]),
    ]

    static var entries: [SettingsSearchEntry] {
        rows.map { row in
            let subpage = row.subpage.flatMap { id in SettingsCatalog.subpages(row.page).first { $0.id == id } }
            return SettingsSearchEntry(
                id: "setting:\(row.id)", label: row.label, description: row.description,
                context: [row.page.title, subpage?.title].compactMap { $0 }.joined(separator: " · "),
                icon: row.page.icon, keywords: row.keywords,
                target: SettingsTarget(page: row.page, subpage: row.subpage, anchor: row.id)
            )
        }
    }
}

enum SettingsSearch {
    /// The Tools & Keys sub-view a credential lists under (`credentialSettingsView`); nil for providers and
    /// messaging-platform credentials, whose pages are elsewhere.
    static func keysView(for info: EnvVar) -> String? {
        if info.channelManaged { return nil }
        switch info.category {
        case "tool": return "tools"
        case "setting", "messaging": return "settings"
        default: return nil
        }
    }

    /// Credential rows (`buildCredentialSearchEntries`).
    static func credentialEntries(_ catalog: EnvCatalog) -> [SettingsSearchEntry] {
        catalog.vars.values.sorted { $0.key < $1.key }.compactMap { info in
            guard let view = keysView(for: info),
                  let subpage = SettingsCatalog.subpages(.apiKeys).first(where: { $0.id == view }) else { return nil }
            return SettingsSearchEntry(
                id: "credential:\(info.key)", label: info.label,
                description: info.description.isEmpty ? nil : info.description,
                context: "\(SettingsPageID.apiKeys.title) · \(subpage.title)", icon: SettingsPageID.apiKeys.icon,
                keywords: [info.key, info.url ?? ""] + info.tools,
                target: SettingsTarget(page: .apiKeys, subpage: view, anchor: info.key)
            )
        }
    }

    /// The desktop's `normalize`: case- and accent-folded, whitespace collapsed.
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `searchScore`: every term must occur somewhere; an exact, prefix or partial label match ranks first, then
    /// the context, then labels and contexts holding every term, then the rest.
    static func score(_ entry: SettingsSearchEntry, query: String) -> Int {
        let needle = normalize(query)
        guard !needle.isEmpty else { return 0 }
        let label = normalize(entry.label)
        let context = normalize(entry.context)
        let parts: [String] = [entry.label, entry.context, entry.description ?? ""] + entry.keywords
        let haystack = normalize(parts.joined(separator: " "))
        let terms = needle.split(separator: " ").map(String.init)
        guard terms.allSatisfy({ haystack.contains($0) }) else { return 0 }
        if label == needle { return 100 }
        if label.hasPrefix(needle) { return 90 }
        if label.contains(needle) { return 80 }
        if context.contains(needle) { return 70 }
        if terms.allSatisfy({ label.contains($0) || context.contains($0) }) { return 60 }
        return 50
    }

    /// The matching entries, best first; ties keep their order (`filterSettingsSearchEntries`).
    static func filter(_ entries: [SettingsSearchEntry], query: String) -> [SettingsSearchEntry] {
        struct Hit {
            let offset: Int
            let entry: SettingsSearchEntry
            let score: Int
        }
        var hits: [Hit] = []
        for (offset, entry) in entries.enumerated() {
            let value = score(entry, query: query)
            if value > 0 { hits.append(Hit(offset: offset, entry: entry, score: value)) }
        }
        hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.offset < $1.offset }
        return hits.map(\.entry)
    }
}
