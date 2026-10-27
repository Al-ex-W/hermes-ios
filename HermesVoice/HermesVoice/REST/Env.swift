import Foundation

/// One provider route a shared credential serves (`EnvProviderProfile`): DASHSCOPE_API_KEY, for one, backs more
/// than one built-in provider card.
struct EnvProviderRoute: Hashable {
    var provider: String
    var providerLabel: String?
    var description: String?
    var url: String?
    var primary: Bool

    init?(row: JSON) {
        guard let provider = LenientField.text(row["provider"]) ?? LenientField.text(row["provider_label"]) else { return nil }
        self.provider = provider
        providerLabel = LenientField.text(row["provider_label"])
        description = LenientField.text(row["description"])
        url = LenientField.text(row["url"])
        primary = LenientField.bool(row["primary"])
    }
}

/// One `.env` variable the dashboard knows (`EnvVarInfo`, `GET /api/env`). The value itself never leaves the host:
/// a set variable comes with a display-only preview.
struct EnvVar: Identifiable, Hashable {
    let key: String
    var isSet = false
    /// The backend's write-guarded preview (`«redacted:sk-p...7890»`); see `CredentialMask.display`.
    var redactedValue: String?
    var description = ""
    var url: String?
    /// "provider", "tool", "setting", "messaging", "custom", …
    var category = ""
    var isPassword = false
    var tools: [String] = []
    var advanced = false
    /// A messaging-platform credential the Messaging page owns.
    var channelManaged = false
    var provider: String?
    var providerLabel: String?
    var providerRoutes: [EnvProviderRoute] = []
    /// The provider's own first credential, ahead of any alias.
    var providerPrimary = false
    /// A `.env` key in no catalog, added by hand.
    var custom = false

    var id: String { key }

    init(key: String, isSet: Bool = false, redactedValue: String? = nil, category: String = "", isPassword: Bool = false) {
        self.key = key
        self.isSet = isSet
        self.redactedValue = redactedValue
        self.category = category
        self.isPassword = isPassword
    }

    init(key: String, row: JSON) {
        self.key = key
        isSet = LenientField.bool(row["is_set"])
        redactedValue = LenientField.text(row["redacted_value"])
        description = LenientField.text(row["description"]) ?? ""
        url = LenientField.text(row["url"])
        category = LenientField.text(row["category"]) ?? ""
        isPassword = LenientField.bool(row["is_password"])
        tools = LenientField.strings(row["tools"])
        advanced = LenientField.bool(row["advanced"])
        channelManaged = LenientField.bool(row["channel_managed"])
        provider = LenientField.text(row["provider"])
        providerLabel = LenientField.text(row["provider_label"])
        providerRoutes = (row["provider_profiles"] as? [JSON] ?? []).compactMap(EnvProviderRoute.init(row:))
        providerPrimary = LenientField.bool(row["provider_primary"])
        custom = LenientField.bool(row["custom"])
    }

    /// An API key or token by flag or by name (`isKeyVar`): typed into a secure field, never shown.
    var isSecret: Bool { isPassword || Self.looksLikeKey(key) }

    /// What a set variable shows instead of its value.
    var preview: String? { isSet ? CredentialMask.display(redactedValue) ?? CredentialMask.placeholder : nil }

    /// The row title (`credentialRowLabel`): a key's provider part, else the whole name, words capitalised.
    var label: String {
        Self.prettyName(isSecret ? Self.stripKeySuffix(key) : key)
    }

    /// A field title inside a provider card (`friendlyFieldLabel` for knobs, the key's stem for extra keys).
    var fieldLabel: String {
        if isSecret { return Self.prettyName(Self.stripKeySuffix(key)) }
        if !description.isEmpty { return description }
        return key.replacingOccurrences(of: "_", with: " ").lowercased().capitalized
    }

    /// The input's placeholder (`credentialPlaceholder`).
    var placeholder: String {
        if isSecret { return "Paste \(label) key" }
        return key.uppercased().hasSuffix("URL") ? "https://…" : "Optional"
    }

    static func looksLikeKey(_ key: String) -> Bool {
        key.hasSuffix("_API_KEY") || key.hasSuffix("_TOKEN") || key.hasSuffix("_KEY")
    }

    private static func stripKeySuffix(_ key: String) -> String {
        for suffix in ["_API_KEY", "_TOKEN", "_KEY"] where key.uppercased().hasSuffix(suffix) {
            return String(key.dropLast(suffix.count))
        }
        return key
    }

