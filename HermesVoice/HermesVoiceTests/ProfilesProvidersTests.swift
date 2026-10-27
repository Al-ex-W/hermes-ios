import XCTest
@testable import HermesVoice

/// Decoders for the profile and provider routes, the credential masks, and the request bodies the screens send.
final class ProfilesProvidersTests: XCTestCase {
    private func json(_ text: String) throws -> JSON {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)
    }

    // MARK: Profiles

    func testProfileRowDecodesEveryField() throws {
        let profile = try XCTUnwrap(ProfileInfo(row: try json("""
        {"name": "work", "display_name": " Work bot ", "is_default": false, "model": "claude-x", "provider": "anthropic",
         "path": "/srv/hermes/profiles/work", "has_env": true, "skill_count": 12, "bot_title": "Helper",
         "gateway_running": true, "description": "Answers mail"}
        """)))
        XCTAssertEqual(profile.label, "Work bot")
        XCTAssertFalse(profile.isDefault)
        XCTAssertEqual(profile.modelSummary, "claude-x · anthropic")
        XCTAssertEqual(profile.path, "/srv/hermes/profiles/work")
        XCTAssertTrue(profile.hasEnv)
        XCTAssertEqual(profile.skillCount, 12)
        XCTAssertEqual(profile.botTitle, "Helper")
        XCTAssertTrue(profile.gatewayRunning)
        XCTAssertEqual(profile.description, "Answers mail")
    }

    func testProfileRowIsLenient() throws {
        let profile = try XCTUnwrap(ProfileInfo(row: try json("""
        {"name": "default", "model": null, "provider": "nous", "skill_count": "7", "has_env": "yes", "gateway_running": 1}
        """)))
        XCTAssertTrue(profile.isDefault, "the root profile is the default when the row doesn't say")
        XCTAssertNil(profile.modelSummary, "no model, no summary, even with a provider")
        XCTAssertEqual(profile.skillCount, 7)
        XCTAssertFalse(profile.hasEnv, "a string isn't a boolean")
        XCTAssertEqual(ProfileInfo(row: try json(#"{"name": "x", "skill_count": -3}"#))?.skillCount, 0)
        XCTAssertEqual(ProfileInfo(row: try json(#"{"name": "x", "skill_count": true}"#))?.skillCount, 0)
        XCTAssertNil(ProfileInfo(row: try json(#"{"name": ""}"#)))
        XCTAssertEqual(ProfileInfo(row: try json(#"{"name": "m", "model": "gpt"}"#))?.modelSummary, "gpt")
    }

    func testProfileNameRules() {
        XCTAssertTrue(ProfileName.isValid("work"))
        XCTAssertTrue(ProfileName.isValid(" coder_2-b "))
        XCTAssertTrue(ProfileName.isValid("9lives"))
        XCTAssertFalse(ProfileName.isValid(""))
        XCTAssertFalse(ProfileName.isValid("-work"))
        XCTAssertFalse(ProfileName.isValid("_work"))
        XCTAssertFalse(ProfileName.isValid("Work"))
        XCTAssertFalse(ProfileName.isValid("wörk"))
        XCTAssertFalse(ProfileName.isValid("a b"))
        XCTAssertTrue(ProfileName.isValid(String(repeating: "a", count: 64)))
        XCTAssertFalse(ProfileName.isValid(String(repeating: "a", count: 65)))

        XCTAssertEqual(ProfileName.sanitize("My Profile"), "my-profile")
        XCTAssertEqual(ProfileName.sanitize("  Hello,  World!! "), "hello-world-")
        XCTAssertEqual(ProfileName.sanitize("--lead"), "lead")
        XCTAssertEqual(ProfileName.sanitize("work-"), "work-", "a trailing dash stays so the name remains typeable")
        XCTAssertEqual(ProfileName.sanitize("snake_case"), "snake-case")
        XCTAssertEqual(ProfileName.sanitize("Ünïcode"), "n-code")
    }

    func testProfileAnswersDecode() throws {
        let soul = ProfileSoul(response: try json(#"{"content": "Persona: brief", "exists": true}"#))
        XCTAssertEqual(soul, ProfileSoul(content: "Persona: brief", exists: true))
        XCTAssertEqual(ProfileSoul(response: try json(#"{"content": "", "exists": false}"#)).exists, false)
        XCTAssertEqual(ProfileSoul(response: try json(#"{"content": "hi"}"#)).exists, true, "older backends: content implies a file")
        XCTAssertEqual(ProfileSoul(response: [:]), ProfileSoul(content: "", exists: false))

        let activity = ProfileActivity(response: try json(#"{"active": "work", "current": "default"}"#))
        XCTAssertEqual(activity.active, "work")
        XCTAssertEqual(activity.current, "default")
        XCTAssertEqual(ProfileActivity(response: [:]), ProfileActivity())

        let created = CreatedProfile(response: try json(#"{"ok": true, "name": "work", "path": "/p/work", "soul_set": true}"#), requested: "x")
        XCTAssertEqual(created.name, "work")
        XCTAssertTrue(created.soulSet)
        XCTAssertFalse(CreatedProfile(response: try json(#"{"ok": true}"#), requested: "older").soulSet)
        XCTAssertEqual(CreatedProfile(response: [:], requested: "older").name, "older")

        let renamed = RenamedProfile(response: try json(#"{"ok": true, "name": "default", "display_name": "Ada"}"#), requested: "Ada")
        XCTAssertEqual(renamed.name, "default", "the root profile keeps its id")
        XCTAssertEqual(renamed.displayName, "Ada")

        let pending = ProfileDeletion(response: try json(#"{"ok": true, "settlement_pending": true, "retry_command": "hermes profile settle old"}"#))
        XCTAssertTrue(pending.settlementPending)
        XCTAssertEqual(pending.retryCommand, "hermes profile settle old")
        XCTAssertFalse(ProfileDeletion(response: try json(#"{"ok": true, "path": "/p"}"#)).settlementPending)
    }

    func testProfileNamesCompareLikeTheHost() {
        XCTAssertTrue(ProfilesStore.sameName("Work", " work "))
        XCTAssertFalse(ProfilesStore.sameName("work", "work2"))
    }

    func testPathSegmentsRefuseSlashes() {
        XCTAssertEqual(try DashboardClient.segment("work"), "work")
        XCTAssertEqual(try DashboardClient.segment("local-127.0.0.1:8283"), "local-127.0.0.1:8283")
        XCTAssertThrowsError(try DashboardClient.segment("../etc"))
        XCTAssertThrowsError(try DashboardClient.segment(""))
    }

    @MainActor
    func testSoulEditorTracksUnsavedEdits() throws {
        let client = try DashboardClient(settings: ConnectionSettings(dashboardURL: "http://127.0.0.1:9", username: "u", password: "p"))
        let editor = SoulEditorModel(client: client, profile: "work")
        XCTAssertFalse(editor.dirty, "nothing loaded, nothing to lose")
        editor.text = "typed before load"
        XCTAssertFalse(editor.dirty)
        editor.apply(ProfileSoul(content: "Be brief.", exists: true))
        XCTAssertFalse(editor.dirty)
        XCTAssertEqual(editor.text, "Be brief.")
        editor.text = "Be brief. Be kind."
        XCTAssertTrue(editor.dirty)
        editor.text = "Be brief."
        XCTAssertFalse(editor.dirty, "typing back the saved text is not a change")
        editor.apply(ProfileSoul(content: "", exists: false))
        XCTAssertFalse(editor.exists)
    }

    // MARK: Credential masks

    func testPreviewsShowWhatTheDashboardSent() {
        XCTAssertEqual(CredentialMask.display("«redacted:sk-o...mnop»"), "sk-o...mnop")
        XCTAssertEqual(CredentialMask.display("«redacted:***»"), CredentialMask.placeholder, "a short value's mask")
        XCTAssertEqual(CredentialMask.display("«redacted-secret»"), CredentialMask.placeholder)
        XCTAssertEqual(CredentialMask.display("«redacted:»"), CredentialMask.placeholder)
        XCTAssertEqual(CredentialMask.display("sk-o...mnop"), "sk-o...mnop", "an older backend's bare mask")
        XCTAssertEqual(CredentialMask.display("***"), CredentialMask.placeholder)
        XCTAssertNil(CredentialMask.display(nil))
        XCTAssertNil(CredentialMask.display(""))
    }

    func testLocalPreviewNeverShowsMoreThanTheDashboard() {
        // agent.redact.mask_secret: first and last four of a value of 12 or more, after control characters go.
        XCTAssertEqual(CredentialMask.localPreview("test-or-v1-abcdefghijklmnop"), "test...mnop")
        XCTAssertEqual(CredentialMask.localPreview("123456789012"), "1234...9012")
        XCTAssertEqual(CredentialMask.localPreview("12345678901"), CredentialMask.placeholder)
        XCTAssertEqual(CredentialMask.localPreview("short"), CredentialMask.placeholder)
        XCTAssertEqual(CredentialMask.localPreview("abcd\u{7}\u{7}efgh"), CredentialMask.placeholder, "control characters don't count")
        XCTAssertEqual(CredentialMask.localPreview("🔑🔑🔑🔑-middle-🗝🗝🗝🗝"), "🔑🔑🔑🔑...🗝🗝🗝🗝")
        let secret = "test-ant-0123456789abcdefghij"
        let preview = CredentialMask.localPreview(secret)
        XCTAssertFalse(preview.contains("0123456789"), "the middle of the key never shows")
        XCTAssertTrue(CredentialMask.isPreview(preview), "the dashboard refuses the preview as a value")
    }

    func testPreviewsAreRecognisedByShape() {
        XCTAssertTrue(CredentialMask.isPreview("«redacted:sk-o...mnop»"))
        XCTAssertTrue(CredentialMask.isPreview("«redacted-vault-secret»"))
        XCTAssertTrue(CredentialMask.isPreview("***"))
        XCTAssertTrue(CredentialMask.isPreview("sk-o...mnop"))
        XCTAssertFalse(CredentialMask.isPreview("sk-o...mnopq"))
        XCTAssertFalse(CredentialMask.isPreview("test-or-v1-real-key"))
        XCTAssertFalse(CredentialMask.isPreview("ab\nc...wxyz"), "the host's pattern doesn't match across lines")
        XCTAssertFalse(CredentialMask.isPreview("****"))

        XCTAssertTrue(CredentialMask.isEnvReference("${CUSTOM_LOCAL_API_KEY}"))
        XCTAssertFalse(CredentialMask.isEnvReference("${}"))
        XCTAssertFalse(CredentialMask.isEnvReference("${A}${B}"))
        XCTAssertFalse(CredentialMask.isEnvReference("sk-${A}"))
    }

    func testErrorsNeverEchoATypedKey() {
        let secret = "test-or-v1-0123456789abcdef"
        XCTAssertEqual(CredentialMask.scrub("Rejected key \(secret) (401) \(secret)", secret: " \(secret)\n"),
                       "Rejected key \(CredentialMask.placeholder) (401) \(CredentialMask.placeholder)")
        XCTAssertEqual(CredentialMask.scrub("abc in abcdef", secret: "abc"), "abc in abcdef", "too short to blank safely")

        let scrubbed = DashboardClient.scrubbed(DashboardError.http(400, #"{"detail": "bad value \#(secret)"}"#), secret: secret)
        guard case let .http(code, body)? = scrubbed as? DashboardError else { return XCTFail("still an HTTP error") }
        XCTAssertEqual(code, 400)
        XCTAssertFalse(body.contains(secret))
        XCTAssertFalse(scrubbed.localizedDescription.contains(secret))
        XCTAssertTrue(DashboardClient.scrubbed(DashboardError.timeout, secret: secret) is DashboardError)
    }

    // MARK: Env catalog

    private func catalog() throws -> EnvCatalog {
        EnvCatalog(response: try json("""
        {
          "OPENROUTER_API_KEY": {"is_set": true, "redacted_value": "«redacted:sk-o...1234»", "category": "provider",
            "is_password": true, "provider": "openrouter", "provider_label": "OpenRouter", "provider_primary": true,
            "description": "OpenRouter key", "url": "https://openrouter.ai/keys", "tools": [], "advanced": false},
          "OPENROUTER_BASE_URL": {"is_set": false, "redacted_value": null, "category": "provider", "is_password": false,
            "provider": "openrouter", "provider_label": "OpenRouter", "advanced": true, "description": "Base URL"},
          "ANTHROPIC_API_KEY": {"is_set": false, "category": "provider", "is_password": true,
            "provider_label": "Anthropic", "provider_primary": true},
          "ANTHROPIC_TOKEN": {"is_set": false, "category": "provider", "is_password": true, "provider_label": "Anthropic",
            "advanced": true},
          "DASHSCOPE_API_KEY": {"is_set": true, "redacted_value": "«redacted:***»", "category": "provider", "is_password": true,
            "description": "DashScope key",
            "provider_profiles": [
              {"provider": "alibaba", "provider_label": "DashScope (Qwen)", "primary": true, "description": "Qwen"},
              {"provider": "alibaba-coding-plan", "provider_label": "Alibaba Coding Plan", "primary": false}
            ]},
          "MYSTERY_SETTING": {"is_set": false, "category": "provider"},
          "GLM_BASE_URL": {"is_set": true, "redacted_value": "«redacted:http...v4»", "category": "provider"},
          "DEEPSEEK_API_KEY": {"is_set": false, "category": "provider", "is_password": false},
          "FIRECRAWL_API_KEY": {"is_set": true, "redacted_value": "«redacted:fc-1...9999»", "category": "tool", "is_password": true,
            "tools": ["web_extract"]},
          "TELEGRAM_BOT_TOKEN": {"is_set": true, "category": "messaging", "is_password": true, "channel_managed": true},
          "MY_CUSTOM": {"is_set": true, "category": "custom", "is_password": true, "custom": true},
          "": {"is_set": true},
          "BROKEN": "not an object"
        }
        """))
    }

    func testEnvRowsDecode() throws {
        let vars = try catalog()
        XCTAssertNil(vars[""])
        XCTAssertNil(vars["BROKEN"])
        let key = try XCTUnwrap(vars["OPENROUTER_API_KEY"])
        XCTAssertTrue(key.isSet)
        XCTAssertTrue(key.isSecret)
        XCTAssertEqual(key.preview, "sk-o...1234")
        XCTAssertEqual(key.label, "OPENROUTER")
        XCTAssertEqual(key.placeholder, "Paste OPENROUTER key")
        XCTAssertEqual(key.url, "https://openrouter.ai/keys")
        XCTAssertEqual(vars["DASHSCOPE_API_KEY"]?.preview, CredentialMask.placeholder)
        XCTAssertEqual(vars["DASHSCOPE_API_KEY"]?.providerRoutes.map(\.provider), ["alibaba", "alibaba-coding-plan"])
        XCTAssertNil(vars["ANTHROPIC_API_KEY"]?.preview, "an unset variable shows no preview")
        XCTAssertTrue(vars["DEEPSEEK_API_KEY"]?.isSecret == true, "a key by name even without the password flag")
        let url = try XCTUnwrap(vars["OPENROUTER_BASE_URL"])
        XCTAssertFalse(url.isSecret)
        XCTAssertEqual(url.placeholder, "https://…")
        XCTAssertEqual(url.fieldLabel, "Base URL")
        XCTAssertEqual(vars["FIRECRAWL_API_KEY"]?.tools, ["web_extract"])
        XCTAssertTrue(vars["MY_CUSTOM"]?.custom == true)
        XCTAssertEqual(EnvVar.prettyName("hf_token_x"), "Hf Token X")
    }

    func testProviderCardsGroupLikeTheDesktop() throws {
        let groups = try catalog().providerGroups()
        XCTAssertEqual(groups.map(\.name), ["OpenRouter", "Anthropic", "DeepSeek", "DashScope (Qwen)", "Alibaba Coding Plan"],
                       "by the desktop's priority, then name; Other and keyless providers are left out")

        let openRouter = groups[0]
        XCTAssertEqual(openRouter.primary.key, "OPENROUTER_API_KEY")
        XCTAssertEqual(openRouter.advanced.map(\.key), ["OPENROUTER_BASE_URL"])
        XCTAssertTrue(openRouter.hasAnySet)
        XCTAssertEqual(openRouter.docsURL, "https://openrouter.ai/keys")
        XCTAssertEqual(openRouter.description, "Aggregator for hundreds of frontier models")
        XCTAssertEqual(openRouter.keys, ["OPENROUTER_API_KEY", "OPENROUTER_BASE_URL"])

        let anthropic = groups[1]
        XCTAssertEqual(anthropic.primary.key, "ANTHROPIC_API_KEY")
        XCTAssertTrue(anthropic.advanced.isEmpty, "an unset alias key gets no second field")
        XCTAssertFalse(anthropic.hasAnySet)

        XCTAssertEqual(groups[2].primary.key, "DEEPSEEK_API_KEY", "grouped by prefix when the backend names no provider")

        let qwen = groups[3], plan = groups[4]
        XCTAssertEqual(qwen.primary.key, "DASHSCOPE_API_KEY")
        XCTAssertEqual(plan.primary.key, "DASHSCOPE_API_KEY", "one shared key, two cards")
        XCTAssertEqual(qwen.description, "Alibaba Cloud DashScope — Qwen and multi-vendor models")
        XCTAssertEqual(plan.description, "DashScope key", "no overlay: the variable's own description")
        XCTAssertEqual(plan.priority, 99)
    }

    func testAliasKeysThatAreSetStayClearable() throws {
        var vars = try catalog()
        vars.vars["ANTHROPIC_TOKEN"]?.isSet = true
        let anthropic = try XCTUnwrap(vars.providerGroups().first { $0.name == "Anthropic" })
        XCTAssertEqual(anthropic.primary.key, "ANTHROPIC_API_KEY", "the provider's own key stays the main field")
        XCTAssertEqual(anthropic.advanced.map(\.key), ["ANTHROPIC_TOKEN"])
    }

    func testCatalogRecordsSavesUntilReload() throws {
        var vars = try catalog()
        vars.update("ANTHROPIC_API_KEY", isSet: true, preview: CredentialMask.localPreview("test-ant-0123456789abcdef"))
        XCTAssertEqual(vars["ANTHROPIC_API_KEY"]?.preview, "test...cdef")
        XCTAssertTrue(vars.providerGroups().first { $0.name == "Anthropic" }?.hasAnySet == true)
        vars.update("ANTHROPIC_API_KEY", isSet: false, preview: nil)
        XCTAssertNil(vars["ANTHROPIC_API_KEY"]?.preview)
        vars.update("NOT_LISTED", isSet: true, preview: "x")
        XCTAssertNil(vars["NOT_LISTED"])

        XCTAssertEqual(vars.entries(categories: ["tool"]).map(\.key), ["FIRECRAWL_API_KEY"])
        XCTAssertTrue(vars.entries(categories: ["messaging"]).isEmpty, "the Messaging page owns channel credentials")
    }

    func testKeySearchMatchesNamesBlurbsAndVariables() throws {
        let groups = try catalog().providerGroups()
        XCTAssertEqual(APIKeysScreen.filter(groups, query: "").count, groups.count)
        XCTAssertEqual(APIKeysScreen.filter(groups, query: " router ").map(\.name), ["OpenRouter"])
        XCTAssertEqual(APIKeysScreen.filter(groups, query: "base_url").map(\.name), ["OpenRouter"])
        XCTAssertEqual(APIKeysScreen.filter(groups, query: "dashscope").map(\.name), ["DashScope (Qwen)", "Alibaba Coding Plan"])
        XCTAssertTrue(APIKeysScreen.filter(groups, query: "nothing-like-this").isEmpty)
    }

    func testProviderPrefixesPickTheLongestMatch() {
        XCTAssertEqual(ProviderCatalog.group(for: "KIMI_CN_API_KEY"), "Kimi (China)")
        XCTAssertEqual(ProviderCatalog.group(for: "KIMI_API_KEY"), "Kimi / Moonshot")
        XCTAssertEqual(ProviderCatalog.group(for: "GEMINI_API_KEY"), "Gemini")
        XCTAssertEqual(ProviderCatalog.group(for: "SOMETHING_ELSE"), ProviderCatalog.other)
        XCTAssertEqual(ProviderCatalog.meta(for: "Gemini")?.docsURL, "https://aistudio.google.com/app/apikey")
    }

    func testCredentialCheckDecodes() throws {
        XCTAssertTrue(CredentialCheck(response: try json(#"{"ok": false, "reachable": true, "message": "rejected"}"#)).rejected)
        XCTAssertFalse(CredentialCheck(response: try json(#"{"ok": false, "reachable": false, "message": ""}"#)).rejected,
                       "a probe that couldn't run doesn't block the save")
        XCTAssertFalse(CredentialCheck(response: try json(#"{"ok": true, "reachable": false}"#)).rejected)
    }

    // MARK: Accounts

    func testAccountsDecodeAndSort() throws {
        let rows = try json("""
        {"providers": [
          {"id": "claude-code", "name": "Claude Code", "flow": "external", "cli_command": "claude setup-token",
           "docs_url": "https://docs.claude.com", "disconnect_hint": "Managed outside Hermes", "disconnect_command": "rm -f creds",
           "disconnectable": false, "status": {"logged_in": true, "source_label": "Keychain", "token_preview": "ab12"}},
          {"id": "nous", "name": "Nous Portal", "flow": "device_code", "cli_command": "hermes auth add nous",
           "docs_url": "javascript:alert(1)", "status": {"logged_in": true, "free_tier": true}},
          {"id": "zeta-plugin", "name": "Zeta", "flow": "external", "status": {"logged_in": false}},
          {"id": "openai-codex", "name": "ChatGPT", "flow": "device_code", "disconnectable": true,
           "status": {"logged_in": true, "account_tier": "Plus"}},
          {"name": "no id"}
        ]}
        """)
        let accounts = OAuthAccount.sorted((rows["providers"] as? [JSON] ?? []).compactMap(OAuthAccount.init(row:)))
        XCTAssertEqual(accounts.map(\.id), ["nous", "openai-codex", "claude-code", "zeta-plugin"])

        let nous = accounts[0]
        XCTAssertEqual(nous.flow, .deviceCode)
        XCTAssertTrue(nous.status.loggedIn)
        XCTAssertFalse(nous.isConnected, "the free tier is never connected")
        XCTAssertTrue(nous.signsInFromPhone)
        XCTAssertNil(nous.docsURL, "only http(s) pages open")
        XCTAssertEqual(nous.title, "Nous Portal")

        let codex = accounts[1]
        XCTAssertTrue(codex.isConnected)
        XCTAssertTrue(codex.canDisconnect)
        XCTAssertEqual(codex.title, "ChatGPT or Codex Subscription")
        XCTAssertEqual(codex.status.accountTier, "Plus")

        let claude = accounts[2]
        XCTAssertEqual(claude.flow, .external)
        XCTAssertFalse(claude.canDisconnect)
        XCTAssertFalse(claude.signsInFromPhone)
        XCTAssertEqual(claude.disconnectCommand, "rm -f creds")
        XCTAssertEqual(claude.status.tokenPreview, "ab12")

        let zeta = accounts[3]
        XCTAssertFalse(zeta.canDisconnect, "external accounts can't be cleared when the backend doesn't say")
        XCTAssertEqual(zeta.title, "Zeta")
        XCTAssertEqual(OAuthAccount(id: "x", name: "X", flow: .deviceCode).canDisconnect, true)
        XCTAssertEqual(OAuthAccount.Flow("pkce"), .pkce)
        XCTAssertEqual(OAuthAccount.Flow("magic"), .other("magic"))
    }

    func testDeviceCodeStartDecodes() throws {
        let code = try XCTUnwrap(OAuthDeviceCode(response: try json("""
        {"session_id": "s1", "flow": "device_code", "user_code": "ABCD-EFGH",
         "verification_url": "https://portal.example.com/device", "expires_in": 600, "poll_interval": 0}
        """)))
        XCTAssertEqual(code.sessionID, "s1")
        XCTAssertEqual(code.userCode, "ABCD-EFGH")
        XCTAssertEqual(code.verificationURL.host, "portal.example.com")
        XCTAssertEqual(code.expiresIn, 600)
        XCTAssertEqual(code.pollInterval, 1)
        XCTAssertEqual(OAuthDeviceCode(response: try json(#"{"session_id": "s", "user_code": "C", "verification_url": "https://x.y/d"}"#))?.expiresIn, 900)
        XCTAssertNil(OAuthDeviceCode(response: try json(#"{"session_id": "s", "flow": "pkce", "auth_url": "https://x.y/a", "expires_in": 60}"#)),
                     "a PKCE start needs a browser on the host")
        XCTAssertNil(OAuthDeviceCode(response: try json(#"{"session_id": "s", "user_code": "C", "verification_url": "file:///etc/passwd"}"#)))
        XCTAssertNil(OAuthDeviceCode(response: try json(#"{"session_id": "s", "verification_url": "https://x.y/d"}"#)))
    }

    func testPollAnswersDecode() throws {
        XCTAssertFalse(OAuthPoll(response: try json(#"{"session_id": "s", "status": "pending"}"#)).isFinished)
        let approved = OAuthPoll(response: try json("""
        {"session_id": "s", "status": "approved", "account_email": "user@example.com", "model": "hermes-4",
         "handoff_status": {"state": "claimed", "lines": ["Moved 2 apps.", " "]}}
        """))
        XCTAssertEqual(approved.state, .approved)
        XCTAssertTrue(approved.isFinished)
        XCTAssertEqual(approved.accountEmail, "user@example.com")
        XCTAssertEqual(approved.model, "hermes-4")
        XCTAssertEqual(approved.handoffLines, ["Moved 2 apps."])

        let denied = OAuthPoll(response: try json(#"{"status": "denied", "error_message": null}"#))
        XCTAssertEqual(denied.failureText, "The sign-in was declined.")
        let failed = OAuthPoll(response: try json(#"{"status": "error", "error_message": "Account service is busy."}"#))
        XCTAssertEqual(failed.failureText, "Account service is busy.")
        XCTAssertEqual(OAuthPoll(response: try json(#"{"status": "cancelled"}"#)).state, .other("cancelled"))
        XCTAssertTrue(OAuthPoll(response: try json(#"{"status": "cancelled"}"#)).isFinished)
        XCTAssertEqual(OAuthPoll(state: .expired).failureText, "The code expired before it was approved. Try again.")
    }

    // MARK: Custom endpoints

    func testCustomEndpointsDecode() throws {
        let list = CustomEndpointList(response: try json("""
        {"current": {"provider": "local-vllm", "model": "qwen3", "base_url": "http://box:8000/v1"},
         "endpoints": [
           {"id": "local-vllm", "name": "Local vLLM", "base_url": "http://box:8000/v1", "model": "qwen3",
            "models": ["qwen3", "llama"], "api_mode": "chat_completions", "context_length": 32768, "discover_models": false,
            "has_api_key": true, "api_key_preview": "${CUSTOM_LOCAL_VLLM_API_KEY}", "is_current": true},
           {"id": "zy", "name": "Zyphra", "base_url": "https://api.zyphra.com/v1", "model": "", "models": [],
            "api_mode": "bogus", "context_length": null, "has_api_key": true, "api_key_preview": "«redacted:zy-1...abcd»"},
           {"id": "nourl", "name": "Broken"}
         ], "ok": true, "id": "zy"}
        """))
        XCTAssertEqual(list.endpoints.map(\.id), ["local-vllm", "zy"])
        XCTAssertEqual(list.currentProvider, "local-vllm")
        XCTAssertEqual(list.currentModel, "qwen3")
        XCTAssertEqual(list.savedID, "zy")

        let vllm = list.endpoints[0]
        XCTAssertTrue(vllm.isCurrent)
        XCTAssertEqual(vllm.apiMode, .chatCompletions)
        XCTAssertEqual(vllm.contextLength, 32768)
        XCTAssertFalse(vllm.discoverModels)
        XCTAssertEqual(vllm.models, ["qwen3", "llama"])
        XCTAssertEqual(vllm.keyDisplay, "${CUSTOM_LOCAL_VLLM_API_KEY}")

        let zyphra = list.endpoints[1]
        XCTAssertEqual(zyphra.apiMode, .auto)
        XCTAssertNil(zyphra.contextLength)
        XCTAssertTrue(zyphra.discoverModels)
        XCTAssertEqual(zyphra.keyDisplay, "zy-1...abcd")
        XCTAssertFalse(zyphra.isCurrent)
    }

    func testEndpointDraftPayload() throws {
        var draft = CustomEndpointDraft()
        draft.name = " Local "
        draft.baseURL = "http://box:8000/v1 "
        draft.model = "qwen3"
        draft.contextLength = "abc"
        XCTAssertNil(draft.problem)
        var body = draft.payload()
        XCTAssertEqual(body["name"] as? String, "Local")
        XCTAssertEqual(body["base_url"] as? String, "http://box:8000/v1")
        XCTAssertEqual(body["api_mode"] as? String, "")
        XCTAssertEqual(body["make_default"] as? Bool, true)
        XCTAssertEqual(body["discover_models"] as? Bool, true)
        XCTAssertNil(body["id"], "a new endpoint has no id")
        XCTAssertNil(body["api_key"], "an empty key keeps the stored one")
        XCTAssertNil(body["context_length"])
        XCTAssertNil(body["models"])

        draft.id = "local"
        draft.apiKey = "  test-local-123456789  "
        draft.contextLength = "65536"
        draft.apiMode = .anthropicMessages
        let detail = try XCTUnwrap(EndpointModelDetail(row: try json(#"{"id": "gpt-x-high", "canonical_model": "gpt-x", "reasoning_effort": "high"}"#)))
        body = draft.payload(models: ["qwen3", "gpt-x-high"], details: [detail])
        XCTAssertEqual(body["id"] as? String, "local")
        XCTAssertEqual(body["api_key"] as? String, "test-local-123456789")
        XCTAssertEqual(body["context_length"] as? Int, 65536)
        XCTAssertEqual(body["api_mode"] as? String, "anthropic_messages")
        XCTAssertEqual(body["models"] as? [String], ["qwen3", "gpt-x-high"])
        let details = try XCTUnwrap(body["model_details"] as? [JSON])
        XCTAssertEqual(details.first?["canonical_model"] as? String, "gpt-x")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))
    }

    func testEndpointDraftProblems() throws {
        var draft = CustomEndpointDraft()
        XCTAssertNotNil(draft.problem)
        draft.name = "Local"
        draft.baseURL = "box:8000"
        draft.model = "m"
        XCTAssertNotNil(draft.problem, "the URL needs a scheme")
        draft.baseURL = "ftp://box/v1"
        XCTAssertNotNil(draft.problem)
        draft.baseURL = "https://box/v1"
        XCTAssertNil(draft.problem)
        draft.apiKey = "${CUSTOM_LOCAL_API_KEY}"
        XCTAssertNotNil(draft.problem, "the displayed key reference is not a key")
        draft.apiKey = "«redacted:sk-1...abcd»"
        XCTAssertNotNil(draft.problem)
        draft.apiKey = "test-real-key-value"
        XCTAssertNil(draft.problem)
        draft.model = " "
        XCTAssertNotNil(draft.problem)

        let editing = CustomEndpointDraft(editing: try XCTUnwrap(CustomEndpoint(row: try json("""
        {"id": "e", "name": "E", "base_url": "https://e/v1", "model": "m", "context_length": 8192, "is_current": false,
         "has_api_key": true, "api_key_preview": "${K}", "api_mode": "codex_responses"}
        """))))
        XCTAssertEqual(editing.id, "e")
        XCTAssertEqual(editing.apiKey, "", "a stored key is never put back in the form")
        XCTAssertEqual(editing.contextLength, "8192")
        XCTAssertFalse(editing.makeDefault)
        XCTAssertEqual(editing.apiMode, .responses)
    }

    func testEndpointProbeDecodes() throws {
        let ok = EndpointProbe(response: try json("""
        {"ok": true, "reachable": true, "message": "", "models": ["a", "b"],
         "model_details": [{"id": "a"}, {"id": "b", "canonical_model": "a", "reasoning_effort": "high"}, {"x": 1}],
         "transport_checked": "chat_completions", "resolved_base_url": "http://box:8000/v1"}
        """))
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.details.map(\.id), ["a", "b"])
        XCTAssertEqual(ok.resolvedBaseURL, "http://box:8000/v1")
        XCTAssertEqual(ok.summary, "Reachable (Chat Completions) · 2 models.")
        XCTAssertEqual(EndpointProbe(response: try json(#"{"ok": false, "reachable": false, "message": "Could not reach x/models.", "models": []}"#)).summary,
                       "Could not reach x/models.")
        XCTAssertEqual(EndpointProbe(response: try json(#"{"ok": false, "reachable": false, "models": []}"#)).summary,
                       "Couldn't reach the endpoint.")
        XCTAssertEqual(EndpointProbe(response: try json(#"{"ok": true, "models": ["a"], "transport_checked": ""}"#)).summary,
                       "Reachable · 1 model.")
    }

    // MARK: Errors

    func testDashboardErrorDetails() {
        XCTAssertEqual(DashboardDetail.message(#"{"detail": "Profile 'x' already exists"}"#), "Profile 'x' already exists")
        XCTAssertEqual(DashboardDetail.message(#"{"detail": [{"loc": ["body", "name"], "msg": "Field required"}]}"#), "Field required")
        XCTAssertEqual(DashboardDetail.message("plain text failure"), "plain text failure")
        XCTAssertNil(DashboardDetail.message("<html>502</html>"))
        XCTAssertNil(DashboardDetail.message(""))
        XCTAssertEqual(DashboardError.http(409, #"{"detail": "No stored credentials were removed for X."}"#).dashboardMessage,
                       "No stored credentials were removed for X.")
        XCTAssertEqual(DashboardError.http(502, "<html></html>").dashboardMessage, "Hermes answered 502.")
        XCTAssertEqual(DashboardError.rpc("Nope.").dashboardMessage, "Nope.")
    }
}
