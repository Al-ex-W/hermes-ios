import XCTest
@testable import HermesVoice

/// Records the REST calls the Messaging and Webhooks routes make and answers them from canned responses.
private final class RecordingMessagingTransport: CapabilitiesTransport {
    struct Call {
        let method: String
        let path: String
        let query: [String: String]
        let body: JSON?
    }

    private(set) var calls: [Call] = []
    /// `"METHOD path"` → the answer.
    var responses: [String: Any] = [:]
    /// `"METHOD path"` → the error that call throws.
    var failures: [String: Error] = [:]

    func request(_ method: String, _ path: String, query: [String: String], body: JSON?) async throws -> Any {
        calls.append(Call(method: method, path: path, query: query, body: body))
        let key = "\(method) \(path)"
        if let failure = failures[key] { throw failure }
        return responses[key] ?? JSON()
    }

    func last(_ method: String, _ path: String) -> Call? {
        calls.last { $0.method == method && $0.path == path }
    }
}

/// The Messaging and Webhooks screens' decoders, request bodies, onboarding state machines, allowlist editing,
/// gateway restart watching and secret handling (cases ported from the desktop's and web dashboard's behaviour).
final class MessagingTests: XCTestCase {
    private func json(_ text: String) throws -> JSON {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
    }

    private let telegramRow = """
    {"id": "telegram", "name": "Telegram", "description": "Telegram bot", "docs_url": "https://docs.example.com/telegram",
     "enabled": true, "configured": true, "gateway_running": true, "state": "connected", "error_code": null,
     "error_message": null, "updated_at": "2026-10-27T09:00:00Z",
     "home_channel": {"platform": "telegram", "chat_id": 12345, "name": "Home"},
     "env_vars": [
       {"key": "TELEGRAM_BOT_TOKEN", "required": true, "is_set": true, "redacted_value": "«redacted:1234...wxyz»",
        "value": null, "description": "Bot token", "prompt": "Telegram bot token", "help": "", "url": "https://t.me/BotFather",
        "is_password": true, "is_list": false, "advanced": false},
       {"key": "TELEGRAM_ALLOWED_USERS", "required": false, "is_set": true, "redacted_value": "«redacted:***»",
        "value": "111,222", "description": "Allowed users", "prompt": "Allowed Telegram users", "url": null,
        "is_password": false, "is_list": true, "advanced": false},
       {"key": "TELEGRAM_PROXY", "required": false, "is_set": false, "redacted_value": null, "value": null,
        "description": "Proxy", "prompt": "Proxy URL", "url": "javascript:alert(1)", "is_password": false, "advanced": false},
       {"key": "VOICE_TOOLS_OPENAI_KEY", "required": false, "is_set": false, "is_password": true}
     ],
     "ingress_url": null}
    """

    // MARK: Platforms

    func testPlatformDecodesEveryField() throws {
        let platform = try XCTUnwrap(MessagingPlatform(row: try json(telegramRow)))
        XCTAssertEqual(platform.id, "telegram")
        XCTAssertEqual(platform.name, "Telegram")
        XCTAssertEqual(platform.docsURL?.absoluteString, "https://docs.example.com/telegram")
        XCTAssertTrue(platform.enabled)
        XCTAssertTrue(platform.configured)
        XCTAssertTrue(platform.gatewayRunning)
        XCTAssertEqual(platform.state, "connected")
        XCTAssertEqual(platform.tone, .good)
        XCTAssertEqual(platform.homeChannel?.chatID, "12345")
        XCTAssertEqual(platform.envVars.map(\.key), ["TELEGRAM_BOT_TOKEN", "TELEGRAM_ALLOWED_USERS", "TELEGRAM_PROXY"],
                       "a voice knob is stripped from the card")

        let token = try XCTUnwrap(platform.field("TELEGRAM_BOT_TOKEN"))
        XCTAssertTrue(token.required)
        XCTAssertTrue(token.isPassword)
        XCTAssertFalse(token.isList)
        XCTAssertEqual(token.savedPreview, "1234...wxyz", "the sentinel shows its preview, never a value to send back")
        XCTAssertEqual(token.url?.host, "t.me")

        let allowed = try XCTUnwrap(platform.field("TELEGRAM_ALLOWED_USERS"))
        XCTAssertTrue(allowed.isList)
        XCTAssertEqual(allowed.value, "111,222")
        XCTAssertEqual(allowed.savedPreview, CredentialMask.placeholder)

        let proxy = try XCTUnwrap(platform.field("TELEGRAM_PROXY"))
        XCTAssertNil(proxy.url, "only web links open")
        XCTAssertNil(proxy.savedPreview)
        XCTAssertFalse(proxy.isList, "absent is_list (older backends): a plain field")
    }