    /// `prettyName`: underscores to spaces, each word's first character uppercased, the rest as is.
    static func prettyName(_ value: String) -> String {
        var out = ""
        var atWordStart = true
        for character in value.replacingOccurrences(of: "_", with: " ") {
            let wordCharacter = character.isLetter || character.isNumber
            out.append(atWordStart && wordCharacter ? Character(character.uppercased()) : character)
            atWordStart = !wordCharacter
        }
        return out
    }
}

/// How credentials show on the phone. The dashboard never sends a stored value, only a preview, and refuses a
/// preview sent back as a value; the app keeps typed values in memory only until they are sent.
enum CredentialMask {
    static let placeholder = "••••••••"

    /// The backend's display sentinel `«redacted:sk-p...7890»` shows as `sk-p...7890`; a sentinel without a
    /// preview, or the short-value mask `***`, as a plain mask; anything else (older backends' bare masks) as is.
    static func display(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        guard value.hasPrefix("«redacted") else { return value == "***" ? placeholder : value }
        if value.hasPrefix("«redacted:"), value.hasSuffix("»") {
            let inner = value.dropFirst("«redacted:".count).dropLast().trimmingCharacters(in: .whitespaces)
            if !inner.isEmpty, inner != "***" { return inner }
        }
        return placeholder
    }

    /// The preview a value gets right after it is saved, before the list reloads: the server's own mask
    /// (`agent.redact.mask_secret`), so it never shows more than the dashboard would: first and last four
    /// characters of a value of 12 or more (control characters dropped), else a plain mask.
    static func localPreview(_ value: String) -> String {
        let visible = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        guard visible.count >= 12 else { return placeholder }
        let scalars = Array(visible)
        var preview = String.UnicodeScalarView(scalars.prefix(4))
        preview.append(contentsOf: "...".unicodeScalars)
        preview.append(contentsOf: scalars.suffix(4))
        return String(preview)
    }

    /// A display-only preview, which the dashboard refuses to store (`is_redacted_credential_preview`): any
    /// `«redacted…` sentinel, `***`, or the legacy `abcd...wxyz` mask (exactly 4 + "..." + 4 characters).
    static func isPreview(_ value: String) -> Bool {
        if value.hasPrefix("«redacted") || value == "***" { return true }
        let scalars = Array(value.unicodeScalars)
        guard scalars.count == 11, !scalars.contains("\n") else { return false }
        return scalars[4] == "." && scalars[5] == "." && scalars[6] == "."
    }

    /// `${VAR}`: how a custom endpoint shows a key kept in `.env`. Display-only too.
    static func isEnvReference(_ value: String) -> Bool {
        value.hasPrefix("${") && value.hasSuffix("}") && value.count > 3 && !value.dropFirst(2).dropLast().contains("}")
    }

    /// `message` with every occurrence of `secret` blanked, so an error never echoes a typed key back.
    static func scrub(_ message: String, secret: String) -> String {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.count >= 4 else { return message }
        return message.replacingOccurrences(of: secret, with: placeholder)
    }
}

/// Every variable `GET /api/env` lists, keyed by name.
struct EnvCatalog: Hashable {
    var vars: [String: EnvVar]

    init(vars: [String: EnvVar] = [:]) {
        self.vars = vars
    }

    init(response: JSON) {
        var vars: [String: EnvVar] = [:]
        for (key, row) in response {
            guard let row = row as? JSON, !key.isEmpty else { continue }
            vars[key] = EnvVar(key: key, row: row)
        }
        self.vars = vars
    }

    subscript(key: String) -> EnvVar? { vars[key] }

    /// The Tools & Keys rows: variables in `categories` that no Messaging card owns, by name.
    func entries(categories: Set<String>) -> [EnvVar] {
        vars.values.filter { !$0.channelManaged && categories.contains($0.category) }.sorted { $0.key < $1.key }
    }

