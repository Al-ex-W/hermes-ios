import Foundation

/// Every page of Settings, in the desktop's navigation order (`apps/desktop/src/app/settings/index.tsx`).
/// The desktop's Voice page, keyboard shortcuts, window layout, pet, local models and uninstall are left out;
/// its Gateways page is our Connection page; Calls is this app's own.
enum SettingsPageID: String, Hashable, CaseIterable, Identifiable {
    case model, chat, appearance, workspace, safety, browser, vault, memory, advanced
    case notifications, billing
    case providers, profiles, connection, calls, apiKeys, sessions
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .model: return "Model"
        case .chat: return "Chat"
        case .appearance: return "Appearance"
        case .workspace: return "Workspace"
        case .safety: return "Safety"
        case .browser: return "Browser"
        case .vault: return "Passwords & Logins"
        case .memory: return "Memory & Context"
        case .advanced: return "Advanced"
        case .notifications: return "Notifications"
        case .billing: return "Billing"
        case .providers: return "Providers"
        case .profiles: return "Profiles"
        case .connection: return "Connection"
        case .calls: return "Calls"
        case .apiKeys: return "Tools & Keys"
        case .sessions: return "Sessions"
        case .about: return "About"
        }
    }

    /// SF Symbols for the desktop's Tabler glyphs (`constants.ts` SECTIONS and the nav groups).
    var icon: String {
        switch self {
        case .model: return "shippingbox"
        case .chat: return "bubble.left"
        case .appearance: return "paintpalette"
        case .workspace: return "desktopcomputer"
        case .safety: return "lock"
        case .browser: return "globe"
        case .vault: return "lock.shield"
        case .memory: return "brain"
        case .advanced: return "wrench.and.screwdriver"
        case .notifications: return "bell"
        case .billing: return "chart.bar"
        case .providers: return "bolt"
        case .profiles: return Theme.Icon.profile
        case .connection: return "network"
        case .calls: return "phone"
        case .apiKeys: return "key"
        case .sessions: return "archivebox"
        case .about: return "info.circle"
        }
    }

    /// The navigation groups, with the desktop's gaps between them.
    static let groups: [[SettingsPageID]] = [
        [.model, .chat, .appearance, .workspace, .safety, .browser, .vault, .memory, .advanced, .notifications, .billing],
        [.providers, .profiles, .connection, .calls, .apiKeys, .sessions],
        [.about],
    ]
}

/// A child page of a settings page (`config-subpages.ts`, `other-subpages.ts`, `appearance-subpages.ts`). The
/// schema fields it shows are its `fields` plus every key under one of its `prefixes`.
struct SettingsSubpage: Hashable, Identifiable {
    let id: String
    let title: String
    let icon: String
    var fields: [String] = []
    var prefixes: [String] = []

    func contains(_ key: String) -> Bool {
        fields.contains(key) || prefixes.contains { key.hasPrefix($0) }
    }
}

/// A schema-driven settings page: the config keys it offers (the desktop's curated `SECTIONS`), split into
/// subpages.
struct SettingsSection: Hashable, Identifiable {
    let page: SettingsPageID
    let keys: [String]
    let subpages: [SettingsSubpage]

    var id: SettingsPageID { page }
    var title: String { page.title }

    /// The subpage that renders `key`: the first whose fields or prefixes match (`configSubpageForField`).
    func subpage(for key: String) -> SettingsSubpage? {
        subpages.first { $0.contains(key) }
    }

    /// The section's keys that land on `subpage`, in the section's order.
    func keys(in subpage: SettingsSubpage) -> [String] {
        keys.filter { self.subpage(for: $0)?.id == subpage.id }
    }
}

enum SettingsCatalog {
    // MARK: Pages