    func testPlatformDecoderIsLenient() throws {
        XCTAssertNil(MessagingPlatform(row: try json(#"{"name": "No id"}"#)))
        let bare = try XCTUnwrap(MessagingPlatform(row: try json(#"{"id": "matrix", "enabled": "yes", "env_vars": [{"prompt": "x"}, 3]}"#)))
        XCTAssertEqual(bare.name, "matrix")
        XCTAssertFalse(bare.enabled, "a string is not a flag")
        XCTAssertTrue(bare.envVars.isEmpty)
        XCTAssertNil(bare.whatsappSetup)
        XCTAssertEqual(bare.tone, .muted)

        let secretList = try XCTUnwrap(MessagingEnvField(row: try json(#"{"key": "X_ALLOWED_USERS", "is_password": true, "is_list": true}"#)))
        XCTAssertFalse(secretList.isList, "a secret is never edited as a list")

        let whatsapp = try XCTUnwrap(MessagingPlatform(row: try json("""
        {"id": "whatsapp", "name": "WhatsApp", "enabled": true, "state": "pending_restart",
         "whatsapp_setup": {"mode": "self-chat", "allowed_users_set": true, "home_channel_set": false},
         "ingress_url": "https://host.example/p/work/whatsapp"}
        """)))
        XCTAssertEqual(whatsapp.whatsappSetup?.mode, .selfChat)
        XCTAssertEqual(whatsapp.whatsappSetup?.allowedUsersSet, true)
        XCTAssertEqual(whatsapp.ingressURL, "https://host.example/p/work/whatsapp")
        XCTAssertEqual(whatsapp.tone, .warn)
    }

    func testToneFollowsTheDesktop() {
        XCTAssertEqual(MessagingTone.of(enabled: false, state: "connected"), .muted, "off wins")
        XCTAssertEqual(MessagingTone.of(enabled: true, state: "connected"), .good)
        XCTAssertEqual(MessagingTone.of(enabled: true, state: "fatal"), .bad)
        XCTAssertEqual(MessagingTone.of(enabled: true, state: "startup_failed"), .bad)
        XCTAssertEqual(MessagingTone.of(enabled: true, state: "disabled"), .muted)
        for waiting in ["connecting", "retrying", "pending_restart", "gateway_stopped", "not_configured", nil] {
            XCTAssertEqual(MessagingTone.of(enabled: true, state: waiting), .warn, "\(waiting ?? "nil") waits on something")
        }
        XCTAssertEqual(MessagingTone.filterOrder.map(\.filterLabel), ["Errors", "Needs attention", "Connected", "Inactive"])
        XCTAssertEqual(MessagingCopy.stateLabel("gateway_stopped"), "Messaging gateway stopped")
        XCTAssertEqual(MessagingCopy.stateLabel("some_new_state"), "some new state")
        XCTAssertEqual(MessagingCopy.stateLabel(nil), "Unknown")
    }

    func testSearchAndStatusFilter() {
        var platform = MessagingPlatform(id: "discord", name: "Discord")
        platform.description = "Discord bot for servers"
        platform.enabled = true
        platform.state = "fatal"
        XCTAssertTrue(platform.matches(tone: nil, query: ""))
        XCTAssertTrue(platform.matches(tone: .bad, query: "  SERVERS "))
        XCTAssertTrue(platform.matches(tone: nil, query: "fatal"), "the state is searchable")
        XCTAssertFalse(platform.matches(tone: .good, query: ""))
        XCTAssertFalse(platform.matches(tone: nil, query: "slack"))
    }

    func testFieldCopyAndAdvanced() throws {
        var token = MessagingEnvField(key: "TELEGRAM_BOT_TOKEN")
        token.prompt = "Telegram bot token"
        XCTAssertEqual(MessagingCopy.copy(token).label, "Bot token")
        XCTAssertEqual(MessagingCopy.copy(token).placeholder, "Paste Telegram bot token")
        XCTAssertFalse(MessagingCopy.copy(token).advanced)
        XCTAssertTrue(MessagingCopy.copy(MessagingEnvField(key: "TELEGRAM_PROXY")).advanced, "FIELD_COPY marks it advanced")
        var plugin = MessagingEnvField(key: "IRC_SERVER")
        plugin.advanced = true
        plugin.description = "IRC server"
        let copy = MessagingCopy.copy(plugin)
        XCTAssertEqual(copy.label, "IRC_SERVER", "no prompt: the key")
        XCTAssertEqual(copy.help, "IRC server")
        XCTAssertTrue(copy.advanced, "the backend's flag counts too")
        XCTAssertTrue(MessagingEnvField(key: "TTS_PROVIDER").isStripped)
        XCTAssertTrue(MessagingEnvField(key: "VOICE").isStripped)
        XCTAssertFalse(MessagingEnvField(key: "DISCORD_BOT_TOKEN").isStripped)
    }

    // MARK: Setup edits

    func testPlatformChangesTrimSkipBlanksAndClearEmptiedLists() throws {
        let platform = try XCTUnwrap(MessagingPlatform(row: try json(telegramRow)))
        XCTAssertFalse(MessagingPlatformUpdate.changes(platform, draft: [:]).hasChanges)
        XCTAssertFalse(MessagingPlatformUpdate.changes(platform, draft: ["TELEGRAM_BOT_TOKEN": "   "]).hasChanges,
                       "a blank secret is untouched, not a clear")

        let update = MessagingPlatformUpdate.changes(platform, draft: [
            "TELEGRAM_BOT_TOKEN": "  123:abc  ",
            "TELEGRAM_ALLOWED_USERS": "",
            "TELEGRAM_PROXY": "",
        ])
        XCTAssertEqual(update.env, ["TELEGRAM_BOT_TOKEN": "123:abc"])
        XCTAssertEqual(update.clearEnv, ["TELEGRAM_ALLOWED_USERS"], "a saved allowlist emptied in its editor is cleared")
        XCTAssertTrue(update.hasChanges)
        let body = update.body
        XCTAssertEqual(body["env"] as? [String: String], ["TELEGRAM_BOT_TOKEN": "123:abc"])
        XCTAssertEqual(body["clear_env"] as? [String], ["TELEGRAM_ALLOWED_USERS"])
        XCTAssertNil(body["enabled"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))

        var toggle = MessagingPlatformUpdate()
        toggle.enabled = false
        XCTAssertEqual(toggle.body as NSDictionary, ["enabled": false] as NSDictionary, "a switch sends only the flag")
        var clear = MessagingPlatformUpdate()
        clear.clearEnv = ["TELEGRAM_PROXY"]
        XCTAssertEqual(clear.body as NSDictionary, ["clear_env": ["TELEGRAM_PROXY"]] as NSDictionary)
    }

    func testAllowlistSplitAndJoin() {
        XCTAssertEqual(MessagingAllowlist.split(" 1, 2\n3,,  "), ["1", "2", "3"])
        XCTAssertEqual(MessagingAllowlist.split(nil), [])
        XCTAssertEqual(MessagingAllowlist.join([" 1", "2", "1", "", " "]), "1,2", "trimmed, unique, blanks dropped")
    }

    func testAllowlistRowsEditLikeTheDesktop() {
        var rows = MessagingAllowlistRows(nil)
        XCTAssertEqual(rows.rows.map(\.value), [""], "an empty list still has one box")
        XCTAssertTrue(rows.isLone)

        rows = MessagingAllowlistRows("111,222")
        XCTAssertEqual(rows.rows.map(\.value), ["111", "222"])
        XCTAssertFalse(rows.isLone)
        let first = rows.rows[0].id

        rows.change(first, to: "333, 444\n555")
        XCTAssertEqual(rows.rows.map(\.value), ["333", "444", "555", "222"], "a pasted list becomes one box per entry")
        XCTAssertEqual(rows.rows[0].id, first, "the edited box keeps its identity")
        XCTAssertEqual(Set(rows.rows.map(\.id)).count, 4, "new boxes get new ids")
        XCTAssertEqual(rows.joined, "333,444,555,222")

        let added = rows.add()
        XCTAssertEqual(rows.rows.last?.id, added)
        XCTAssertEqual(rows.joined, "333,444,555,222", "an empty box adds nothing")

        for row in rows.rows { rows.remove(row.id) }
        XCTAssertEqual(rows.rows.map(\.value), [""], "removing the last box leaves an empty one")
        XCTAssertEqual(rows.joined, "", "an emptied list saves as a clear")

        var paste = MessagingAllowlistRows("1")
        paste.change(paste.rows[0].id, to: ",")
        XCTAssertEqual(paste.rows.map(\.value), [""], "a paste of nothing leaves the box empty")
    }

    // MARK: Pairing and test results

    func testPairingDecodesAndLabels() throws {
        let lists = PairingLists(response: try json("""
        {"pending": [{"platform": "telegram", "request_id": "r1", "user_id": "42", "user_name": "Ada", "age_minutes": 0},
                     {"platform": "telegram", "request_id": "", "user_id": 7, "user_name": "", "age_minutes": 12},
                     {"platform": "discord", "user_id": "9"}, {"user_id": "no platform"}],
         "approved": [{"platform": "telegram", "user_id": "5", "user_name": "Bo", "approved_at": 1}]}
        """))
        XCTAssertEqual(lists.pending.count, 3)
        XCTAssertEqual(lists.pending(for: "telegram").map(\.id), ["telegram:42", "telegram:7"])
        let ada = lists.pending[0]
        XCTAssertEqual(ada.label, "Ada")
        XCTAssertEqual(ada.detail, "42 · just now")
        XCTAssertEqual(ada.requestID, "r1")
        let legacy = lists.pending[1]
        XCTAssertNil(legacy.requestID, "a legacy request has no id to approve on")
        XCTAssertEqual(legacy.label, "7")
        XCTAssertEqual(legacy.detail, "12m ago", "an unnamed requester doesn't repeat its id")
        XCTAssertEqual(lists.approved(for: "telegram").first?.label, "Bo")
        XCTAssertTrue(lists.approved(for: "discord").isEmpty)
    }

    func testPairingBodiesCarryTheProfile() {
        let user = PairingUser(platform: "telegram", userID: "42", requestID: "r1")
        XCTAssertEqual(MessagingAPI.approveBody(user, requestID: "r1", profile: "work") as NSDictionary,
                       ["platform": "telegram", "request_id": "r1", "profile": "work"] as NSDictionary)
        XCTAssertEqual(MessagingAPI.approveBody(user, requestID: "r1", profile: nil) as NSDictionary,
                       ["platform": "telegram", "request_id": "r1"] as NSDictionary, "never a code")
        XCTAssertEqual(MessagingAPI.revokeBody(user, profile: "work") as NSDictionary,
                       ["platform": "telegram", "user_id": "42", "profile": "work"] as NSDictionary)
    }

    func testTestResultSaysWhoCanReachTheBot() throws {
        let open = MessagingTestResult(response: try json(#"{"ok": true, "state": "connected", "message": "Telegram is connected."}"#))
        XCTAssertTrue(open.ok)
        XCTAssertFalse(open.unreachable)
        let denied = MessagingTestResult(response: try json("""
        {"ok": true, "state": "connected", "message": "Connected, but no users are authorized yet.", "auth_posture": "deny_all"}
        """))
        XCTAssertTrue(denied.unreachable, "connected but nobody gets through: a warning")
        let off = MessagingTestResult(response: try json(#"{"ok": false, "state": "disabled"}"#))
        XCTAssertFalse(off.ok)
        XCTAssertEqual(off.message, "The test didn't pass.")
    }

    // MARK: Onboarding decoders

    func testTelegramOnboardingDecoders() throws {
        let start = try XCTUnwrap(TelegramOnboardingStart(response: try json("""
        {"pairing_id": "p1", "suggested_username": "hermes_bot", "deep_link": "https://t.me/setupbot?start=abc",
         "qr_payload": "", "expires_at": "2026-10-27T12:10:00Z"}
        """)))
        XCTAssertEqual(start.deepLink.absoluteString, "https://t.me/setupbot?start=abc")
        XCTAssertEqual(start.qrPayload, "https://t.me/setupbot?start=abc", "no QR payload: the link itself")
        XCTAssertNotNil(TelegramOnboardingStart(response: try json(#"{"pairing_id": "p", "deep_link": "tg://resolve?domain=x"}"#)))
        XCTAssertNil(TelegramOnboardingStart(response: try json(#"{"pairing_id": "p", "deep_link": "file:///etc/passwd"}"#)))
        XCTAssertNil(TelegramOnboardingStart(response: try json(#"{"deep_link": "https://t.me/x"}"#)))

        XCTAssertEqual(TelegramOnboardingStatus(response: try json(#"{"status": "waiting", "expires_at": "x"}"#)), .waiting)
        XCTAssertEqual(TelegramOnboardingStatus(response: try json(#"{"status": "ready", "bot_username": "b", "owner_user_id": 123456}"#)),
                       .ready(botUsername: "b", ownerUserID: "123456"))

        let applied = OnboardingApplyResult(response: try json(#"{"ok": true, "platform": "telegram", "bot_username": "b", "restart_started": true, "restart_action": "gateway-restart"}"#))
        XCTAssertTrue(applied.restartStarted)
        XCTAssertFalse(applied.needsRestart, "no needs_restart: the opposite of restart_started")
        let refused = OnboardingApplyResult(response: try json(#"{"ok": true, "needs_restart": true, "restart_started": false, "restart_error": "busy", "restart_busy": true}"#))
        XCTAssertTrue(refused.needsRestart)
        XCTAssertTrue(refused.restartBusy)
        XCTAssertEqual(refused.restartError, "busy")
    }

    func testWhatsAppSessionDecoder() throws {
        let session = try XCTUnwrap(WhatsAppOnboardingSession(response: try json("""
        {"pairing_id": "w1", "status": "connected", "qr_payload": null, "expires_at": "2026-10-27T12:10:00.123456Z",
         "mode": "self-chat", "allowed_users": "", "account_id": "15551234567:3", "account_name": "Ada",
         "account_phone": "15551234567", "error": null}
        """)))
        XCTAssertEqual(session.mode, .selfChat)
        XCTAssertEqual(session.linkedAccountLabel, "+15551234567")
        XCTAssertEqual(session.chatURL?.absoluteString, "https://wa.me/15551234567")
        let unnamed = try XCTUnwrap(WhatsAppOnboardingSession(response: try json(#"{"pairing_id": "w2", "mode": "weird", "account_name": "Bo"}"#)))
        XCTAssertEqual(unnamed.status, "starting")
        XCTAssertEqual(unnamed.mode, .bot)
        XCTAssertEqual(unnamed.linkedAccountLabel, "Bo")
        XCTAssertNil(unnamed.chatURL)
        XCTAssertNil(WhatsAppOnboardingSession(response: try json(#"{"status": "waiting"}"#)))
    }

    func testOnboardingTiming() throws {
        let now = try date("2026-10-27T12:00:00Z")
        XCTAssertEqual(OnboardingTiming.remaining("2026-10-27T12:09:05Z", now: now), "9:05")
        XCTAssertEqual(OnboardingTiming.remaining("2026-10-27T12:00:00.500Z", now: now), "0:01", "a part second counts up")
        XCTAssertEqual(OnboardingTiming.remaining("2026-10-27T12:01:00.123456Z", now: now), "1:01", "the host's microseconds, counted up")
        XCTAssertNotNil(OnboardingTiming.date("2026-10-27T12:01:00.1234567+00:00"), "more digits than a formatter reads")
        XCTAssertEqual(OnboardingTiming.remaining("2026-10-27T14:02:00+02:00", now: now), "2:00")
        XCTAssertEqual(OnboardingTiming.remaining("2026-10-27T12:03:00", now: now), "3:00", "no zone: UTC")
        XCTAssertNil(OnboardingTiming.remaining("2026-10-27T11:59:59Z", now: now))
        XCTAssertNil(OnboardingTiming.remaining("soon", now: now))
        XCTAssertTrue(OnboardingTiming.isExpired("2026-10-27T12:00:00Z", now: now))
        XCTAssertFalse(OnboardingTiming.isExpired("", now: now), "an unreadable expiry never ends a pairing on its own")

        XCTAssertTrue(OnboardingTiming.isTerminal(DashboardError.http(410, #"{"detail": "Telegram setup expired."}"#)))
        XCTAssertFalse(OnboardingTiming.isTerminal(DashboardError.http(404, "")))
        XCTAssertFalse(OnboardingTiming.isTerminal(DashboardError.timeout))
        XCTAssertFalse(OnboardingTiming.isTerminal(URLError(.notConnectedToInternet)))
    }

    // MARK: Telegram state machine

    private func telegramStart(expiresAt: String = "2026-10-27T12:10:00Z") throws -> TelegramOnboardingStart {
        try XCTUnwrap(TelegramOnboardingStart(response: [
            "pairing_id": "p1", "deep_link": "https://t.me/setupbot?start=abc", "expires_at": expiresAt,
        ]))
    }

    func testTelegramSetupHappyPath() throws {
        var state = TelegramSetupState()
        state.error = "old"
        state.beginStart()
        XCTAssertEqual(state.phase, .starting)
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isPolling)

        state.started(try telegramStart())
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.isPolling)
        XCTAssertTrue(state.polled(.waiting), "still waiting: keep polling")

        XCTAssertFalse(state.polled(.ready(botUsername: "hermes_bot", ownerUserID: "123456789")))
        XCTAssertEqual(state.phase, .ready)
        XCTAssertFalse(state.isPolling)
        XCTAssertEqual(state.botUsername, "hermes_bot")
        XCTAssertEqual(state.detectedOwnerID, "123456789")
        XCTAssertEqual(state.allowedIDs, ["123456789"], "the detected owner is pre-allowed")

        state.newAllowedID = " 98765 "
        state.addAllowedID()
        XCTAssertEqual(state.allowedIDs, ["123456789", "98765"])
        XCTAssertEqual(state.newAllowedID, "")
        state.newAllowedID = "98765"
        state.addAllowedID()
        XCTAssertEqual(state.allowedIDs.count, 2, "no repeats")

        XCTAssertTrue(state.beginApply())
        XCTAssertEqual(state.phase, .applying)
        state.applied(OnboardingApplyResult(response: ["ok": true, "restart_started": true]))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.setup)
        XCTAssertTrue(state.allowedIDs.isEmpty)
        XCTAssertEqual(state.connectedBot, "hermes_bot", "the card still says which bot is connected")

        state.beginStart()
        XCTAssertNil(state.connectedBot, "a new setup forgets it")
    }

    func testTelegramSetupValidatesAllowedUsers() throws {
        var state = TelegramSetupState()
        state.beginStart()
        state.started(try telegramStart())
        _ = state.polled(.ready(botUsername: nil, ownerUserID: "12"))
        XCTAssertNil(state.detectedOwnerID, "too short for a Telegram id: not trusted")
        XCTAssertTrue(state.allowedIDs.isEmpty)

        for bad in ["abc", "12", "123456789012345678901", "-12345", "١٢٣٤"] {
            state.newAllowedID = bad
            state.addAllowedID()
            XCTAssertEqual(state.error, TelegramSetupState.numericOnly, bad)
        }
        XCTAssertTrue(state.allowedIDs.isEmpty)
        XCTAssertFalse(state.beginApply(), "nobody allowed: no apply")
        XCTAssertEqual(state.error, TelegramSetupState.addAtLeastOne)
        XCTAssertEqual(state.phase, .ready)

        state.newAllowedID = "123"
        state.addAllowedID()
        XCTAssertNil(state.error)
        XCTAssertTrue(state.beginApply())
        state.applyFailed("Telegram setup is not ready yet.")
        XCTAssertEqual(state.phase, .ready, "a failed apply goes back to review")
        XCTAssertEqual(state.error, "Telegram setup is not ready yet.")
        state.removeAllowedID("123")
        XCTAssertTrue(state.allowedIDs.isEmpty)
    }

    func testTelegramSetupPollFailures() throws {
        let now = try date("2026-10-27T12:00:00Z")
        var state = TelegramSetupState()
        state.beginStart()
        state.started(try telegramStart())
        XCTAssertTrue(state.pollFailed(URLError(.timedOut), message: "timed out", now: now), "transient: keep polling")
        XCTAssertEqual(state.error, "Still waiting for Telegram. Retrying after: timed out")
        XCTAssertTrue(state.polled(.waiting))
        XCTAssertNil(state.error, "an answer clears the hint")

        XCTAssertFalse(state.pollFailed(DashboardError.http(410, "claimed"), message: "claimed", now: now))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.setup)
        XCTAssertEqual(state.error, TelegramSetupState.pairingExpired)

        state.beginStart()
        state.started(try telegramStart(expiresAt: "2026-10-27T11:59:00Z"))
        XCTAssertFalse(state.pollFailed(URLError(.timedOut), message: "timed out", now: now), "past its expiry: over")
        XCTAssertEqual(state.error, TelegramSetupState.pairingExpired)

        state.beginStart()
        state.startFailed("Telegram setup service is unavailable.")
        XCTAssertEqual(state.phase, .idle)
        XCTAssertEqual(state.error, "Telegram setup service is unavailable.")
        XCTAssertFalse(state.polled(.waiting), "nothing to poll while idle")
    }

    // MARK: WhatsApp state machine

    private func whatsappSession(_ status: String, qr: String? = nil, error: String? = nil,
                                 expiresAt: String = "2026-10-27T12:10:00Z") throws -> WhatsAppOnboardingSession {
        var row: JSON = ["pairing_id": "w1", "status": status, "expires_at": expiresAt, "mode": "bot"]
        if let qr { row["qr_payload"] = qr }
        if let error { row["error"] = error }
        return try XCTUnwrap(WhatsAppOnboardingSession(response: row))
    }

    func testWhatsAppSetupPairsAndSaves() throws {
        var state = WhatsAppSetupState(configuredMode: .selfChat)
        XCTAssertEqual(state.mode, .selfChat, "starts on the saved mode")
        state.mode = .bot
        state.beginStart()
        XCTAssertTrue(state.busy)
        XCTAssertFalse(state.inputsLocked, "inputs lock once the bridge pairs")

        state.started(try whatsappSession("installing"))
        XCTAssertEqual(state.phase, .waiting)
        XCTAssertTrue(state.inputsLocked)
        XCTAssertEqual(state.statusLabel, "preparing")
        XCTAssertTrue(state.help.contains("Preparing"))

        XCTAssertTrue(state.polled(try whatsappSession("waiting", qr: "2@abc")))
        XCTAssertEqual(state.setup?.qrPayload, "2@abc")
        XCTAssertEqual(state.statusLabel, "waiting")
        XCTAssertTrue(state.polled(try whatsappSession("waiting", qr: "2@def")), "WhatsApp rotates its code")
        XCTAssertEqual(state.setup?.qrPayload, "2@def")

        XCTAssertFalse(state.polled(try whatsappSession("connected")))
        XCTAssertEqual(state.phase, .connected)
        XCTAssertTrue(state.linked)
        XCTAssertFalse(state.isPolling)

        XCTAssertTrue(state.beginApply())
        XCTAssertEqual(state.phase, .applying)
        state.applyFailed("WhatsApp is still saving its linked device.")
        XCTAssertEqual(state.phase, .connected)
        XCTAssertTrue(state.beginApply())
        state.applied()
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.setup)
        XCTAssertFalse(state.beginApply(), "nothing linked: no apply")
    }

    func testWhatsAppSetupStartsLinkedOrFails() throws {
        var state = WhatsAppSetupState()
        state.beginStart()
        state.started(try whatsappSession("connected"))
        XCTAssertEqual(state.phase, .connected, "saved credentials: linked without a QR code")

        state.beginStart()
        state.started(try whatsappSession("error", error: "npm install failed"))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.setup)
        XCTAssertEqual(state.error, "npm install failed")

        state.beginStart()
        state.started(try whatsappSession("waiting"))
        XCTAssertFalse(state.polled(try whatsappSession("error")))
        XCTAssertEqual(state.error, WhatsAppSetupState.failed)
        XCTAssertEqual(state.phase, .idle)

        state.adoptConfiguredMode(.selfChat)
        XCTAssertEqual(state.mode, .selfChat, "idle: follows the saved mode")
        state.beginStart()
        state.started(try whatsappSession("waiting"))
        state.adoptConfiguredMode(.bot)
        XCTAssertEqual(state.mode, .selfChat, "a pairing in progress keeps its mode")
    }

    func testWhatsAppSetupPollFailures() throws {
        let now = try date("2026-10-27T12:00:00Z")
        var state = WhatsAppSetupState()
        state.beginStart()
        state.started(try whatsappSession("waiting"))
        XCTAssertTrue(state.pollFailed(DashboardError.http(404, "not found"), message: "not found", now: now))
        XCTAssertEqual(state.error, "Still waiting for WhatsApp. Retrying after: not found")
        XCTAssertFalse(state.pollFailed(DashboardError.http(410, "expired"), message: "expired", now: now))
        XCTAssertEqual(state.error, WhatsAppSetupState.expired)
        XCTAssertEqual(state.phase, .idle)
    }

    func testWhatsAppInstructions() throws {
        var state = WhatsAppSetupState()
        XCTAssertTrue(state.pairingInstruction(hasSavedAllowedUsers: true).contains("keep the saved"))
        XCTAssertTrue(state.pairingInstruction(hasSavedAllowedUsers: false).contains("pairing code"))
        state.mode = .selfChat
        XCTAssertTrue(state.pairingInstruction(hasSavedAllowedUsers: false).contains("allow the linked account"))
        XCTAssertTrue(state.messageInstruction.contains("Message Yourself"))
        state.allowedUsers = "1555"
        XCTAssertTrue(state.pairingInstruction(hasSavedAllowedUsers: true).contains("pairing code"), "typed numbers replace the saved list")
    }

    // MARK: Routes and bodies

    func testMessagingRoutesAndBodies() async throws {
        let transport = RecordingMessagingTransport()
        transport.responses["GET /api/messaging/platforms"] = try json("{\"platforms\": [\(telegramRow)]}")
        transport.responses["PUT /api/messaging/platforms/telegram"] = ["ok": true, "hot_served": true]
        transport.responses["POST /api/pairing/clear-pending"] = ["ok": true, "cleared": 3]
        transport.responses["POST /api/messaging/telegram/onboarding/start"] = [
            "pairing_id": "p1", "deep_link": "https://t.me/setupbot?start=abc", "qr_payload": "https://t.me/setupbot?start=abc",
            "expires_at": "2026-10-27T12:10:00Z",
        ]
        transport.responses["POST /api/messaging/whatsapp/onboarding/start"] = ["pairing_id": "w1", "status": "starting"]
        transport.responses["POST /api/gateway/restart"] = ["ok": true, "pid": 10, "name": "gateway-restart"]
        let api = MessagingAPI(transport: transport, profile: "work")

        let platforms = try await api.platforms()
        XCTAssertEqual(platforms.map(\.id), ["telegram"])
        XCTAssertEqual(transport.last("GET", "/api/messaging/platforms")?.query, ["profile": "work"])

        var update = MessagingPlatformUpdate()
        update.env = ["TELEGRAM_BOT_TOKEN": "123:abc"]
        let result = try await api.update("telegram", update)
        XCTAssertTrue(result.hotServed)
        let put = try XCTUnwrap(transport.last("PUT", "/api/messaging/platforms/telegram"))
        XCTAssertEqual(put.query, ["profile": "work"])
        XCTAssertEqual(put.body?["env"] as? [String: String], ["TELEGRAM_BOT_TOKEN": "123:abc"])

        _ = try await api.test("telegram")
        XCTAssertNotNil(transport.last("POST", "/api/messaging/platforms/telegram/test"))

        try await api.approve(PairingUser(platform: "telegram", userID: "42", requestID: "r1"))
        XCTAssertEqual(transport.last("POST", "/api/pairing/approve")?.body?["request_id"] as? String, "r1")
        XCTAssertEqual(transport.last("POST", "/api/pairing/approve")?.body?["profile"] as? String, "work")
        do {
            try await api.approve(PairingUser(platform: "telegram", userID: "7"))
            XCTFail("a request without an id can't be approved")
        } catch {}
        try await api.revoke(PairingUser(platform: "telegram", userID: "42"))
        XCTAssertEqual(transport.last("POST", "/api/pairing/revoke")?.body?["user_id"] as? String, "42")
        let cleared = try await api.clearPending()
        XCTAssertEqual(cleared, 3)

        let start = try await api.startTelegram()
        XCTAssertEqual(start.pairingID, "p1")
        XCTAssertEqual(transport.last("POST", "/api/messaging/telegram/onboarding/start")?.body as NSDictionary?, [:] as NSDictionary)
        _ = try await api.telegramStatus("p1")
        XCTAssertNotNil(transport.last("GET", "/api/messaging/telegram/onboarding/p1"))
        _ = try await api.applyTelegram("p1", allowedUserIDs: ["123"])
        XCTAssertEqual(transport.last("POST", "/api/messaging/telegram/onboarding/p1/apply")?.body as NSDictionary?,
                       ["allowed_user_ids": ["123"], "profile": "work"] as NSDictionary)
        await api.cancelTelegram("p1")
        XCTAssertNotNil(transport.last("DELETE", "/api/messaging/telegram/onboarding/p1"))

        _ = try await api.startWhatsApp(mode: .selfChat, allowedUsers: " 1555 ", resetSession: true)
        XCTAssertEqual(transport.last("POST", "/api/messaging/whatsapp/onboarding/start")?.body as NSDictionary?,
                       ["mode": "self-chat", "allowed_users": "1555", "reset_session": true, "profile": "work"] as NSDictionary)
        _ = try await api.applyWhatsApp("w1", mode: .bot, allowedUsers: "")
        XCTAssertEqual(transport.last("POST", "/api/messaging/whatsapp/onboarding/w1/apply")?.body as NSDictionary?,
                       ["mode": "bot", "allowed_users": "", "profile": "work"] as NSDictionary)
        await api.cancelWhatsApp("w1")
        XCTAssertNotNil(transport.last("DELETE", "/api/messaging/whatsapp/onboarding/w1"))

        let restart = try await api.restartGateway()
        XCTAssertEqual(restart.name, "gateway-restart")
        XCTAssertEqual(transport.last("POST", "/api/gateway/restart")?.query, ["profile": "work"])
        let started = try await api.startGateway()
        XCTAssertEqual(started.name, "gateway-start", "named for its status poll")
        _ = try await api.actionStatus("gateway-start")
        XCTAssertNotNil(transport.last("GET", "/api/actions/gateway-start/status"))

        do {
            _ = try await api.test("../etc")
            XCTFail("a path in a segment is refused")
        } catch {}
        XCTAssertNil(transport.calls.first { $0.path.contains("..") })

        let unscoped = MessagingAPI(transport: transport, profile: nil)
        _ = try await unscoped.platforms()
        XCTAssertEqual(transport.calls.last?.query, [:], "nil: the dashboard's own profile")
        try await unscoped.revoke(PairingUser(platform: "telegram", userID: "42"))
        XCTAssertNil(transport.last("POST", "/api/pairing/revoke")?.body?["profile"])
    }

    func testATypedTokenNeverComesBackInAnError() async throws {
        let transport = RecordingMessagingTransport()
        let token = "123456789:AAH-secret-token-value"
        transport.failures["PUT /api/messaging/platforms/telegram"] =
            DashboardError.http(400, #"{"detail": "Invalid token \#(token) for TELEGRAM_BOT_TOKEN"}"#)
        let api = MessagingAPI(transport: transport, profile: nil)
        var update = MessagingPlatformUpdate()
        update.env = ["TELEGRAM_BOT_TOKEN": token]
        do {
            _ = try await api.update("telegram", update)
            XCTFail("the dashboard refused it")
        } catch {
            XCTAssertFalse(error.dashboardMessage.contains(token))
            XCTAssertFalse(error.localizedDescription.contains(token))
            XCTAssertTrue(error.dashboardMessage.contains(CredentialMask.placeholder))
        }
    }

    // MARK: Gateway restart watch

    private func status(running: Bool, exit: Int?) -> OpsActionStatus {
        OpsActionStatus(name: "gateway-restart", running: running, exitCode: exit)
    }

    func testGatewayRestartWatch() {
        var poll = GatewayActionWatch.poll()
        for _ in 0..<GatewayActionWatch.polls { _ = poll.recordFailure() }
        XCTAssertFalse(GatewayActionWatch.succeeded(poll), "refused end to end: the gateway never came back")

        poll = GatewayActionWatch.poll()
        XCTAssertEqual(poll.recordFailure(), .wait, "the restart window refuses for a while")
        XCTAssertEqual(poll.record(status(running: false, exit: nil)), .wait, "a fresh process never saw the action")
        XCTAssertEqual(poll.record(status(running: false, exit: 0)), .finished)
        XCTAssertTrue(GatewayActionWatch.succeeded(poll))

        poll = GatewayActionWatch.poll()
        XCTAssertEqual(poll.record(status(running: false, exit: 1)), .finished)
        XCTAssertFalse(GatewayActionWatch.succeeded(poll), "a recorded non-zero exit fails")

        poll = GatewayActionWatch.poll()
        var step = OpsActionPoll.Step.wait
        var polls = 0
        while step == .wait {
            step = poll.record(status(running: true, exit: nil))
            polls += 1
        }
        XCTAssertEqual(polls, GatewayActionWatch.polls)
        XCTAssertTrue(GatewayActionWatch.succeeded(poll), "still running when the window closes: a no-service gateway")

        poll = GatewayActionWatch.poll()
        _ = poll.record(status(running: false, exit: nil))
        while poll.recordFailure() == .wait {}
        XCTAssertTrue(GatewayActionWatch.succeeded(poll), "one answered poll proves the dashboard came back")
    }

    // MARK: Webhooks

    func testWebhookDecoders() throws {
        let snapshot = WebhooksSnapshot(response: try json("""
        {"enabled": true, "base_url": "https://host.example:8644",
         "subscriptions": [
           {"name": "github-push", "description": "Pushes", "events": ["push", " ", "pull_request"], "deliver": "telegram",
            "deliver_only": false, "prompt": "Summarize", "script": "", "skills": ["git"], "created_at": "2026-10-27T09:00:00Z",
            "url": "https://host.example:8644/webhooks/github-push", "secret_set": true, "enabled": false},
           {"name": "bare", "url": "https://host.example:8644/webhooks/bare"},
           {"description": "nameless"}
         ]}
        """))
        XCTAssertTrue(snapshot.enabled)
        XCTAssertEqual(snapshot.baseURL, "https://host.example:8644")
        XCTAssertEqual(snapshot.subscriptions.map(\.name), ["github-push", "bare"])
        let push = try XCTUnwrap(snapshot.route("github-push"))
        XCTAssertEqual(push.events, ["push", "pull_request"])
        XCTAssertEqual(push.deliverLabel, "Telegram")
        XCTAssertEqual(push.skills, ["git"])
        XCTAssertTrue(push.secretSet)
        XCTAssertFalse(push.enabled)
        let bare = try XCTUnwrap(snapshot.route("bare"))
        XCTAssertTrue(bare.enabled, "default-enabled: only an explicit false turns a route off")
        XCTAssertEqual(bare.deliver, "log")
        XCTAssertEqual(bare.deliverLabel, "Log")
        XCTAssertTrue(push.matches("PULL_"))
        XCTAssertTrue(push.matches("telegram"))
        XCTAssertFalse(push.matches("discord"))
        XCTAssertEqual(WebhookDelivery.label("github_comment"), "GitHub comment")
        XCTAssertEqual(WebhookDelivery.label("matrix"), "matrix")

        let created = try XCTUnwrap(WebhookCreated(response: try json("""
        {"name": "github-push", "url": "https://host.example:8644/webhooks/github-push", "secret_set": true, "secret": "s3cr3t-value"}
        """)))
        XCTAssertEqual(created.secret, "s3cr3t-value")
        XCTAssertNil(WebhookCreated(response: try json(#"{"name": "x", "url": "u", "secret": ""}"#)), "no secret: nothing to show once")

        let enable = WebhookEnableResult(response: try json(#"{"ok": true, "restart_started": false, "restart_error": "busy"}"#))
        XCTAssertFalse(enable.restartStarted)
        XCTAssertEqual(enable.restartError, "busy")
    }

    func testWebhookDraftBody() {
        var draft = WebhookDraft()
        draft.name = "  github-push "
        XCTAssertEqual(draft.body as NSDictionary,
                       ["name": "github-push", "deliver": "log", "deliver_only": false] as NSDictionary, "blanks left to the host")
        draft.description = " Pushes "
        draft.prompt = "Summarize\n"
        draft.events = "push, ,pull_request"
        draft.skills = "git"
        draft.deliver = "telegram"
        draft.deliverOnly = true
        XCTAssertEqual(draft.body as NSDictionary, [
            "name": "github-push", "description": "Pushes", "prompt": "Summarize", "events": ["push", "pull_request"],
            "skills": ["git"], "deliver": "telegram", "deliver_only": true,
        ] as NSDictionary)
    }

    func testWebhookRoutes() async throws {
        let transport = RecordingMessagingTransport()
        transport.responses["POST /api/webhooks"] = ["name": "hook", "url": "https://h/webhooks/hook", "secret": "abc"]
        let api = WebhooksAPI(transport: transport, profile: "work")
        _ = try await api.list()
        XCTAssertEqual(transport.last("GET", "/api/webhooks")?.query, ["profile": "work"])
        _ = try await api.enable()
        XCTAssertNotNil(transport.last("POST", "/api/webhooks/enable"))
        var draft = WebhookDraft()
        draft.name = "hook"
        let created = try await api.create(draft)
        XCTAssertEqual(created.secret, "abc")
        XCTAssertEqual(transport.last("POST", "/api/webhooks")?.body?["name"] as? String, "hook")
        try await api.setEnabled("hook", false)
        XCTAssertEqual(transport.last("PUT", "/api/webhooks/hook/enabled")?.body as NSDictionary?, ["enabled": false] as NSDictionary)
        try await api.delete("hook")
        XCTAssertEqual(transport.last("DELETE", "/api/webhooks/hook")?.query, ["profile": "work"])
        // The dashboard's own profile is named on the delete, which Hermes refuses unnamed on a multi-profile host.
        transport.responses["GET /api/profiles/active"] = ["active": "default", "current": "ops"]
        try await WebhooksAPI(transport: transport, profile: nil).delete("hook")
        XCTAssertEqual(transport.last("DELETE", "/api/webhooks/hook")?.query, ["profile": "ops"])

        transport.responses["POST /api/webhooks"] = ["name": "hook", "url": "u"]
        do {
            _ = try await api.create(draft)
            XCTFail("an answer without the secret is reported")
        } catch {}
    }

    func testSecretMaskShowsNothingOfTheSecret() {
        let secret = "Zq3-very_secret_token_value_from_the_host"
        let masked = WebhookSecretMask.masked(secret)
        XCTAssertTrue(masked.allSatisfy { $0 == "•" })
        XCTAssertEqual(masked.count, 24, "capped, so the length doesn't give it away")
        XCTAssertEqual(WebhookSecretMask.masked("ab").count, 8)
        XCTAssertEqual(WebhookSecretMask.masked("").count, 8)
    }

    // MARK: Store

    @MainActor
    func testStoreSavesDraftsAndAsksForARestart() async throws {
        let transport = RecordingMessagingTransport()
        transport.responses["GET /api/messaging/platforms"] = try json("{\"platforms\": [\(telegramRow)]}")
        transport.responses["PUT /api/messaging/platforms/telegram"] = ["ok": true, "hot_served": false]
        let store = MessagingStore(api: MessagingAPI(transport: transport, profile: nil))
        await store.refreshAll()
        let platform = try XCTUnwrap(store.platform("telegram"))
        XCTAssertEqual(store.presentTones, [.good])

        store.edit("telegram", key: "TELEGRAM_BOT_TOKEN", value: "  ")
        XCTAssertFalse(store.hasEdits(platform))
        store.edit("telegram", key: "TELEGRAM_BOT_TOKEN", value: "123:abc")
        XCTAssertTrue(store.hasEdits(platform))
        await store.save(platform)
        XCTAssertEqual(store.draft("telegram"), [:], "a saved draft is dropped")
        XCTAssertTrue(store.restartNeeded, "not hot-served: the banner stays until a restart")
        XCTAssertEqual(store.notice?.title, "Telegram setup saved")

        await store.setEnabled(platform, false)
        XCTAssertEqual(store.platform("telegram")?.state, "disabled")
        XCTAssertEqual(store.platform("telegram")?.tone, .muted)
        XCTAssertEqual(transport.last("PUT", "/api/messaging/platforms/telegram")?.body as NSDictionary?, ["enabled": false] as NSDictionary)
    }

    @MainActor
    func testStoreRestoresAFailedApproval() async throws {
        let transport = RecordingMessagingTransport()
        transport.responses["GET /api/pairing"] = try json(#"{"pending": [{"platform": "telegram", "request_id": "r1", "user_id": "42"}], "approved": []}"#)
        transport.failures["POST /api/pairing/approve"] = DashboardError.http(429, #"{"detail": "locked out"}"#)
        let store = MessagingStore(api: MessagingAPI(transport: transport, profile: nil))
        await store.refreshPairing()
        let user = try XCTUnwrap(store.pairing.pending.first)
        await store.approve(user)
        XCTAssertEqual(store.pairing.pending.map(\.id), ["telegram:42"], "a failed approval puts the row back")
        XCTAssertEqual(store.failure, "Too many failed approvals — this platform is locked out. Try again later.")
        XCTAssertNil(store.approving)
    }

    func testQRCodeRenders() {
        let image = MessagingQRRenderer.image("https://t.me/setupbot?start=abc")
        XCTAssertNotNil(image)
        XCTAssertGreaterThan(image?.size.width ?? 0, 100)
    }
}
