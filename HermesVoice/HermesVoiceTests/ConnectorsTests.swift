import XCTest
@testable import HermesVoice

/// Records the MCP routes the Connectors screens call and answers from a script.
private final class FakeMCPTransport: MCPTransport {
    struct Call {
        var method: String
        var path: String
        var query: [String: String]
        var body: JSON?
        var timeout: TimeInterval?

        var bodyValue: JSONValue { JSONValue(any: body ?? [:]) }
    }

    var calls: [Call] = []
    var responses: [String: Any] = [:]
    var errors: [String: Error] = [:]
    let dashboardBase = URL(string: "https://hermes.example.ts.net")!

    func mcpRequest(_ method: String, _ path: String, query: [String: String], body: JSON?, timeout: TimeInterval?) async throws -> Any {
        calls.append(Call(method: method, path: path, query: query, body: body, timeout: timeout))
        let key = "\(method) \(path)"
        if let error = errors[key] { throw error }
        return responses[key] ?? JSON()
    }

    func calls(_ method: String, _ path: String) -> [Call] {
        calls.filter { $0.method == method && $0.path == path }
    }
}

final class ConnectorsTests: XCTestCase {
    private func value(_ text: String) throws -> JSONValue {
        try JSONValue(jsonData: Data(text.utf8))
    }

    private func object(_ text: String) throws -> [String: JSONValue] {
        try XCTUnwrap(try value(text).objectValue)
    }

    // MARK: Decoders

    func testServerSummaryDecodesEveryField() throws {
        let server = try XCTUnwrap(MCPServerSummary(row: try value("""
        {"name": "github", "transport": "http", "url": "https://mcp.example.com/mcp", "command": null, "args": [],
         "env": {}, "auth": "oauth", "enabled": false, "tools": {"include": ["get_issue", 3]},
         "source": "config", "plugin": null}
        """)))
        XCTAssertEqual(server.name, "github")
        XCTAssertEqual(server.transport, .http)
        XCTAssertEqual(server.url, "https://mcp.example.com/mcp")
        XCTAssertNil(server.command)
        XCTAssertEqual(server.auth, "oauth")
        XCTAssertFalse(server.enabled)
        XCTAssertEqual(server.tools.include, ["get_issue"], "non-string names are dropped")
        XCTAssertFalse(server.isPlugin)
        XCTAssertEqual(server.target, "https://mcp.example.com/mcp")
    }