    /// `SECTIONS` + `CONFIG_SUBPAGE_DEFINITIONS`. Desktop-only keys (`desktop.repo_scan_*`, which drive the
    /// desktop's own folder scan) and the whole voice section are left out.
    static let sections: [SettingsSection] = [
        SettingsSection(
            page: .model,
            keys: ["model_context_length", "fallback_providers", "delegation.model", "delegation.provider",
                   "delegation.max_iterations", "delegation.max_concurrent_children",
                   "delegation.child_timeout_seconds", "delegation.reasoning_effort"],
            subpages: [
                SettingsSubpage(id: "main", title: "Main model", icon: "shippingbox",
                                fields: ["model", "model_context_length", "agent.reasoning_effort", "agent.service_tier"],
                                prefixes: ["model."]),
                SettingsSubpage(id: "fallbacks", title: "Fallback models", icon: "arrow.triangle.branch",
                                fields: ["fallback_providers"]),
                SettingsSubpage(id: "auxiliary", title: "Auxiliary models", icon: "cpu", prefixes: ["auxiliary."]),
                SettingsSubpage(id: "delegation", title: "Subagents", icon: "arrow.triangle.branch",
                                prefixes: ["delegation."]),
                SettingsSubpage(id: "moa", title: "Mixture of Agents", icon: "person.2", prefixes: ["moa."]),
            ]
        ),
        SettingsSection(
            page: .chat,
            keys: ["display.personality", "timezone", "display.show_reasoning", "agent.image_input_mode"],
            subpages: [
                SettingsSubpage(id: "behavior", title: "Behavior", icon: "bubble.left",
                                fields: ["display.personality", "timezone", "display.show_reasoning"]),
                SettingsSubpage(id: "attachments", title: "Attachments", icon: "photo",
                                fields: ["agent.image_input_mode"]),
            ]
        ),
        SettingsSection(
            page: .workspace,
            keys: ["terminal.cwd", "code_execution.mode", "terminal.persistent_shell", "terminal.env_passthrough",
                   "file_read_max_chars"],
            subpages: [
                SettingsSubpage(id: "projects", title: "Projects", icon: "folder", fields: ["terminal.cwd"]),
                SettingsSubpage(id: "shell", title: "Shell environment", icon: "terminal",
                                fields: ["terminal.persistent_shell", "terminal.env_passthrough"]),
                SettingsSubpage(id: "files", title: "Files & execution", icon: "doc.text",
                                fields: ["code_execution.mode", "file_read_max_chars"]),
            ]
        ),
        SettingsSection(
            page: .safety,
            keys: ["approvals.mode", "approvals.timeout", "approvals.mcp_reload_confirm", "command_allowlist",
                   "security.redact_secrets", "security.allow_private_urls", "checkpoints.enabled"],
            subpages: [
                SettingsSubpage(id: "approvals", title: "Approvals", icon: "lock.shield",
                                fields: ["command_allowlist"], prefixes: ["approvals."]),
                SettingsSubpage(id: "privacy", title: "Privacy & network", icon: "lock", prefixes: ["security."]),
                SettingsSubpage(id: "checkpoints", title: "Checkpoints", icon: "archivebox", prefixes: ["checkpoints."]),
            ]
        ),
        SettingsSection(
            page: .browser,
            keys: ["browser.use_real_profile", "browser.allow_private_urls", "browser.auto_local_for_private_urls"],
            subpages: [
                SettingsSubpage(id: "profile", title: "Browser profile", icon: "globe",
                                fields: ["browser.use_real_profile"]),
                SettingsSubpage(id: "network", title: "Local & private URLs", icon: "network",
                                fields: ["browser.allow_private_urls", "browser.auto_local_for_private_urls"]),
            ]
        ),
        SettingsSection(
            page: .memory,
            keys: ["memory.memory_enabled", "memory.user_profile_enabled", "memory.memory_char_limit",
                   "memory.user_char_limit", "memory.provider", "context.engine", "compression.enabled",
                   "compression.threshold", "compression.codex_gpt55_autoraise", "compression.target_ratio",
                   "compression.protect_last_n", "auxiliary.compression.timeout"],
            subpages: [
                SettingsSubpage(id: "persistent", title: "Persistent memory", icon: "brain", prefixes: ["memory."]),
                SettingsSubpage(id: "context", title: "Context & compression", icon: "doc.text",
                                prefixes: ["context.", "compression.", "auxiliary.compression."]),
            ]
        ),
        SettingsSection(
            page: .advanced,
            keys: ["toolsets", "terminal.backend", "terminal.timeout", "terminal.docker_image",
                   "terminal.singularity_image", "terminal.modal_image", "terminal.daytona_image",
                   "tool_output.max_bytes", "tool_output.max_lines", "tool_output.max_line_length",
                   "checkpoints.max_snapshots", "agent.max_turns", "agent.api_max_retries", "agent.service_tier",
                   "agent.tool_use_enforcement", "updates.non_interactive_local_changes"],
            subpages: [
                // The desktop's "Desktop & startup": its device-local rows don't apply here, the update policy does.
                SettingsSubpage(id: "desktop", title: "Updates", icon: "arrow.down.to.line", prefixes: ["updates."]),
                SettingsSubpage(id: "runtime", title: "Agent limits", icon: "cpu",
                                fields: ["agent.max_turns", "agent.api_max_retries", "agent.service_tier"]),
                SettingsSubpage(id: "tools", title: "Tool access", icon: "wrench.and.screwdriver",
                                fields: ["toolsets", "agent.tool_use_enforcement"]),
                SettingsSubpage(id: "terminal", title: "Terminal backend", icon: "terminal", prefixes: ["terminal."]),
                SettingsSubpage(id: "output", title: "Output limits", icon: "doc.text",
                                prefixes: ["tool_output.", "checkpoints."]),
            ]
        ),
    ]