    /// One card per provider (`buildProviderKeyGroups`): its main key field plus the knobs and extra keys that
    /// belong to it. Grouped by the backend's provider identity (the `hermes model` catalog), else by prefix;
    /// providers without a key field are left out. Ordered by the desktop's priority, then name.
    func providerGroups() -> [ProviderKeyGroup] {
        var buckets: [String: [EnvVar]] = [:]
        for info in vars.values where info.category == "provider" {
            let scoped: [EnvVar] = info.providerRoutes.isEmpty ? [info] : info.providerRoutes.map { route in
                var copy = info
                if let description = route.description { copy.description = description }
                copy.provider = route.provider
                copy.providerLabel = route.providerLabel
                copy.providerPrimary = route.primary
                copy.url = route.url ?? info.url
                return copy
            }
            for row in scoped {
                let name = row.providerLabel ?? row.provider ?? ProviderCatalog.group(for: row.key)
                guard name != ProviderCatalog.other else { continue }
                buckets[name, default: []].append(row)
            }
        }
        var groups: [ProviderKeyGroup] = []
        for (name, entries) in buckets {
            // JSON objects lose their order on the way in, so ties break the same way every time.
            let ranked = entries.sorted { lhs, rhs in
                let left = (lhs.providerPrimary ? 0 : 1, lhs.advanced ? 1 : 0, lhs.key.hasSuffix("_API_KEY") ? 0 : 1)
                let right = (rhs.providerPrimary ? 0 : 1, rhs.advanced ? 1 : 0, rhs.key.hasSuffix("_API_KEY") ? 0 : 1)
                return left != right ? left < right : lhs.key < rhs.key
            }
            guard let primary = ranked.first(where: { $0.providerPrimary && $0.isSecret })
                ?? ranked.first(where: { !$0.advanced && $0.isSecret })
                ?? ranked.first(where: \.isSecret) else { continue }
            let meta = ProviderCatalog.meta(for: name)
            var seen: Set<String> = [primary.key]
            let advanced = ranked
                .filter { $0.key != primary.key && (!$0.isSecret || $0.isSet) && seen.insert($0.key).inserted }
                .sorted { $0.key < $1.key }
            groups.append(ProviderKeyGroup(
                name: name, primary: primary, advanced: advanced,
                description: meta?.description ?? (primary.description.isEmpty ? nil : primary.description),
                docsURL: meta?.docsURL ?? primary.url,
                hasAnySet: entries.contains(where: \.isSet), priority: ProviderCatalog.priority(for: name)
            ))
        }
        return groups.sorted { $0.priority != $1.priority ? $0.priority < $1.priority : $0.name < $1.name }
    }

    /// Records a save or removal locally until the next reload.
    mutating func update(_ key: String, isSet: Bool, preview: String?) {
        guard var info = vars[key] else { return }
        info.isSet = isSet
        info.redactedValue = preview
        vars[key] = info
    }
}

/// A provider's key card on the API keys page.
struct ProviderKeyGroup: Identifiable, Hashable {
    var name: String
    /// The "Paste key" field.
    var primary: EnvVar
    /// Base URLs, regions and extra keys that are already set.
    var advanced: [EnvVar]
    var description: String?
    var docsURL: String?
    var hasAnySet: Bool
    var priority: Int

    var id: String { name }

    /// Every variable the card edits.
    var keys: [String] { [primary.key] + advanced.map(\.key) }
}

/// The desktop's provider presentation overlay (`PROVIDER_GROUPS` in settings/constants.ts): which env prefix
/// belongs to which provider, its blurb, key page and place in the list.
enum ProviderCatalog {
    struct Entry {
        let prefix: String
        let name: String
        var description: String?
        var docsURL: String?
        let priority: Int
    }

    static let other = "Other"