    func testServerSummaryIsLenientAndKeepsTheHostsMasks() throws {
        let server = try XCTUnwrap(MCPServerSummary(row: try value("""
        {"name": "fs", "command": "npx", "args": ["-y", "server-filesystem", 7], "env": {"TOKEN": "sk-a...wxyz", "B": "***"},
         "tools": ["x"], "source": "plugin", "plugin": "files"}
        """)))
        XCTAssertEqual(server.transport, .stdio, "no transport field: the command decides")
        XCTAssertEqual(server.args, ["-y", "server-filesystem"])
        XCTAssertEqual(server.env, [MCPEnvPreview(key: "B", value: "***"), MCPEnvPreview(key: "TOKEN", value: "sk-a...wxyz")])
        XCTAssertTrue(server.enabled, "absent enabled is on")
        XCTAssertNil(server.tools.include, "a list isn't a filter")
        XCTAssertTrue(server.isPlugin)
        XCTAssertEqual(server.plugin, "files")
        XCTAssertEqual(server.target, "npx -y server-filesystem")
        XCTAssertNil(MCPServerSummary(row: try value(#"{"name": ""}"#)))
        XCTAssertNil(MCPServerSummary(row: try value(#"{"url": "https://x.example"}"#)))
    }

    func testProbeResultAndStatus() throws {
        let ok = MCPTestResult(response: try value("""
        {"ok": true, "tools": [{"name": "search", "description": "Find", "schema_chars": 400}, {"name": "", "description": "x"},
         {"name": "read", "description": "Read", "schema_chars": 0}], "prompts": 2, "resources": -1}
        """))
        XCTAssertTrue(ok.ok)
        XCTAssertEqual(ok.tools.map(\.name), ["search", "read"])
        XCTAssertEqual(ok.tools[0].schemaChars, 400)
        XCTAssertNil(ok.tools[1].schemaChars, "a zero size is no size")
        XCTAssertEqual(ok.prompts, 2)
        XCTAssertEqual(ok.resources, 0)
        XCTAssertEqual(ok.status, .ok)

        let auth = MCPTestResult(response: try value(#"{"ok": false, "error": "OAuth authentication required — no token found.", "tools": []}"#))
        XCTAssertEqual(auth.status, .needsAuth)
        XCTAssertEqual(MCPTestResult(response: try value(#"{"ok": false, "error": "HTTP 401"}"#)).status, .needsAuth)
        XCTAssertEqual(MCPTestResult(response: try value(#"{"ok": false, "error": "Connection refused"}"#)).status, .error)
        XCTAssertEqual(MCPTestResult(response: try value(#"{"error": "authenticator crashed"}"#)).status, .error,
                       "the word must stand alone")

        XCTAssertEqual(MCPServerStatus.of(enabled: false, probing: true, probe: ok), .off)
        XCTAssertEqual(MCPServerStatus.of(enabled: true, probing: true, probe: ok), .probing)
        XCTAssertEqual(MCPServerStatus.of(enabled: true, probing: false, probe: nil), .unknown)
    }

    func testCanAuthenticate() {
        let http = MCPServerSummary(name: "a", transport: .http, url: "https://a.example/mcp")
        XCTAssertTrue(MCPServerStatus.canAuthenticate(http, status: .needsAuth))
        XCTAssertFalse(MCPServerStatus.canAuthenticate(http, status: .error), "no auth mode: only a sign-in request")
        var oauth = http
        oauth.auth = "oauth"
        XCTAssertTrue(MCPServerStatus.canAuthenticate(oauth, status: .error))
        var header = http
        header.auth = "header"
        XCTAssertFalse(MCPServerStatus.canAuthenticate(header, status: .needsAuth))
        let stdio = MCPServerSummary(name: "b", command: "npx")
        XCTAssertFalse(MCPServerStatus.canAuthenticate(stdio, status: .needsAuth))
        var plugin = http
        plugin.source = .plugin
        XCTAssertFalse(MCPServerStatus.canAuthenticate(plugin, status: .needsAuth))
    }

    func testCatalogDecodesAndBuildsTheInstallBody() throws {
        let catalog = MCPCatalog(response: try value("""
        {"entries": [{"name": "linear", "description": "Issues", "connector_slug": "linear", "source": "nous",
          "transport": "http", "auth_type": "api_key",
          "required_env": [{"name": "LINEAR_KEY", "prompt": "API key", "required": true}, {"name": "LINEAR_TEAM", "prompt": "", "required": false}],
          "command": null, "args": [], "url": "https://mcp.linear.example/mcp", "install_url": "https://git.example/linear.git",
          "install_ref": "v1", "bootstrap": ["npm ci"], "default_enabled": null, "post_install": "", "needs_install": true,
          "installed": false, "enabled": false}, {"description": "no name"}],
         "diagnostics": [{"name": "broken", "kind": "parse", "message": "bad yaml"}]}
        """))
        XCTAssertEqual(catalog.entries.count, 1)
        let entry = catalog.entries[0]
        XCTAssertEqual(entry.connectorSlug, "linear")
        XCTAssertEqual(entry.authType, "api_key")
        XCTAssertEqual(entry.requiredEnv.map(\.name), ["LINEAR_KEY", "LINEAR_TEAM"])
        XCTAssertTrue(entry.needsEnv)
        XCTAssertEqual(entry.installURL, "https://git.example/linear.git")
        XCTAssertEqual(entry.bootstrap, ["npm ci"])
        XCTAssertEqual(catalog.diagnostics.first?.message, "bad yaml")

        XCTAssertFalse(entry.canInstall(with: ["LINEAR_KEY": "  "]))
        XCTAssertTrue(entry.canInstall(with: ["LINEAR_KEY": "lin_123"]))
        let body = JSONValue(any: entry.installBody(["LINEAR_KEY": " lin_123 ", "LINEAR_TEAM": "", "PATH": "/evil"], profile: "work"))
        XCTAssertEqual(body, ["name": "linear", "env": ["LINEAR_KEY": "lin_123"], "enable": true, "profile": "work"],
                       "only declared names, trimmed, blanks left out")
    }

    // MARK: Draft validation and bodies

    func testDraftCompleteness() {
        var draft = MCPServerDraft()
        XCTAssertFalse(draft.isComplete)
        draft.name = "  fs "
        XCTAssertFalse(draft.isComplete, "stdio needs a command")
        draft.command = "npx"
        XCTAssertTrue(draft.isComplete)
        draft.transport = .http
        XCTAssertFalse(draft.isComplete, "http needs a URL")
        draft.url = " https://a.example/mcp "
        XCTAssertTrue(draft.isComplete)
        XCTAssertTrue(draft.nameTaken(in: ["fs", "git"]))
        XCTAssertFalse(draft.nameTaken(in: ["git"]))
        draft.name = " "
        XCTAssertFalse(draft.nameTaken(in: [""]))
    }

    func testStdioCreateBody() {
        var draft = MCPServerDraft()
        draft.name = " files "
        draft.command = " npx "
        draft.args = [.init("-y"), .init("  "), .init(" server-filesystem ")]
        draft.env = [.init(" API_TOKEN ", "s3cret value"), .init("", "ignored")]
        draft.passthrough = [.init(" HOME "), .init("")]
        draft.auth = .oauth
        draft.bearer = "ignored for stdio"
        let body = JSONValue(any: draft.createBody(profile: nil))
        XCTAssertEqual(body, ["name": "files", "command": "npx", "args": ["-y", "server-filesystem"],
                              "env": ["API_TOKEN": "s3cret value", "HOME": "${HOME}"]],
                       "no auth or token for stdio; passthroughs are references")
        XCTAssertFalse(draft.needsFollowUp)
        draft.cwd = "/srv/work"
        XCTAssertTrue(draft.needsFollowUp, "the create route has no working directory")
    }

    func testHttpCreateBodies() {
        var draft = MCPServerDraft()
        draft.name = "linear"
        draft.transport = .http
        draft.url = "https://mcp.linear.example/mcp"
        draft.command = "left over"
        draft.env = [.init("X", "y")]
        XCTAssertEqual(JSONValue(any: draft.createBody(profile: "work")),
                       ["name": "linear", "url": "https://mcp.linear.example/mcp", "auth": "none", "profile": "work"])
        draft.auth = .oauth
        XCTAssertEqual(JSONValue(any: draft.createBody(profile: nil))["auth"], "oauth")
        draft.auth = .bearer
        XCTAssertEqual(JSONValue(any: draft.createBody(profile: nil))["auth"], "none", "no token typed: no header auth")
        draft.bearer = " tok_1234567890 "
        let body = JSONValue(any: draft.createBody(profile: nil))
        XCTAssertEqual(body["auth"], "header")
        XCTAssertEqual(body["bearer_token"], "tok_1234567890")
        XCTAssertFalse(draft.needsFollowUp)
        draft.headers = [.init("X-Team", "core")]
        XCTAssertTrue(draft.needsFollowUp, "the create route has no custom headers")
    }

    func testEntryOverStoredKeepsWhatTheFormDoesntOwn() throws {
        let stored = try object("""
        {"command": "uvx", "args": ["old"], "env": {"API_KEY": "fake-stored-abcdefghijklmnop", "OLD": "1"},
         "enabled": false, "tools": {"exclude": ["drop"]}, "timeout": 30}
        """)
        var draft = MCPServerDraft(editing: "srv", entry: stored)
        XCTAssertEqual(draft.env.map(\.key), ["API_KEY", "OLD"])
        XCTAssertTrue(draft.env.allSatisfy { $0.value.isEmpty && $0.kept != nil }, "no stored secret reaches the form")
        draft.env.removeAll { $0.key == "OLD" }
        draft.env.append(.init("NEW", "typed"))
        draft.args = [.init("new")]
        let entry = draft.entry(over: stored)
        XCTAssertEqual(entry["env"], ["API_KEY": "fake-stored-abcdefghijklmnop", "NEW": "typed"], "kept value from the host, typed one as typed")
        XCTAssertEqual(entry["args"], ["new"])
        XCTAssertEqual(entry["enabled"], false)
        XCTAssertEqual(entry["tools"], ["exclude": ["drop"]])
        XCTAssertEqual(entry["timeout"], 30)

        // A kept row renamed keeps its stored value under the new key; a replaced value wins.
        draft.env[0].key = "API_TOKEN"
        XCTAssertEqual(draft.entry(over: stored)["env"]?["API_TOKEN"], "fake-stored-abcdefghijklmnop")
        draft.env[0].value = "rotated"
        draft.env[0].kept = nil
        XCTAssertEqual(draft.entry(over: stored)["env"]?["API_TOKEN"], "rotated")

        // Switching to HTTP drops the stdio keys.
        draft.transport = .http
        draft.url = "https://a.example/mcp"
        let http = draft.entry(over: stored)
        XCTAssertNil(http["command"])
        XCTAssertNil(http["env"])
        XCTAssertEqual(http["url"], "https://a.example/mcp")
        XCTAssertEqual(http["timeout"], 30)
    }

    func testEditDraftMasksValuesAndReadsPassthroughsAndBearer() throws {
        let stdio = MCPServerDraft(editing: "fs", entry: try object("""
        {"command": "npx", "args": ["-y", "fs"], "cwd": "/srv", "env": {"HOME": "${HOME}", "TOKEN": "fake-proj-1234567890abcd", "PIN": "42"}}
        """))
        XCTAssertEqual(stdio.transport, .stdio)
        XCTAssertEqual(stdio.passthrough.map(\.value), ["HOME"])
        XCTAssertEqual(stdio.env.first { $0.key == "TOKEN" }?.kept, "fake...abcd", "mask_secret: first and last four")
        XCTAssertEqual(stdio.env.first { $0.key == "PIN" }?.kept, CredentialMask.placeholder, "short values are fully masked")
        XCTAssertEqual(stdio.cwd, "/srv")

        let template = MCPServerDraft.bearerTemplate(for: "my-server")
        XCTAssertEqual(template, "Bearer ${MCP_MY_SERVER_API_KEY}")
        let http = MCPServerDraft(editing: "my-server", entry: try object("""
        {"url": "https://a.example/mcp", "headers": {"Authorization": "\(template)", "X-Org": "org-secret-value-123"}}
        """))
        XCTAssertEqual(http.auth, .bearer)
        XCTAssertTrue(http.hasStoredBearer)
        XCTAssertEqual(http.headers.map(\.key), ["X-Org"], "the template is the bearer mode, not a header row")
        XCTAssertEqual(http.headers[0].kept, "org-...-123")
        let entry = http.entry(over: try object(#"{"url": "https://a.example/mcp", "headers": {"Authorization": "\#(template)", "X-Org": "org-secret-value-123"}}"#),
                               bearerHeader: template)
        XCTAssertEqual(entry["headers"], ["Authorization": .string(template), "X-Org": "org-secret-value-123"])

        var none = http
        none.auth = .none
        let dropped = none.entry(over: try object(#"{"url": "https://a.example/mcp", "headers": {"Authorization": "\#(template)", "X-Org": "org-secret-value-123"}}"#),
                                 bearerHeader: template)
        XCTAssertEqual(dropped["headers"], ["X-Org": "org-secret-value-123"], "leaving bearer mode drops the template")
        XCTAssertNil(dropped["auth"])
        let vanished = none.entry(over: try object(#"{"url": "https://a.example/mcp"}"#), bearerHeader: template)
        XCTAssertNil(vanished["headers"], "a kept row whose value left the host has nothing to keep")
    }

    func testBearerHelpers() {
        XCTAssertEqual(MCPServerDraft.bearerEnvKey(for: "github.com/x"), "MCP_GITHUB_COM_X_API_KEY")
        XCTAssertEqual(MCPServerDraft.bearerEnvKey(for: "_a_"), "MCP_A_API_KEY")
        XCTAssertEqual(MCPServerDraft.strippedBearer(" Bearer abc "), "abc")
        XCTAssertEqual(MCPServerDraft.strippedBearer("bearer  xyz"), "xyz")
        XCTAssertEqual(MCPServerDraft.strippedBearer("token"), "token")
    }

    func testMasking() {
        XCTAssertEqual(MCPServerDraft.mask(.string("fake-value-0123456789")), "fake...6789")
        XCTAssertEqual(MCPServerDraft.mask(.string("short")), CredentialMask.placeholder)
        XCTAssertEqual(MCPServerDraft.mask(.string("")), "")
        XCTAssertEqual(MCPServerDraft.mask(.int(12345)), CredentialMask.placeholder)
        XCTAssertEqual(MCPServerDraft.mask(.string("${MCP_X_API_KEY}")), "${MC...KEY}", "references mask like any value")
        XCTAssertEqual(CredentialMask.display("***"), CredentialMask.placeholder, "the host's short mask shows as dots")
    }

    // MARK: Tool filters

    func testToolFilter() throws {
        XCTAssertTrue(MCPToolFilter(nil).isEnabled("a"))
        let exclude = MCPToolFilter(try value(#"{"exclude": ["b"]}"#))
        XCTAssertTrue(exclude.isEnabled("a"))
        XCTAssertFalse(exclude.isEnabled("b"))
        let include = MCPToolFilter(try value(#"{"include": [], "exclude": ["b"]}"#))
        XCTAssertFalse(include.isEnabled("a"), "an empty include allows nothing")
        XCTAssertEqual(MCPToolFilter(try value(#"{"include": ["a"]}"#)).enabledCount(["a", "b", "c"]), 1)
    }

    func testSettingDisabledTools() throws {
        let plain = try object(#"{"command": "npx"}"#)
        let off = MCPEntry.settingDisabledTools(plain, disabled: ["b"], discovered: ["a", "b"])
        XCTAssertEqual(off["tools"], ["exclude": ["b"]])
        XCTAssertNil(MCPEntry.settingDisabledTools(off, disabled: [], discovered: ["a", "b"])["tools"], "an emptied denylist goes")

        let whitelist = try object(#"{"command": "npx", "tools": {"include": ["a", "gone"], "prompts": false}}"#)
        let next = MCPEntry.settingDisabledTools(whitelist, disabled: ["a"], discovered: ["a", "b"])
        XCTAssertEqual(next["tools"], ["include": ["b", "gone"], "prompts": false],
                       "a whitelist stays one; names the probe didn't see and other keys are kept")

        let denylist = try object(#"{"tools": {"exclude": ["old"]}}"#)
        XCTAssertEqual(MCPEntry.settingDisabledTools(denylist, disabled: ["a"], discovered: ["a", "b"])["tools"],
                       ["exclude": ["a", "old"]])
    }

    func testEnabledReadsLikeTheRuntime() throws {
        XCTAssertTrue(MCPEntry.isEnabled([:]))
        XCTAssertTrue(MCPEntry.isEnabled(["enabled": .null]))
        XCTAssertFalse(MCPEntry.isEnabled(["enabled": false]))
        XCTAssertFalse(MCPEntry.isEnabled(["enabled": 0]))
        XCTAssertFalse(MCPEntry.isEnabled(["enabled": " Off "]))
        XCTAssertFalse(MCPEntry.isEnabled(["enabled": "no"]))
        XCTAssertTrue(MCPEntry.isEnabled(["enabled": "maybe"]))
        XCTAssertEqual(MCPEntry.servers(inConfig: try value(#"{"mcp_servers": {"a": {"command": "x"}, "b": null, "c": 3}}"#)).keys.sorted(), ["a"])
    }

    // MARK: Requests

    func testListAndScopedRoutes() async throws {
        let fake = FakeMCPTransport()
        fake.responses["GET /api/mcp/servers"] = ["servers": [["name": "fs", "command": "npx"], ["bad": true]]] as JSON
        let api = MCPAPI(transport: fake, profile: "work")
        let servers = try await api.servers()
        XCTAssertEqual(servers.map(\.name), ["fs"])
        XCTAssertEqual(fake.calls.last?.query, ["profile": "work"])

        try await api.setEnabled("fs", false)
        let toggle = try XCTUnwrap(fake.calls("PUT", "/api/mcp/servers/fs/enabled").first)
        XCTAssertEqual(toggle.bodyValue, ["enabled": false, "profile": "work"])

        _ = try await api.test("fs")
        let test = try XCTUnwrap(fake.calls("POST", "/api/mcp/servers/fs/test").first)
        XCTAssertEqual(test.timeout, MCPAPI.testTimeout, "a probe connects for real: past the usual timeout")

        try await api.remove("fs")
        XCTAssertEqual(fake.calls("DELETE", "/api/mcp/servers/fs").count, 1)

        do {
            try await api.remove("a/b")
            XCTFail("a name with a slash can't be addressed")
        } catch {}
    }

    @MainActor
    func testEveryWriteReloadsTheLiveSessionsOnce() async throws {
        let fake = FakeMCPTransport()
        fake.responses["GET /api/mcp/servers"] = ["servers": [["name": "fs", "command": "npx", "enabled": true]]] as JSON
        fake.responses["POST /api/mcp/servers/fs/test"] = ["ok": true, "tools": []] as JSON
        fake.responses["GET /api/config"] = ["mcp_servers": ["fs": ["command": "npx"]]] as JSON
        var reloads = 0
        let model = ConnectorsModel(api: MCPAPI(transport: fake, profile: "work")) { reloads += 1 }
        XCTAssertTrue(model.reloadsLiveSessions)
        await model.reloadServers()

        await model.setEnabled("fs", false)
        await model.settleReload()
        XCTAssertEqual(reloads, 1, "turning a server off reaches running chats")
        let saved = await model.saveTools("fs", disabled: ["write"], discovered: ["read", "write"])
        XCTAssertTrue(saved, model.failure ?? "")
        await model.settleReload()
        XCTAssertEqual(reloads, 2)
        _ = await model.remove("fs")
        await model.settleReload()
        XCTAssertEqual(reloads, 3)

        fake.errors["DELETE /api/mcp/servers/gone"] = DashboardError.http(404, "{}")
        _ = await model.remove("gone")
        await model.settleReload()
        XCTAssertEqual(reloads, 3, "a failed write reloads nothing")

        let offline = ConnectorsModel(api: MCPAPI(transport: fake, profile: nil))
        XCTAssertFalse(offline.reloadsLiveSessions, "without the gateway, changes wait for new chats")
    }

    @MainActor
    func testReloadFailureIsReported() async throws {
        let fake = FakeMCPTransport()
        fake.responses["GET /api/mcp/servers"] = ["servers": [["name": "fs", "command": "npx", "enabled": true]]] as JSON
        let model = ConnectorsModel(api: MCPAPI(transport: fake, profile: nil)) { throw DashboardError.timeout }
        await model.reloadServers()
        await model.setEnabled("fs", false)
        await model.settleReload()
        XCTAssertTrue(model.failure?.hasPrefix("MCP reload failed.") == true)
    }

    func testCreateWithFollowUpWritesTheWholeMap() async throws {
        let fake = FakeMCPTransport()
        fake.responses["POST /api/mcp/servers"] = ["name": "files", "transport": "stdio", "command": "npx"] as JSON
        fake.responses["GET /api/config"] = ["mcp_servers": [
            "files": ["command": "npx", "env": ["TOKEN": "typed-secret-value"]],
            "other": ["url": "https://o.example/mcp", "headers": ["Authorization": "Bearer ${MCP_OTHER_API_KEY}"]],
        ]] as JSON
        var draft = MCPServerDraft()
        draft.name = "files"
        draft.command = "npx"
        draft.env = [.init("TOKEN", "typed-secret-value")]
        draft.cwd = "/srv/data"
        let api = MCPAPI(transport: fake)
        let created = try await api.create(draft)
        XCTAssertEqual(created?.name, "files")

        let config = try XCTUnwrap(fake.calls("GET", "/api/config").first)
        XCTAssertEqual(config.query["include_defaults"], "false", "the raw file: references stay references")
        let put = try XCTUnwrap(fake.calls("PUT", "/api/mcp/servers").first)
        let servers = try XCTUnwrap(put.bodyValue["servers"]?.objectValue)
        XCTAssertEqual(servers["files"]?["cwd"], "/srv/data")
        XCTAssertEqual(servers["files"]?["env"], ["TOKEN": "typed-secret-value"])
        XCTAssertEqual(servers["other"], ["url": "https://o.example/mcp", "headers": ["Authorization": "Bearer ${MCP_OTHER_API_KEY}"]],
                       "every other server is written back as stored")
        XCTAssertNil(put.body?["profile"])
    }

    func testCreateWithoutFollowUpIsOneRequest() async throws {
        let fake = FakeMCPTransport()
        var draft = MCPServerDraft()
        draft.name = "a"
        draft.transport = .http
        draft.url = "https://a.example/mcp"
        draft.auth = .bearer
        draft.bearer = "tok_abcdefghijkl"
        try await MCPAPI(transport: fake).create(draft)
        XCTAssertEqual(fake.calls.map { "\($0.method) \($0.path)" }, ["POST /api/mcp/servers"])
        XCTAssertEqual(fake.calls[0].bodyValue["bearer_token"], "tok_abcdefghijkl")
    }

    func testUpdateKeepsStoredSecretsAndWritesTheBearerFirst() async throws {
        let fake = FakeMCPTransport()
        let template = MCPServerDraft.bearerTemplate(for: "linear")
        fake.responses["GET /api/config"] = ["mcp_servers": [
            "linear": ["url": "https://l.example/mcp", "headers": ["X-Org": "org-secret-value-123"], "tools": ["exclude": ["x"]]],
        ]] as JSON
        var draft = MCPServerDraft(editing: "linear", entry: [
            "url": "https://l.example/mcp", "headers": ["X-Org": "org-secret-value-123"],
        ])
        draft.auth = .bearer
        draft.bearer = "Bearer tok_new_1234567"
        let api = MCPAPI(transport: fake, profile: "work")
        try await api.update("linear", draft: draft)

        XCTAssertEqual(fake.calls.map { "\($0.method) \($0.path)" },
                       ["PUT /api/env", "GET /api/config", "PUT /api/mcp/servers"], "the token lands before the config points at it")
        XCTAssertEqual(fake.calls[0].bodyValue, ["key": "MCP_LINEAR_API_KEY", "value": "tok_new_1234567", "profile": "work"])
        let servers = try XCTUnwrap(fake.calls[2].bodyValue["servers"]?.objectValue)
        XCTAssertEqual(servers["linear"]?["headers"], ["X-Org": "org-secret-value-123", "Authorization": .string(template)])
        XCTAssertEqual(servers["linear"]?["tools"], ["exclude": ["x"]])
        XCTAssertEqual(fake.calls[2].bodyValue["profile"], "work")
    }

    func testPartialCreateSaysWhatWasntSaved() async throws {
        let fake = FakeMCPTransport()
        fake.errors["GET /api/config"] = DashboardError.http(500, #"{"detail": "header secret-header-value-1 bad"}"#)
        var draft = MCPServerDraft()
        draft.name = "a"
        draft.transport = .http
        draft.url = "https://a.example/mcp"
        draft.headers = [.init("X-Key", "secret-header-value-1")]
        do {
            try await MCPAPI(transport: fake).create(draft)
            XCTFail("the follow-up failed")
        } catch {
            XCTAssertTrue(error.dashboardMessage.hasPrefix("Added a, but its headers weren't saved."), error.dashboardMessage)
            XCTAssertFalse(error.dashboardMessage.contains("secret-header-value-1"))
        }
        XCTAssertEqual(fake.calls("POST", "/api/mcp/servers").count, 1)
    }

    func testUpdateRefusesBearerModeWithoutAToken() async throws {
        let fake = FakeMCPTransport()
        var draft = MCPServerDraft()
        draft.name = "a"
        draft.transport = .http
        draft.url = "https://a.example/mcp"
        draft.auth = .bearer
        do {
            try await MCPAPI(transport: fake).update("a", draft: draft)
            XCTFail("bearer mode needs a token")
        } catch {}
        XCTAssertTrue(fake.calls.isEmpty)
    }

    func testSetDisabledToolsRewritesOneEntry() async throws {
        let fake = FakeMCPTransport()
        fake.responses["GET /api/config"] = ["mcp_servers": ["fs": ["command": "npx"], "b": ["command": "uvx"]]] as JSON
        try await MCPAPI(transport: fake).setDisabledTools("fs", disabled: ["write"], discovered: ["read", "write"])
        let servers = try XCTUnwrap(fake.calls("PUT", "/api/mcp/servers").first?.bodyValue["servers"]?.objectValue)
        XCTAssertEqual(servers["fs"], ["command": "npx", "tools": ["exclude": ["write"]]])
        XCTAssertEqual(servers["b"], ["command": "uvx"])

        let missing = FakeMCPTransport()
        missing.responses["GET /api/config"] = ["mcp_servers": [:]] as JSON
        do {
            try await MCPAPI(transport: missing).setDisabledTools("fs", disabled: [], discovered: [])
            XCTFail("a server that left the config can't be rewritten")
        } catch {}
        XCTAssertTrue(missing.calls("PUT", "/api/mcp/servers").isEmpty)
    }

    func testErrorsNeverEchoTypedSecrets() async throws {
        let fake = FakeMCPTransport()
        fake.errors["POST /api/mcp/servers"] = DashboardError.http(400, #"{"detail": "rejected token tok_secret_987654"}"#)
        var draft = MCPServerDraft()
        draft.name = "a"
        draft.transport = .http
        draft.url = "https://a.example/mcp"
        draft.auth = .bearer
        draft.bearer = "tok_secret_987654"
        do {
            try await MCPAPI(transport: fake).create(draft)
            XCTFail("expected the error")
        } catch {
            XCTAssertFalse(error.dashboardMessage.contains("tok_secret_987654"))
            XCTAssertFalse(String(describing: error).contains("tok_secret_987654"))
        }

        fake.errors["POST /api/mcp/catalog/install"] = DashboardError.http(400, "bad value lin_api_key_42 for LINEAR_KEY")
        let entry = try XCTUnwrap(MCPCatalogEntry(row: ["name": "linear", "required_env": [["name": "LINEAR_KEY", "required": true]]]))
        do {
            _ = try await MCPAPI(transport: fake).install(entry, env: ["LINEAR_KEY": "lin_api_key_42"])
            XCTFail("expected the error")
        } catch {
            XCTAssertFalse(String(describing: error).contains("lin_api_key_42"))
        }
    }

    func testOAuthRoutes() async throws {
        let fake = FakeMCPTransport()
        fake.responses["POST /api/mcp/servers/linear/auth"] = [
            "flow_id": "f1", "server_name": "linear", "status": "authorization_required",
            "authorization_url": "https://auth.example/authorize?client_id=c&redirect_uri=https%3A%2F%2Fhermes.example.ts.net%2Fapi%2Fmcp%2Foauth%2Fcallback%2Flinear&state=s",
            "error": NSNull(),
        ] as JSON
        let api = MCPAPI(transport: fake, profile: "work")
        let flow = try await api.startOAuth("linear")
        XCTAssertEqual(flow.status, .authorizationRequired)
        XCTAssertEqual(flow.redirectURI?.host, "hermes.example.ts.net")
        XCTAssertFalse(flow.callbackUnreachable(from: fake.dashboardBase))
        XCTAssertEqual(fake.calls[0].timeout, MCPAPI.authTimeout)
        XCTAssertEqual(fake.calls[0].query, ["profile": "work"])

        fake.errors["GET /api/mcp/oauth/flows/f1"] = DashboardError.http(404, #"{"detail": "OAuth flow not found or expired"}"#)
        let expired = try await api.pollOAuth("f1")
        XCTAssertNil(expired, "an unknown flow reads as expired")

        await api.cancelOAuth("f1")
        XCTAssertEqual(fake.calls("DELETE", "/api/mcp/oauth/flows/f1").count, 1)
    }

    func testOAuthFlowDecodingAndReachability() throws {
        let approved = try XCTUnwrap(MCPOAuthFlow(response: try value("""
        {"flow_id": "f", "server_name": "s", "status": "approved", "authorization_url": null, "error": null,
         "tools": [{"name": "a", "description": "A"}, {"description": "nameless"}]}
        """)))
        XCTAssertEqual(approved.status, .approved)
        XCTAssertEqual(approved.tools.map(\.name), ["a"])
        XCTAssertNil(MCPOAuthFlow(response: try value(#"{"status": "starting"}"#)))
        XCTAssertEqual(MCPOAuthFlow.Status("weird"), .other("weird"))

        let base = URL(string: "https://hermes.example.ts.net")!
        func flow(redirect: String) -> MCPOAuthFlow {
            var components = URLComponents(string: "https://auth.example/authorize")!
            components.queryItems = [URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "state", value: "x")]
            return MCPOAuthFlow(flowID: "f", status: .authorizationRequired, authorizationURL: components.url)
        }
        XCTAssertTrue(flow(redirect: "http://127.0.0.1:9119/api/mcp/oauth/callback/s").callbackUnreachable(from: base))
        XCTAssertTrue(flow(redirect: "http://localhost:9119/api/mcp/oauth/callback/s").callbackUnreachable(from: base))
        XCTAssertTrue(flow(redirect: "http://[::1]:9119/cb").callbackUnreachable(from: base))
        XCTAssertFalse(flow(redirect: "https://hermes.example.ts.net/api/mcp/oauth/callback/s").callbackUnreachable(from: base))
        XCTAssertFalse(flow(redirect: "http://127.0.0.1:9119/cb").callbackUnreachable(from: URL(string: "http://127.0.0.1:9119")!),
                       "a phone that reaches the host on loopback (the simulator) can use it")
        XCTAssertFalse(MCPOAuthFlow(flowID: "f", status: .authorizationRequired,
                                    authorizationURL: URL(string: "https://auth.example/authorize?state=x")).callbackUnreachable(from: base),
                       "no redirect named: assume it works")
        let proxied = URL(string: "http://hermes.example.ts.net/api/mcp/oauth/callback/s")!
        XCTAssertEqual(MCPOAuthFlow.mismatchedOrigin(proxied, dashboard: base), "http://hermes.example.ts.net",
                       "same host, another scheme: worth a warning")
        XCTAssertNil(MCPOAuthFlow.mismatchedOrigin(URL(string: "https://hermes.example.ts.net:443/cb")!, dashboard: base))
        XCTAssertNil(MCPOAuthFlow.mismatchedOrigin(URL(string: "https://other.example/cb")!, dashboard: base))
        XCTAssertFalse(MCPText.isLoopback("127.example.com"))
        XCTAssertTrue(MCPText.isLoopback("127.1.2.3"))
        XCTAssertTrue(MCPText.isLoopback("app.localhost"))
    }

    // MARK: OAuth state machine

    private let dashboard = URL(string: "https://hermes.example.ts.net")!
    private let authURL = URL(string: "https://auth.example/authorize?redirect_uri=https%3A%2F%2Fhermes.example.ts.net%2Fcb&state=s")!

    private func waiting(at start: Date = Date(timeIntervalSince1970: 1000)) -> MCPOAuthMachine {
        var machine = MCPOAuthMachine()
        machine.start(at: start)
        let effects = machine.started(MCPOAuthFlow(flowID: "f1", status: .authorizationRequired, authorizationURL: authURL),
                                      dashboard: dashboard)
        XCTAssertEqual(effects, [.open(authURL), .poll(after: MCPOAuthMachine.pollInterval)])
        XCTAssertEqual(machine.phase, .waiting(flowID: "f1", url: authURL))
        XCTAssertTrue(machine.isRunning)
        return machine
    }

    func testOAuthHappyPath() {
        var machine = waiting()
        let start = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(machine.polled(MCPOAuthFlow(flowID: "f1", status: .authorizationRequired, authorizationURL: authURL),
                                      at: start.addingTimeInterval(2)), [.poll(after: MCPOAuthMachine.pollInterval)])
        let tools = [MCPProbedTool(name: "search", description: "")]
        XCTAssertEqual(machine.polled(MCPOAuthFlow(flowID: "f1", status: .approved, tools: tools), at: start.addingTimeInterval(4)),
                       [.closeBrowser])
        XCTAssertEqual(machine.phase, .approved(tools: tools))
        XCTAssertFalse(machine.isRunning)
        XCTAssertEqual(machine.stop(), [], "nothing to cancel once approved")
        XCTAssertEqual(machine.polled(nil, at: start), [], "a late poll is ignored")
    }

    func testOAuthErrorsAndExpiry() {
        var failed = waiting()
        XCTAssertEqual(failed.polled(MCPOAuthFlow(flowID: "f1", status: .error, error: "access_denied"), at: Date(timeIntervalSince1970: 1001)),
                       [.closeBrowser, .cancel(flowID: "f1")])
        XCTAssertEqual(failed.phase, .failed("access_denied"))

        var expired = waiting()
        XCTAssertEqual(expired.polled(nil, at: Date(timeIntervalSince1970: 1001)), [.closeBrowser])
        XCTAssertEqual(expired.phase, .failed("The sign-in expired. Start it again."))

        var other = waiting()
        XCTAssertEqual(other.polled(MCPOAuthFlow(flowID: "other", status: .approved), at: Date(timeIntervalSince1970: 1001)), [],
                       "another flow's answer is ignored")
        XCTAssertEqual(other.phase, .waiting(flowID: "f1", url: authURL))
    }

    func testOAuthTimeoutAndPollFailures() {
        var slow = waiting()
        let late = Date(timeIntervalSince1970: 1000 + MCPOAuthMachine.timeout)
        XCTAssertEqual(slow.polled(MCPOAuthFlow(flowID: "f1", status: .authorizationRequired, authorizationURL: authURL), at: late),
                       [.closeBrowser, .cancel(flowID: "f1")])
        if case .failed = slow.phase {} else { XCTFail("timed out") }

        var flaky = waiting()
        let now = Date(timeIntervalSince1970: 1010)
        XCTAssertEqual(flaky.pollFailed("offline", at: now), [.poll(after: 1)])
        XCTAssertEqual(flaky.pollFailed("offline", at: now), [.poll(after: 1)])
        XCTAssertEqual(flaky.polled(MCPOAuthFlow(flowID: "f1", status: .starting), at: now), [.poll(after: MCPOAuthMachine.pollInterval)],
                       "an answer resets the count")
        XCTAssertEqual(flaky.pollFailed("offline", at: now), [.poll(after: 1)])
        XCTAssertEqual(flaky.pollFailed("offline", at: now), [.poll(after: 1)])
        XCTAssertEqual(flaky.pollFailed("offline", at: now), [.closeBrowser, .cancel(flowID: "f1")])
        XCTAssertEqual(flaky.phase, .failed("offline"))
    }

    func testOAuthStopAndRemint() {
        var machine = waiting()
        let fresh = URL(string: "https://auth.example/authorize?state=t")!
        _ = machine.polled(MCPOAuthFlow(flowID: "f1", status: .authorizationRequired, authorizationURL: fresh), at: Date(timeIntervalSince1970: 1001))
        XCTAssertEqual(machine.phase, .waiting(flowID: "f1", url: fresh), "a re-minted attempt's URL replaces the old one")
        XCTAssertEqual(machine.stop(), [.closeBrowser, .cancel(flowID: "f1")])
        XCTAssertEqual(machine.phase, .cancelled)
        machine.reset()
        XCTAssertEqual(machine.phase, .idle)

        var early = MCPOAuthMachine()
        early.start(at: Date())
        XCTAssertEqual(early.stop(), [])
        XCTAssertEqual(early.started(MCPOAuthFlow(flowID: "late", status: .authorizationRequired, authorizationURL: authURL),
                                     dashboard: dashboard), [.cancel(flowID: "late")], "a flow started after Stop is released")
        XCTAssertEqual(early.phase, .cancelled)
    }

    func testOAuthStartOutcomes() {
        var unreachable = MCPOAuthMachine()
        unreachable.start(at: Date())
        let loopback = URL(string: "https://auth.example/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A9119%2Fapi%2Fmcp%2Foauth%2Fcallback%2Fs")!
        XCTAssertEqual(unreachable.started(MCPOAuthFlow(flowID: "f", status: .authorizationRequired, authorizationURL: loopback),
                                           dashboard: dashboard), [.cancel(flowID: "f")], "never opens a sign-in that can't finish")
        XCTAssertEqual(unreachable.phase, .unreachable(host: "127.0.0.1"))

        var refused = MCPOAuthMachine()
        refused.start(at: Date())
        XCTAssertEqual(refused.started(MCPOAuthFlow(flowID: "f", status: .error, error: "registration refused"), dashboard: dashboard),
                       [.cancel(flowID: "f")])
        XCTAssertEqual(refused.phase, .failed("registration refused"))

        var noURL = MCPOAuthMachine()
        noURL.start(at: Date())
        XCTAssertEqual(noURL.started(MCPOAuthFlow(flowID: "f", status: .starting), dashboard: dashboard), [.cancel(flowID: "f")])

        var broken = MCPOAuthMachine()
        broken.start(at: Date())
        broken.startFailed("Too many MCP OAuth flows are already in progress")
        XCTAssertEqual(broken.phase, .failed("Too many MCP OAuth flows are already in progress"))
    }

    // MARK: Cards and page

    private func server(_ name: String, enabled: Bool = true, url: String? = nil, auth: String? = nil,
                        filter: MCPToolFilter = .init(), plugin: String? = nil) -> MCPServerSummary {
        MCPServerSummary(name: name, transport: url == nil ? .stdio : .http, url: url, command: url == nil ? "npx" : nil,
                         auth: auth, enabled: enabled, tools: filter, source: plugin == nil ? .config : .plugin, plugin: plugin)
    }

    private func catalogEntry(_ name: String, slug: String? = nil, installed: Bool = false, env: Bool = false) throws -> MCPCatalogEntry {
        var row: JSON = ["name": name, "description": "\(name) tools", "installed": installed]
        if let slug { row["connector_slug"] = slug }
        if env { row["required_env"] = [["name": "KEY", "prompt": "Key", "required": true]] }
        return try XCTUnwrap(MCPCatalogEntry(row: JSONValue(any: row)))
    }

    func testCardsFromServersAndCatalog() throws {
        let tools = ["a", "b", "c"].map { MCPProbedTool(name: $0, description: "") }
        let catalog = [try catalogEntry("github", slug: "github"), try catalogEntry("linear", env: true),
                       try catalogEntry("gitlab", slug: "gh-twin"), try catalogEntry("done", installed: true)]
        let servers = [
            server("github", filter: MCPToolFilter(include: ["a", "b"])),
            server("broken"), server("authme", url: "https://a.example/mcp"), server("off", enabled: false),
            server("files__docs", plugin: "files"),
        ]
        let probes: [String: MCPTestResult] = [
            "github": MCPTestResult(ok: true, tools: tools),
            "broken": MCPTestResult(ok: false, error: "Connection refused"),
            "authme": MCPTestResult(ok: false, error: "401 Unauthorized"),
        ]
        let inputs = ConnectorCards.inputs(servers: servers, catalog: catalog, probes: probes, probing: [], calls: ["mcp__github__a": 3])
        let cards = ConnectorCards.cards(inputs: inputs, catalog: catalog)
        let byKey = Dictionary(uniqueKeysWithValues: cards.map { ($0.slug, $0) })

        let github = try XCTUnwrap(byKey["github"])
        XCTAssertEqual(github.state, .connected)
        XCTAssertEqual(github.stateLabel, "3 tools, 2 on")
        XCTAssertEqual(github.kindWord, "MCP · Catalog")
        XCTAssertTrue(github.showsCatalogMark)
        XCTAssertEqual(github.name, "GitHub")
        XCTAssertEqual(github.description, "github tools")

        let broken = try XCTUnwrap(byKey["broken"])
        XCTAssertEqual(broken.state, .broken)
        XCTAssertEqual(broken.reason, .serverError)
        XCTAssertEqual(broken.verb, .openLogs)
        XCTAssertEqual(broken.stateWord, "Error")
        XCTAssertEqual(broken.kindWord, "MCP · Custom")

        let authme = try XCTUnwrap(byKey["authme"])
        XCTAssertEqual(authme.verb, .authenticate)
        XCTAssertEqual(authme.stateWord, "Needs authentication")

        XCTAssertEqual(byKey["off"]?.state, .off)
        XCTAssertEqual(byKey["off"]?.stateLabel, "Off")
        let plugin = try XCTUnwrap(byKey["files__docs"])
        XCTAssertEqual(plugin.name, "Docs", "a plugin's server is titled after its own part")
        XCTAssertEqual(plugin.kindWord, "MCP · Plugin files")
        XCTAssertFalse(plugin.hasSwitch)
        XCTAssertEqual(plugin.state, .connecting, "not probed yet")

        let linear = try XCTUnwrap(byKey["linear"])
        XCTAssertFalse(linear.installed)
        XCTAssertEqual(linear.verb, .install)
        XCTAssertTrue(linear.needsEnv)
        XCTAssertNil(byKey["done"], "an installed entry isn't offered")
        XCTAssertNotNil(byKey["gitlab"], "no server stands for its connector")
    }

    func testUnusedAndFacts() {
        var input = ConnectorServerInput(server: server("s"), status: .ok, toolsOn: 1, toolsTotal: 1, uses: 0, catalog: nil)
        XCTAssertEqual(ConnectorCards.card(input).stateLabel, "On, unused")
        input.uses = 5
        XCTAssertEqual(ConnectorCards.card(input).stateLabel, "1 tool on")
        input.uses = nil
        input.toolsOn = nil
        XCTAssertEqual(ConnectorCards.card(input).stateLabel, "1 tool")
        XCTAssertEqual(MCPCost.uses("my-server", calls: ["mcp__my_server__x": 2, "mcp__my_server__y": 1, "mcp__my_serverz__q": 9]), 3)
        XCTAssertEqual(MCPCost.tokensPerCall([MCPProbedTool(name: "a", description: "", schemaChars: 401),
                                              MCPProbedTool(name: "b", description: "", schemaChars: 100)],
                                             filter: MCPToolFilter(exclude: ["b"])), 101)
        XCTAssertNil(MCPCost.tokensPerCall([MCPProbedTool(name: "a", description: "")], filter: .init()))
        XCTAssertEqual(MCPCost.compact(950), "950")
        XCTAssertEqual(MCPCost.compact(4200), "4.2k")
        XCTAssertEqual(MCPCost.compact(12000), "12k")
        XCTAssertEqual(MCPCost.compact(3_400_000), "3.4M")
    }

    func testPageGroupsSortsAndFilters() throws {
        let catalog = [try catalogEntry("alpha"), try catalogEntry("zeta")]
        let servers = [server("beta"), server("gamma", enabled: false), server("delta")]
        let probes = ["beta": MCPTestResult(ok: true), "delta": MCPTestResult(ok: false, error: "boom")]
        let cards = ConnectorCards.cards(
            inputs: ConnectorCards.inputs(servers: servers, catalog: catalog, probes: probes, probing: [], calls: nil), catalog: catalog)

        let page = ConnectorPage(cards: cards, query: "", segment: .all)
        XCTAssertEqual(page.sections.map(\.group), [.host, .available])
        XCTAssertEqual(page.sections[0].cards.map(\.slug), ["delta", "beta", "gamma"], "broken first, turned off last")
        XCTAssertEqual(page.sections[1].cards.map(\.slug), ["alpha", "zeta"])
        XCTAssertEqual(page.segments.map(\.count), [5, 3, 2])
        XCTAssertTrue(page.showsSegments)
        XCTAssertEqual(page.hiddenMatches, 0)

        let narrowed = ConnectorPage(cards: cards, query: "a", segment: .group(.available))
        XCTAssertEqual(narrowed.sections.map(\.group), [.available])
        XCTAssertEqual(narrowed.hiddenMatches, 3, "beta, gamma and delta match elsewhere")

        let fellBack = ConnectorPage(cards: cards, query: "zeta", segment: .group(.host))
        XCTAssertEqual(fellBack.segment, .all, "a segment without matches falls back to All")
        XCTAssertFalse(fellBack.showsSegments)

        XCTAssertTrue(ConnectorPage(cards: cards, query: "nothing", segment: .all).sections.isEmpty)
        XCTAssertTrue(ConnectorPage(cards: cards, query: "nothing", segment: .all).segments.isEmpty)
    }

    func testTitles() {
        XCTAssertEqual(MCPText.title("github"), "GitHub")
        XCTAssertEqual(MCPText.title("my-mcp_server"), "My MCP Server")
        XCTAssertEqual(MCPText.title("filesystem"), "Filesystem")
    }

    // MARK: Tools editor

    func testToolsEditor() {
        var editor = ConnectorToolsEditor(saved: ["c"])
        let tools = ["a", "b", "c"]
        XCTAssertFalse(editor.dirty)
        XCTAssertEqual(editor.summary(tools).label, "2 of 3 on")
        editor.toggle("a")
        editor.toggle("c")
        XCTAssertTrue(editor.dirty)
        XCTAssertEqual(editor.counts.off, 1)
        XCTAssertEqual(editor.counts.backOn, 1)
        XCTAssertEqual(editor.footer, "1 tool off, 1 back on")
        editor.setAll(false, tools: tools)
        XCTAssertEqual(editor.summary(tools).label, "off")
        XCTAssertFalse(editor.summary(tools).switchOn)
        XCTAssertEqual(editor.footer, "2 tools off, none back on")
        editor.setAll(true, tools: tools)
        XCTAssertEqual(editor.summary(tools).label, "all on")
        editor.discard()
        XCTAssertFalse(editor.dirty)
        editor.toggle("b")
        editor.markSaved()
        XCTAssertFalse(editor.dirty)
        editor.reset(saved: [])
        XCTAssertTrue(editor.isOn("b"))
        XCTAssertEqual(ConnectorToolsEditor.savedDisabled(MCPToolFilter(include: ["a"]), discovered: tools), ["b", "c"])
        XCTAssertEqual(ConnectorToolText.displayName("get_issue"), "Get issue")
        XCTAssertEqual(ConnectorToolText.displayName("listPullRequests"), "List Pull Requests")
        XCTAssertEqual(ConnectorToolText.capabilities(tools: 3, prompts: 0, resources: 2), "3 tools, 2 resources enabled")
    }

    // MARK: Import

    func testImportJSONAndCommands() throws {
        let snippet = try XCTUnwrap(MCPImport.parse("""
        {"mcpServers": {"fs": {"type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem"]}}}
        """))
        XCTAssertEqual(snippet.map(\.name), ["fs"])
        XCTAssertEqual(snippet[0].config["transport"], "stdio", "type becomes transport")

        let bare = try XCTUnwrap(MCPImport.parse(#"{"url": "https://mcp.linear.app/sse"}"#))
        XCTAssertEqual(bare.first?.name, "linear")

        let npx = try XCTUnwrap(MCPImport.parse("npx -y @modelcontextprotocol/server-filesystem@latest /tmp/dir"))
        XCTAssertEqual(npx.first?.name, "filesystem")
        XCTAssertEqual(npx.first?.config["args"], ["-y", "@modelcontextprotocol/server-filesystem@latest", "/tmp/dir"])

        let docker = try XCTUnwrap(MCPImport.parse("docker run -i --rm -e TOKEN ghcr.io/acme/github-mcp-server:latest"))
        XCTAssertEqual(docker.first?.name, "github")

        XCTAssertEqual(MCPImport.parse("uvx mcp-server-git==1.0")?.first?.name, "git")
        XCTAssertEqual(MCPImport.parse("https://api.example.com/mcp")?.first?.config, ["url": "https://api.example.com/mcp"])
        XCTAssertNil(MCPImport.parse("ls -la"))
        XCTAssertNil(MCPImport.parse("   "))
    }

    func testImportAddLines() throws {
        let claude = try XCTUnwrap(MCPImport.parse("claude mcp add notes -e API_KEY=abc -s user -- node \"dist/server.js\" --port 3"))
        XCTAssertEqual(claude.first?.name, "notes")
        XCTAssertEqual(claude.first?.config, ["command": "node", "args": ["dist/server.js", "--port", "3"], "env": ["API_KEY": "abc"]])

        let remote = try XCTUnwrap(MCPImport.parse("claude mcp add --transport http linear https://mcp.linear.example/mcp -H 'X-Team: core'"))
        XCTAssertEqual(remote.first?.config["url"], nil, "flags after the URL make it a command line")
        let remoteURL = try XCTUnwrap(MCPImport.parse("claude mcp add --transport http linear https://mcp.linear.example/mcp"))
        XCTAssertEqual(remoteURL.first?.config, ["url": "https://mcp.linear.example/mcp", "transport": "http"])

        let hermes = try XCTUnwrap(MCPImport.parse("hermes mcp add gh --command npx --env A=1 B=2 --args -- -y gh-mcp"))
        XCTAssertEqual(hermes.first?.config, ["command": "npx", "args": ["-y", "gh-mcp"], "env": ["A": "1", "B": "2"]])

        XCTAssertNil(MCPImport.tokenize("echo \"open"))
        XCTAssertEqual(MCPImport.tokenize(#"a "b c" 'd e' "f\"g" """#), ["a", "b c", "d e", "f\"g", ""])
    }

    func testImportCursorLinkAndDraft() throws {
        let config = Data(#"{"command":"npx","args":["-y","x-mcp"],"env":{"HOME":"${HOME}","TOKEN":"t"}}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let encoded = config.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? config
        let link = try XCTUnwrap(MCPImport.parse("cursor://anysphere.cursor-deeplink/mcp/install?name=x&config=\(encoded)"))
        XCTAssertEqual(link.first?.name, "x")

        var previous = MCPServerDraft()
        previous.bearer = "keep"
        let draft = MCPImport.draft(try XCTUnwrap(link.first), previous: previous)
        XCTAssertEqual(draft.transport, .stdio)
        XCTAssertEqual(draft.command, "npx")
        XCTAssertEqual(draft.args.map(\.value), ["-y", "x-mcp"])
        XCTAssertEqual(draft.passthrough.map(\.value), ["HOME"])
        XCTAssertEqual(draft.env.map(\.key), ["TOKEN"])
        XCTAssertNil(draft.env.first?.kept, "pasted values are typed values")

        let http = MCPImport.draft(.init(name: "", config: ["url": "https://a.example/mcp", "auth": "oauth", "headers": ["X": "1"]]),
                                   previous: previous)
        XCTAssertEqual(http.transport, .http)
        XCTAssertEqual(http.auth, .oauth)
        XCTAssertEqual(http.bearer, "keep", "a paste keeps the typed bearer token")
        XCTAssertEqual(http.headers.map(\.key), ["X"])
    }

    // MARK: Logs

    func testStdioLogSections() {
        let lines = [
            "noise",
            "2026-01-01 10:00:00,123 ===== starting MCP server 'fs' =====",
            "fs ready",
            "===== [10:01] starting MCP server 'git' =====",
            "git ready",
            "===== starting MCP server 'fs' =====",
            "fs again",
        ]
        XCTAssertEqual(MCPLogs.stdioSections(lines, server: "fs"),
                       ["2026-01-01 10:00:00,123 ===== starting MCP server 'fs' =====", "fs ready",
                        "===== starting MCP server 'fs' =====", "fs again"])
        XCTAssertEqual(MCPLogs.stdioSections(lines, server: "git").count, 2)
        XCTAssertTrue(MCPLogs.stdioSections(lines, server: "none").isEmpty)
    }
}