    /// The child pages of the pages that aren't schema sections (`other-subpages.ts`, `appearance-subpages.ts`,
    /// the Tools & Keys sub-views). Appearance keeps Theme and Chat display (typography, window layout and pet are
    /// desktop-only); Notifications keeps its alerts (no sounds); About keeps the versions (no uninstall).
    static let otherSubpages: [SettingsPageID: [SettingsSubpage]] = [
        .appearance: [
            SettingsSubpage(id: "theme", title: "Theme", icon: "paintpalette"),
            SettingsSubpage(id: "chat-display", title: "Chat display", icon: "bubble.left"),
        ],
        .vault: [
            SettingsSubpage(id: "credentials", title: "Saved credentials", icon: "key"),
            SettingsSubpage(id: "sources", title: "Password managers", icon: "lock"),
        ],
        .sessions: [
            SettingsSubpage(id: "archived", title: "Archive & retention", icon: "archivebox"),
            SettingsSubpage(id: "default-directory", title: "Default project folder", icon: "folder"),
        ],
        .apiKeys: [
            SettingsSubpage(id: "tools", title: "Tools", icon: "wrench.and.screwdriver"),
            SettingsSubpage(id: "settings", title: "Settings", icon: "slider.horizontal.3"),
        ],
    ]

    static func section(_ page: SettingsPageID) -> SettingsSection? {
        sections.first { $0.page == page }
    }

    static func subpages(_ page: SettingsPageID) -> [SettingsSubpage] {
        section(page)?.subpages ?? otherSubpages[page] ?? []
    }

    // MARK: Strip list

    /// Config prefixes this app never shows or writes: the official voice features (Voice page, wake word) are
    /// stripped, our call mode being the only voice feature; `desktop.*` drives the desktop's own folder scan.
    static let strippedPrefixes = ["voice.", "tts.", "stt.", "wake_word.", "wake.", "desktop."]
    /// Auxiliary task slots that only serve stripped features.
    static let strippedAuxiliaryTasks: Set<String> = ["voice_chat"]

    static func isStripped(_ key: String) -> Bool {
        strippedPrefixes.contains { key.hasPrefix($0) }
    }

    // MARK: Copy (`FIELD_LABELS`, `FIELD_DESCRIPTIONS`)