    static let entries: [Entry] = [
        Entry(prefix: "NOUS_", name: "Nous Portal", description: "Hosted Hermes & Nous-trained models",
              docsURL: "https://portal.nousresearch.com", priority: 0),
        // The desktop links the API-keys page under the app's user settings; the app root (which leads there)
        // keeps this repository's pre-push path scan free of false hits.
        Entry(prefix: "FIREWORKS_", name: "Fireworks AI", description: "OpenAI-compatible direct model API",
              docsURL: "https://app.fireworks.ai", priority: 1),
        Entry(prefix: "OPENROUTER_", name: "OpenRouter", description: "Aggregator for hundreds of frontier models",
              docsURL: "https://openrouter.ai/keys", priority: 1),
        Entry(prefix: "ANTHROPIC_", name: "Anthropic", description: "Claude API access (Sonnet, Opus, Haiku)",
              docsURL: "https://console.anthropic.com/settings/keys", priority: 2),
        Entry(prefix: "XAI_", name: "xAI", description: "Grok models (use OAuth for SuperGrok / Premium+)",
              docsURL: "https://console.x.ai/", priority: 3),
        Entry(prefix: "GOOGLE_", name: "Gemini", description: "Google AI Studio (Gemini 1.5 / 2.0 / 2.5)",
              docsURL: "https://aistudio.google.com/app/apikey", priority: 4),
        Entry(prefix: "GEMINI_", name: "Gemini", priority: 4),
        Entry(prefix: "DEEPSEEK_", name: "DeepSeek", description: "Direct DeepSeek API (V3.x, R1)",
              docsURL: "https://platform.deepseek.com/api_keys", priority: 5),
        Entry(prefix: "DASHSCOPE_", name: "DashScope (Qwen)", description: "Alibaba Cloud DashScope — Qwen and multi-vendor models",
              docsURL: "https://modelstudio.console.alibabacloud.com/", priority: 6),
        Entry(prefix: "HERMES_QWEN_", name: "DashScope (Qwen)", priority: 6),
        Entry(prefix: "GLM_", name: "GLM / Z.AI", description: "Zhipu GLM-4.6 and Z.AI hosted endpoints",
              docsURL: "https://z.ai/", priority: 7),
        Entry(prefix: "ZAI_", name: "GLM / Z.AI", priority: 7),
        Entry(prefix: "Z_AI_", name: "GLM / Z.AI", priority: 7),
        Entry(prefix: "KIMI_", name: "Kimi / Moonshot", description: "Moonshot Kimi K2 / coding endpoints",
              docsURL: "https://platform.moonshot.cn/", priority: 8),
        Entry(prefix: "KIMI_CN_", name: "Kimi (China)", description: "Moonshot China endpoint",
              docsURL: "https://platform.moonshot.cn/", priority: 9),
        Entry(prefix: "MINIMAX_", name: "MiniMax", description: "MiniMax-M2 and Hailuo international endpoints",
              docsURL: "https://www.minimax.io/", priority: 10),
        Entry(prefix: "MINIMAX_CN_", name: "MiniMax (China)", description: "MiniMax mainland China endpoint",
              docsURL: "https://www.minimaxi.com/", priority: 11),
        Entry(prefix: "HF_", name: "Hugging Face", description: "Inference Providers — 20+ open models via router.huggingface.co",
              docsURL: "https://huggingface.co/settings/tokens", priority: 12),
        Entry(prefix: "OPENCODE_ZEN_", name: "OpenCode Zen", description: "Pay-as-you-go access to curated coding models",
              docsURL: "https://opencode.ai/auth", priority: 13),
        Entry(prefix: "OPENCODE_GO_", name: "OpenCode Go", description: "$10/month subscription for open coding models",
              docsURL: "https://opencode.ai/auth", priority: 14),
        Entry(prefix: "NVIDIA_", name: "NVIDIA NIM", description: "build.nvidia.com or your own local NIM endpoint",
              docsURL: "https://build.nvidia.com/", priority: 15),
        Entry(prefix: "OLLAMA_", name: "Ollama Cloud", description: "Cloud-hosted open models from ollama.com",
              docsURL: "https://ollama.com/settings", priority: 16),
        Entry(prefix: "LM_", name: "LM Studio", description: "Local LM Studio server (OpenAI-compatible)",
              docsURL: "https://lmstudio.ai/docs/local-server", priority: 17),
        Entry(prefix: "STEPFUN_", name: "StepFun", description: "StepFun Step Plan coding models",
              docsURL: "https://platform.stepfun.com/", priority: 18),
        Entry(prefix: "XIAOMI_", name: "Xiaomi MiMo", description: "MiMo-V2.5 and Xiaomi proprietary models",
              docsURL: "https://platform.xiaomimimo.com", priority: 19),
        Entry(prefix: "ARCEEAI_", name: "Arcee AI", description: "Arcee-hosted small + medium models",
              docsURL: "https://chat.arcee.ai/", priority: 20),
        Entry(prefix: "ARCEE_", name: "Arcee AI", priority: 20),
        Entry(prefix: "GMI_", name: "GMI Cloud", description: "GMI Cloud GPU + model serving",
              docsURL: "https://www.gmicloud.ai/", priority: 21),
        Entry(prefix: "AZURE_FOUNDRY_", name: "Azure Foundry",
              description: "Azure AI Foundry custom endpoints (OpenAI / Anthropic-compatible)",
              docsURL: "https://ai.azure.com/", priority: 22),
        Entry(prefix: "AWS_", name: "AWS Bedrock", description: "Authenticate via AWS profile + region",
              docsURL: "https://docs.aws.amazon.com/bedrock/latest/userguide/bedrock-regions.html", priority: 23),
    ]