    static let labels: [String: String] = [
        "model": "Default Model",
        "model_context_length": "Main model context window (override)",
        "fallback_providers": "Fallback Models",
        "toolsets": "Enabled Toolsets",
        "timezone": "Timezone",
        "display.personality": "Personality",
        "display.show_reasoning": "Reasoning Blocks",
        "agent.max_turns": "Max Agent Steps",
        "agent.image_input_mode": "Image Attachments",
        "agent.api_max_retries": "API Retries",
        "agent.service_tier": "Service Tier",
        "agent.tool_use_enforcement": "Tool-Use Enforcement",
        "agent.reasoning_effort": "Reasoning",
        "terminal.cwd": "Working Directory",
        "terminal.backend": "Execution Backend",
        "terminal.timeout": "Command Timeout",
        "terminal.persistent_shell": "Persistent Shell",
        "terminal.env_passthrough": "Environment Passthrough",
        "terminal.docker_image": "Docker Image",
        "terminal.singularity_image": "Singularity Image",
        "terminal.modal_image": "Modal Image",
        "terminal.daytona_image": "Daytona Image",
        "file_read_max_chars": "File Read Limit",
        "tool_output.max_bytes": "Terminal Output Limit",
        "tool_output.max_lines": "File Page Limit",
        "tool_output.max_line_length": "Line Length Limit",
        "code_execution.mode": "Code Execution Mode",
        "approvals.mode": "Approval Mode",
        "approvals.timeout": "Approval Timeout",
        "approvals.mcp_reload_confirm": "Confirm MCP Reloads",
        "command_allowlist": "Command Allowlist",
        "security.redact_secrets": "Redact Secrets",
        "security.allow_private_urls": "Allow Private URLs",
        "browser.allow_private_urls": "Browser Private URLs",
        "browser.auto_local_for_private_urls": "Local Browser For Private URLs",
        "browser.use_real_profile": "Use My Real Browser Profile",
        "checkpoints.enabled": "File Checkpoints",
        "checkpoints.max_snapshots": "Checkpoint Limit",
        "memory.memory_enabled": "Persistent Memory",
        "memory.user_profile_enabled": "User Profile",
        "memory.memory_char_limit": "Memory Budget",
        "memory.user_char_limit": "Profile Budget",
        "memory.provider": "Memory Provider",
        "context.engine": "Context Engine",
        "compression.enabled": "Auto-Compression",
        "compression.threshold": "Compression Threshold",
        "compression.codex_gpt55_autoraise": "Codex Compression Auto-Raise",
        "compression.target_ratio": "Compression Target",
        "compression.protect_last_n": "Protected Recent Messages",
        "auxiliary.compression.timeout": "Compression model timeout (s)",
        "delegation.model": "Subagent Model",
        "delegation.provider": "Subagent Provider",
        "delegation.max_iterations": "Subagent Turn Limit",
        "delegation.max_concurrent_children": "Parallel Subagents",
        "delegation.child_timeout_seconds": "Subagent Timeout",
        "delegation.reasoning_effort": "Subagent Reasoning Effort",
        "updates.non_interactive_local_changes": "In-App Update Local Changes",
        "sessions.auto_archive": "Auto-archive stale chats",
        "sessions.auto_archive_days": "Archive after",
    ]