    /// The provider an env var belongs to by its longest matching prefix (`providerGroup`), else "Other".
    static func group(for key: String) -> String {
        entries.filter { key.hasPrefix($0.prefix) }.max { $0.prefix.count < $1.prefix.count }?.name ?? other
    }

    /// The entry with a blurb or key page for `name`, else any entry for it.
    static func meta(for name: String) -> Entry? {
        entries.first { $0.name == name && ($0.description != nil || $0.docsURL != nil) } ?? entries.first { $0.name == name }
    }

    static func priority(for name: String) -> Int { meta(for: name)?.priority ?? 99 }
}

/// What `POST /api/providers/validate` thinks of a key before it is saved. `reachable` false: the probe couldn't
/// run (or Hermes has none for this provider), so the key may still be fine.
struct CredentialCheck: Hashable {
    var ok: Bool
    var reachable: Bool
    var message: String?

    init(response: JSON) {
        ok = LenientField.bool(response["ok"])
        reachable = LenientField.optionalBool(response["reachable"]) ?? true
        message = LenientField.text(response["message"])
    }

    /// The key is known bad: don't save it.
    var rejected: Bool { !ok && reachable }
}

extension Notification.Name {
    /// Credentials or endpoints changed here, so the providers' model lists may have changed.
    static let hermesModelOptionsDidChange = Notification.Name("HermesModelOptionsDidChange")
}

extension DashboardClient {
    /// Every variable the dashboard knows for `profile` (nil: the dashboard's own), with previews only.
    func envVars(profile: String? = nil) async throws -> EnvCatalog {
        let result = try await request("GET", "/api/env", query: Self.profileQuery(profile))
        return EnvCatalog(response: result as? JSON ?? [:])
    }

    /// Stores a value in the profile's `.env` (and the config mirrors Hermes keeps of it). The value goes to the
    /// dashboard in this request body only: it isn't logged, kept or echoed back in an error.
    /// `providerSetup` marks a provider connection (the key also counts as a provider setup on the host).
    func setEnv(_ key: String, value: String, profile: String? = nil, providerSetup: Bool = false) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw DashboardError.rpc("Enter a value first.") }
        guard !CredentialMask.isPreview(value) else {
            throw DashboardError.rpc("That's the saved key's preview. Paste the full key to replace it.")
        }
        var body: JSON = ["key": key, "value": value]
        if let profile { body["profile"] = profile }
        if providerSetup { body["provider_setup"] = true }
        do {
            _ = try await request("PUT", "/api/env", query: Self.profileQuery(profile), body: body)
        } catch {
            throw Self.scrubbed(error, secret: value)
        }
    }

    /// Removes a variable from the profile's `.env` and every mirror of that credential. Already gone counts as done.
    func deleteEnv(_ key: String, profile: String? = nil) async throws {
        var body: JSON = ["key": key]
        if let profile { body["profile"] = profile }
        do {
            _ = try await request("DELETE", "/api/env", query: Self.profileQuery(profile), body: body)
        } catch let DashboardError.http(code, _) where code == 404 {
            return
        }
    }

    /// Asks the dashboard to try a provider key against the provider (OpenRouter, OpenAI, xAI, Gemini) without
    /// saving it.
    func checkCredential(_ key: String, value: String) async throws -> CredentialCheck {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await request("POST", "/api/providers/validate", body: ["key": key, "value": value])
            return CredentialCheck(response: result as? JSON ?? [:])
        } catch {
            throw Self.scrubbed(error, secret: value)
        }
    }

    static func profileQuery(_ profile: String?) -> [String: String] {
        profile.map { ["profile": $0] } ?? [:]
    }

    /// `error` with `secret` blanked out of whatever the dashboard sent back.
    static func scrubbed(_ error: Error, secret: String) -> Error {
        guard case let .http(code, body)? = error as? DashboardError else { return error }
        return DashboardError.http(code, CredentialMask.scrub(body, secret: secret))
    }
}