    static let descriptions: [String: String] = [
        "model": "Used for new chats unless you pick a different model in the composer.",
        "model_context_length": "Overrides the detected context window of the main chat model only (tokens). Leave at 0 to use the selected model's detected value. Does not affect auxiliary or MoA models.",
        "fallback_providers": "Backup provider:model entries to try if the default model fails.",
        "display.personality": "Default assistant style for new sessions.",
        "display.show_reasoning": "Show reasoning sections when the backend provides them.",
        "timezone": "IANA timezone identifier. Blank uses the system timezone.",
        "browser.use_real_profile": "Local browsing uses your real logins. Hermes copies the host's default browser profile (cookies, logins, preferences) into a managed snapshot and drives it with its packaged Chromium; the live profile is never opened directly. Only Chromium browsers are supported. Off by default.",
        "agent.image_input_mode": "Controls how image attachments are sent to the model.",
        "agent.max_turns": "Upper bound for tool-calling turns before Hermes stops a run.",
        "terminal.cwd": "Default project folder for tool and terminal work.",
        "terminal.persistent_shell": "SSH backend: keep exported variables between commands. Off starts each command from the login environment; the working directory always carries over.",
        "terminal.env_passthrough": "Environment variables to pass into tool execution.",
        "terminal.docker_image": "Container image used when the execution backend is Docker.",
        "terminal.singularity_image": "Image used when the execution backend is Singularity.",
        "terminal.modal_image": "Image used when the execution backend is Modal.",
        "terminal.daytona_image": "Image used when the execution backend is Daytona.",
        "code_execution.mode": "How strictly code execution is scoped to the current project.",
        "file_read_max_chars": "Maximum characters Hermes can read from one file request.",
        "approvals.mode": "How Hermes handles commands that need explicit approval.",
        "approvals.timeout": "How long approval prompts wait before timing out.",
        "security.redact_secrets": "Hide detected secrets from model-visible content when possible.",
        "checkpoints.enabled": "Create rollback snapshots before file edits.",
        "memory.memory_enabled": "Save durable memories that can help future sessions.",
        "memory.user_profile_enabled": "Maintain a compact profile of user preferences.",
        "context.engine": "Strategy for managing long conversations near the context limit.",
        "compression.enabled": "Summarize older context when conversations get large.",
        "compression.codex_gpt55_autoraise": "Raise compression to 85% for supported ChatGPT Codex OAuth models.",
        "auxiliary.compression.timeout": "Seconds to wait for the auxiliary compression model per call (default 120). Raise for slow local models.",
        "updates.non_interactive_local_changes": "When Hermes updates itself without a terminal prompt, keep local source edits (stash) or throw them away (discard). Terminal updates always ask.",
        "sessions.auto_archive": "Automatically archive chats you haven't touched in a while. Pinned chats are never archived, and nothing is deleted.",
        "sessions.auto_archive_days": "Days of inactivity before a chat is archived.",
    ]

    /// The row title for a key: curated copy, else the prettified last path part.
    static func label(for key: String) -> String {
        labels[key] ?? SettingsText.prettyName(String(key.split(separator: ".").last ?? Substring(key)))
    }

    /// Curated copy, else the schema's, hidden when it only repeats the label or the key (`ConfigField`).
    static func description(for key: String, schema: ConfigFieldSchema?) -> String? {
        let raw = (descriptions[key] ?? schema?.description ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        func folded(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        let text = folded(raw)
        return text == folded(label(for: key)) || text == folded(key) ? nil : raw
    }

    // MARK: Options

    /// `ENUM_OPTIONS`: select choices for fields whose schema only says string (voice entries left out).
    static let enumOptions: [String: [String]] = [
        "agent.image_input_mode": ["auto", "native", "text"],
        "approvals.mode": ["manual", "smart", "off"],
        "code_execution.mode": ["project", "strict"],
        "context.engine": ["compressor", "default", "custom"],
        "delegation.reasoning_effort": [""] + reasoningEfforts,
        "terminal.backend": ["local", "docker", "singularity", "modal", "daytona", "ssh"],
        "updates.non_interactive_local_changes": ["stash", "discard"],
    ]

    /// `@hermes/shared` `REASONING_EFFORTS`.
    static let reasoningEfforts = ["minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    /// `lib/personalities` `BUILTIN_PERSONALITIES` (mirrors `hermes_cli/personality.py`).
    static let builtinPersonalities = ["helpful", "concise", "technical", "creative", "teacher", "kawaii", "catgirl",
                                       "pirate", "shakespeare", "surfer", "noir", "uwu", "philosopher", "hype"]
    /// Spellings the runtime treats as no personality.
    static let neutralPersonalities: Set<String> = ["", "none", "default", "neutral"]

    /// The choices of a select field: the curated list (or, for personality, built-ins plus the config's own
    /// personalities) merged with the schema's, and the current value kept so it never shows as blank.
    /// nil when the field isn't a select.
    static func options(for key: String, field: ConfigFieldSchema, value: JSONValue?, config: JSONValue) -> [String]? {
        var options: [String]
        if key == "display.personality" {
            options = personalityOptions(config)
        } else if let curated = enumOptions[key] {
            options = curated
            if field.kind == .select { options += field.options.filter { !curated.contains($0) } }
        } else if field.kind == .select {
            options = field.options
        } else {
            return nil
        }
        if let current = value?.displayText, !current.isEmpty, !options.contains(current) { options.append(current) }
        return options
    }

    /// Built-ins plus the root `personalities` and `agent.personalities` blocks, folded like the runtime.
    static func personalityOptions(_ config: JSONValue) -> [String] {
        var names = [""] + builtinPersonalities
        for path in ["personalities", "agent.personalities"] {
            for name in (config.value(atPath: path)?.objectValue?.keys).map(Array.init)?.sorted() ?? [] {
                let folded = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if !neutralPersonalities.contains(folded), !names.contains(folded) { names.append(folded) }
            }
        }
        return names
    }

    /// The label a choice shows (`ConfigField`): the empty choice by field, else the prettified value.
    static func optionLabel(_ option: String, key: String, field: ConfigFieldSchema?) -> String {
        if let label = field?.optionLabels[option] { return label }
        guard option.isEmpty else { return SettingsText.prettyName(option) }
        switch key {
        case "display.personality": return "None"
        case "memory.provider": return "Built-in only"
        case "timezone": return "System default"
        case "delegation.reasoning_effort": return "Inherit"
        default: return "(none)"
        }
    }

    // MARK: Bounds

    /// Sensible limits for numeric fields whose schema states none: ratios stay in 0…1, counts and timeouts are
    /// never negative. A schema `min`/`max` wins.
    static let bounds: [String: (min: Double?, max: Double?)] = [
        "model_context_length": (0, nil),
        "compression.threshold": (0, 1),
        "compression.target_ratio": (0, 1),
        "compression.protect_last_n": (0, nil),
        "auxiliary.compression.timeout": (0, nil),
        "agent.max_turns": (1, nil),
        "agent.api_max_retries": (0, nil),
        "approvals.timeout": (0, nil),
        "delegation.max_iterations": (1, nil),
        "delegation.max_concurrent_children": (1, nil),
        "delegation.child_timeout_seconds": (0, nil),
        "memory.memory_char_limit": (0, nil),
        "memory.user_char_limit": (0, nil),
        "tool_output.max_bytes": (0, nil),
        "tool_output.max_lines": (0, nil),
        "tool_output.max_line_length": (0, nil),
        "file_read_max_chars": (0, nil),
        "terminal.timeout": (0, nil),
        "checkpoints.max_snapshots": (0, nil),
        "sessions.auto_archive_days": (1, 3650),
    ]

    // MARK: Visibility

    /// Whether a section field shows for this config: an execution backend's image field only when that backend
    /// is selected; stripped keys never.
    static func isVisible(_ key: String, config: JSONValue) -> Bool {
        if isStripped(key) { return false }
        if key == "delegation.provider" { return false } // edited together with delegation.model
        let images = ["docker", "singularity", "modal", "daytona"]
        if let backend = images.first(where: { key == "terminal.\($0)_image" }) {
            let selected = config.value(atPath: "terminal.backend")?.stringValue ?? "local"
            return selected == backend
        }
        return true
    }

    /// Built-in memory (MEMORY.md/USER.md) isn't a provider plugin; only a real plugin name has a config panel.
    static func isExternalMemoryProvider(_ value: JSONValue?) -> Bool {
        guard let name = value?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return !["", "builtin", "built-in", "none"].contains(name)
    }
}
