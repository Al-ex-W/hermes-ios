import XCTest
@testable import HermesVoice

/// Records the REST calls the Capabilities routes make and answers them from canned responses.
private final class RecordingCapabilitiesTransport: CapabilitiesTransport {
    struct Call {
        let method: String
        let path: String
        let query: [String: String]
        let body: JSON?
        /// The longer wait the call asked for; nil is the client's usual one.
        var timeout: TimeInterval?
    }

    private(set) var calls: [Call] = []
    /// `"METHOD path"` → the answer (a JSON object or array).
    var responses: [String: Any] = [:]
    /// `"METHOD path"` → the error that call throws.
    var failures: [String: Error] = [:]
    /// `"METHOD path"` → how many more times that call fails before it answers.
    var transientFailures: [String: Int] = [:]

    func request(_ method: String, _ path: String, query: [String: String], body: JSON?) async throws -> Any {
        try answer(Call(method: method, path: path, query: query, body: body))
    }

    func request(_ method: String, _ path: String, query: [String: String], body: JSON?,
                 timeout: TimeInterval) async throws -> Any {
        try answer(Call(method: method, path: path, query: query, body: body, timeout: timeout))
    }

    private func answer(_ call: Call) throws -> Any {
        calls.append(call)
        let key = "\(call.method) \(call.path)"
        if let failure = failures[key] { throw failure }
        if let left = transientFailures[key], left > 0 {
            transientFailures[key] = left - 1
            throw URLError(.timedOut)
        }
        return responses[key] ?? JSON()
    }

    var last: Call? { calls.last }
}

/// Records `plugins.manage` calls and answers them.
private final class RecordingGateway: GatewayCalling {
    private(set) var calls: [(method: String, params: JSONValue, timeout: TimeInterval?)] = []
    var reply: (JSONValue) -> JSONValue = { _ in ["ok": true] }

    func call(_ method: String, params: JSONValue, timeout: TimeInterval?) async throws -> JSONValue {
        calls.append((method, params, timeout))
        return reply(params)
    }
}

final class CapabilitiesTests: XCTestCase {
    private func object(_ text: String) throws -> JSON {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)
    }

    private func any(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func value(_ text: String) throws -> JSONValue {
        try JSONValue(jsonData: Data(text.utf8))
    }

    /// The body as a canonical JSON string, so dictionaries compare whole.
    private func canonical(_ body: JSON?) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body ?? [:], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Skills decoding

    func testSkillListDecodesLeniently() throws {
        let skills = CapabilitySkill.list(try any("""
        [{"name": "pdf-tools", "description": "Read PDFs", "category": "documents", "enabled": false, "usage": 4,
          "provenance": "hub", "path": "/srv/x", "tags": ["a"], "future": {"kind": "new"}},
         {"name": " solo ", "category": "", "usage": "7", "provenance": "martian"},
         {"name": "", "description": "no name"},
         {"description": "missing name"},
         "not a row",
         {"name": "neg", "usage": -3, "enabled": "yes", "provenance": "EXTERNAL"}]
        """))
        XCTAssertEqual(skills.map(\.name), ["pdf-tools", "solo", "neg"])
        XCTAssertEqual(skills[0], CapabilitySkill(name: "pdf-tools", description: "Read PDFs", category: "documents", enabled: false,
                                                  usage: 4, provenance: .hub))
        XCTAssertEqual(skills[1].category, "general", "a blank category reads as general")
        XCTAssertEqual(skills[1].usage, 7)
        XCTAssertEqual(skills[1].provenance, .agent, "an unknown provenance reads as learned")
        XCTAssertTrue(skills[1].enabled, "older rows without the flag are on")
        XCTAssertEqual(skills[2].usage, 0)
        XCTAssertTrue(skills[2].enabled, "a string isn't a boolean")
        XCTAssertEqual(skills[2].provenance, .external)
        XCTAssertEqual(CapabilitySkill.list(try any(#"{"skills": [{"name": "wrapped"}]}"#)).map(\.name), ["wrapped"])
        XCTAssertEqual(CapabilitySkill.list(try any(#"{"detail": "nope"}"#)), [])
        XCTAssertEqual(CapabilitySkill(name: "x", category: "software-development").categoryLabel, "Software Development")
        XCTAssertEqual(CapabilitySearch.label("browse.sh"), "browse.sh")
    }

    func testSkillProvenanceRules() {
        XCTAssertTrue(SkillProvenance.agent.editable)
        XCTAssertTrue(SkillProvenance.external.editable)
        XCTAssertFalse(SkillProvenance.bundled.editable)
        XCTAssertFalse(SkillProvenance.hub.editable)
        XCTAssertEqual(SkillProvenance.allCases.map(\.label), ["Learned", "Built-in", "Hub", "External"])
    }

    func testHubShapesDecodeLeniently() throws {
        let official = OfficialSkill.list(try any("""
        {"skills": [{"name": "arxiv", "description": "Papers", "identifier": "official/research/arxiv", "category": "research",
                     "installed": true, "tags": ["papers", 3, ""], "trust_level": "builtin"},
                    {"name": "bare"}, {"identifier": "official/x"}]}
        """))
        XCTAssertEqual(official.map(\.name), ["arxiv", "bare"])
        XCTAssertTrue(official[0].installed)
        XCTAssertEqual(official[0].tags, ["papers"])
        XCTAssertEqual(official[1].identifier, "official/bare")
        XCTAssertEqual(official[1].category, "general")
        XCTAssertFalse(official[1].installed)

        let search = HubSearchResponse(response: try any("""
        {"results": [{"name": "a", "identifier": "github/x/a", "trust_level": "trusted", "repo": null, "tags": []},
                     {"name": "b", "source": "clawhub"}, {"bogus": true}],
         "source_counts": {"github": 1}, "timed_out": ["lobehub"], "installed": {"github/x/a": {"name": "a"}}}
        """))
        XCTAssertEqual(search.results.map(\.identifier), ["github/x/a", "b"])
        XCTAssertEqual(search.results[1].trustLevel, "community")
        XCTAssertNil(search.results[0].repo)
        XCTAssertEqual(search.timedOut, ["lobehub"])
        XCTAssertEqual(search.installed, ["github/x/a"])
        XCTAssertEqual(HubSearchResponse(response: "junk"), HubSearchResponse())

        let preview = HubSkillPreview(response: try any("""
        {"name": "a", "description": "d", "identifier": "github/x/a", "trust_level": "community",
         "skill_md": "---\\nname: a\\n---\\nbody", "files": ["SKILL.md", "ref.md"]}
        """), identifier: "github/x/a")
        XCTAssertEqual(preview.skill.name, "a")
        XCTAssertEqual(preview.files, ["SKILL.md", "ref.md"])
        XCTAssertTrue(preview.skillMarkdown.hasPrefix("---"))
        XCTAssertEqual(HubSkillPreview(response: [:] as JSON, identifier: "id").skill.name, "id")

        let scan = HubSkillScan(response: try any("""
        {"verdict": "CAUTION", "summary": "1 finding", "policy": "later", "policy_reason": null,
         "findings": [{"severity": "high", "category": "exfil", "file": "run.sh", "line": null, "description": "curl"}, 4],
         "severity_counts": {"high": 1}, "tier1": null}
        """))
        XCTAssertEqual(scan.verdict, "caution")
        XCTAssertEqual(scan.verdictLabel, "Caution")
        XCTAssertEqual(scan.policy, .ask, "an unknown policy asks")
        XCTAssertEqual(scan.findings.count, 1)
        XCTAssertNil(scan.findings[0].line)
        XCTAssertEqual(HubSkillScan(response: try any(#"{"policy": "block"}"#)).policyLabel, "Install blocked by policy")
    }

    func testActionShapesDecode() throws {
        let started = CapabilityAction(response: try any(#"{"ok": true, "pid": 42, "name": "skills-install-a-1234"}"#), fallbackName: "x")
        XCTAssertEqual(started, CapabilityAction(name: "skills-install-a-1234"))
        XCTAssertEqual(CapabilityAction(response: [:] as JSON, fallbackName: "skills-update").name, "skills-update")
        XCTAssertFalse(CapabilityAction(response: try any(#"{"ok": false}"#), fallbackName: "x").ok)

        let running = CapabilityActionStatus(response: try any(#"{"name": "n", "running": true, "exit_code": null, "lines": ["a", 2, "b"]}"#), name: "n")
        XCTAssertTrue(running.running)
        XCTAssertEqual(running.lines, ["a", "b"])
        XCTAssertFalse(running.succeeded)
        XCTAssertFalse(running.failed)
        let failed = CapabilityActionStatus(response: try any(#"{"running": false, "exit_code": 1, "lines": []}"#), name: "n")
        XCTAssertTrue(failed.failed)
        XCTAssertEqual(failed.name, "n")
        XCTAssertTrue(CapabilityActionStatus(response: try any(#"{"running": false, "exit_code": "0"}"#), name: "n").succeeded)
    }

    func testFrontmatterSplitsMetaAndBody() {
        let parsed = SkillFrontmatter("---\nname: pdf\ndescription: Read PDFs\nmetadata:\n  tags: [a, b]\n  hermes: x\n---\n# PDF\n\nSteps")
        XCTAssertEqual(parsed.meta.map(\.key), ["name", "description", "metadata"])
        XCTAssertEqual(parsed.meta[1].value, "Read PDFs")
        XCTAssertEqual(parsed.meta[2].value, "tags: [a, b]\nhermes: x")
        XCTAssertEqual(parsed.body, "# PDF\n\nSteps")

        let crlf = SkillFrontmatter("---\r\nname: a\r\n---\r\nbody\r\n")
        XCTAssertEqual(crlf.meta.map(\.value), ["a"])
        XCTAssertEqual(crlf.body, "body\n")

        XCTAssertEqual(SkillFrontmatter("# No frontmatter").body, "# No frontmatter")
        XCTAssertTrue(SkillFrontmatter("# No frontmatter").meta.isEmpty)
        XCTAssertEqual(SkillFrontmatter("---\nname: open but never closed").meta, [])
    }

    // MARK: Skills requests

    func testSkillRequestsAreScopedAndShaped() async throws {
        let transport = RecordingCapabilitiesTransport()
        let api = SkillsAPI(transport: transport, profile: "work")

        try await api.setEnabled("pdf", false)
        XCTAssertEqual(transport.last?.method, "PUT")
        XCTAssertEqual(transport.last?.path, "/api/skills/toggle")
        XCTAssertEqual(transport.last?.query, ["profile": "work"])
        XCTAssertEqual(try canonical(transport.last?.body), #"{"enabled":false,"name":"pdf"}"#)

        try await api.saveContent("pdf", "---\nname: pdf\n---\nx")
        XCTAssertEqual(transport.last?.path, "/api/skills/content")
        XCTAssertEqual(transport.last?.method, "PUT")
        XCTAssertEqual(transport.last?.body?["content"] as? String, "---\nname: pdf\n---\nx")
        XCTAssertEqual(transport.last?.body?["name"] as? String, "pdf")

        try await api.create(name: " notes ", content: "c", category: "  ")
        XCTAssertEqual(transport.last?.method, "POST")
        XCTAssertEqual(transport.last?.path, "/api/skills")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"content":"c","name":"notes"}"#, "a blank category is left out")
        XCTAssertEqual(try canonical(SkillsAPI.createBody(name: "n", content: "c", category: " ops ")), #"{"category":"ops","content":"c","name":"n"}"#)

        transport.responses["GET /api/skills/content"] = ["name": "pdf", "content": "body", "path": "/host/path/SKILL.md"]
        let document = try await api.content("pdf")
        XCTAssertEqual(document, SkillDocument(name: "pdf", content: "body"))
        XCTAssertEqual(transport.last?.query, ["profile": "work", "name": "pdf"])

        transport.responses["DELETE /api/learning/node"] = ["ok": true, "message": "archived"]
        try await api.archive("pdf")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"id":"pdf"}"#)
        transport.responses["DELETE /api/learning/node"] = ["ok": false, "message": "not a learned skill"]
        do {
            try await api.archive("pdf")
            XCTFail("an ok:false answer is a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "not a learned skill")
        }

        transport.responses["POST /api/skills/hub/install"] = ["ok": true, "pid": 9, "name": "skills-install-pdf-abcd"]
        let action = try await api.install("official/docs/pdf")
        XCTAssertEqual(action.name, "skills-install-pdf-abcd")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"identifier":"official\/docs\/pdf"}"#)
        _ = try await api.uninstall("pdf")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"name":"pdf"}"#)
        _ = try await api.updateAll()
        XCTAssertEqual(transport.last?.path, "/api/skills/hub/update")

        let count = transport.calls.count
        let empty = try await api.search("   ")
        XCTAssertEqual(empty, HubSearchResponse())
        XCTAssertEqual(transport.calls.count, count, "an empty hub search never leaves the phone")
        _ = try await api.search(" pdf ")
        XCTAssertEqual(transport.last?.query, ["profile": "work", "q": "pdf", "source": "all", "limit": "20"])
        XCTAssertEqual(transport.last?.timeout, SkillsAPI.hubTimeout, "a hub search waits past the client's 30 s")
        XCTAssertGreaterThanOrEqual(SkillsAPI.hubTimeout, 45, "at least the desktop's HUB_REQUEST_TIMEOUT_MS")
        _ = try await api.preview("official/docs/pdf")
        XCTAssertEqual(transport.last?.path, "/api/skills/hub/preview")
        XCTAssertEqual(transport.last?.timeout, SkillsAPI.hubTimeout)
        _ = try await api.scan("official/docs/pdf")
        XCTAssertEqual(transport.last?.path, "/api/skills/hub/scan")
        XCTAssertEqual(transport.last?.timeout, SkillsAPI.hubTimeout)
        _ = try await api.official()
        XCTAssertNil(transport.last?.timeout, "the local catalog read keeps the usual wait")

        let unscoped = SkillsAPI(transport: transport, profile: nil)
        _ = try await unscoped.skills()
        XCTAssertEqual(transport.last?.query, [:], "the dashboard's own profile sends no scope")

        _ = try await CapabilityActionsAPI(transport: transport).status("skills-install-pdf-abcd")
        XCTAssertEqual(transport.last?.path, "/api/actions/skills-install-pdf-abcd/status")
        XCTAssertEqual(transport.last?.query, ["lines": "200"])
    }

    func testActionTailSurvivesAFewFailedReads() async throws {
        let transport = RecordingCapabilitiesTransport()
        let key = "GET /api/actions/skills-install-pdf-abcd/status"
        transport.responses[key] = ["name": "skills-install-pdf-abcd", "running": false, "exit_code": 0, "lines": ["done"]]
        transport.transientFailures[key] = 2
        let actions = CapabilityActionsAPI(transport: transport)
        var updates = 0
        let finished = try await actions.follow("skills-install-pdf-abcd", interval: .milliseconds(1), tolerance: 3) { _ in
            updates += 1
        }
        XCTAssertTrue(finished.succeeded)
        XCTAssertEqual(updates, 1, "failed reads report nothing")
        XCTAssertEqual(transport.calls.count, 3)

        transport.transientFailures[key] = 10
        do {
            _ = try await actions.follow("skills-install-pdf-abcd", interval: .milliseconds(1), tolerance: 3) { _ in }
            XCTFail("three failed reads in a row give up")
        } catch let lost as CapabilityActionLost {
            XCTAssertEqual(lost.name, "skills-install-pdf-abcd")
            XCTAssertTrue(lost.localizedDescription.contains("may still be running on the host"))
        }
        XCTAssertEqual(transport.transientFailures[key], 7)
    }

    // MARK: Toolsets decoding

    func testToolsetShapesDecodeLeniently() throws {
        let toolsets = CapabilityToolset.list(try any("""
        [{"name": "web", "label": "🔍 Web Search & Scraping", "description": "web_search", "platform": "cli", "enabled": true,
          "available": true, "configured": false, "tools": ["web_search", "web_extract"]},
         {"name": "vision", "label": "👁️  Vision / Image Analysis", "enabled": false},
         {"name": "plain"}, {"label": "no name"}]
        """))
        XCTAssertEqual(toolsets.map(\.name), ["web", "vision", "plain"])
        XCTAssertEqual(toolsets[0].label, "Web Search & Scraping")
        XCTAssertFalse(toolsets[0].configured)
        XCTAssertEqual(toolsets[1].label, "Vision / Image Analysis")
        XCTAssertTrue(toolsets[2].configured, "older rows without the flag aren't flagged")
        XCTAssertEqual(toolsets[2].label, "plain")
        XCTAssertEqual(toolsets[0].calls(["web_search": 3, "web_extract": 2, "other": 9]), 5)
        XCTAssertEqual(ToolsetCuration.displayLabel("C++ Tools"), "C++ Tools")

        let setup = ToolsetSetup(response: try any("""
        {"name": "web", "has_category": true, "active_provider": "Firecrawl",
         "active_search_backend": "firecrawl", "active_extract_backend": null, "search_via_nous": false, "extract_via_nous": true,
         "providers": [
           {"name": "Nous Subscription", "badge": "", "tag": "Included", "env_vars": [], "post_setup": null,
            "requires_nous_auth": true, "managed_nous_feature": "web", "is_active": false, "status": "needs_auth",
            "web_backend": "firecrawl", "capabilities": ["search", "extract"]},
           {"name": "Firecrawl", "badge": "paid", "tag": "", "is_active": true, "status": "brand_new_state",
            "web_backend": "firecrawl", "capabilities": ["search", "extract"],
            "env_vars": [{"key": "FIRECRAWL_API_KEY", "prompt": "Firecrawl key", "url": "https://firecrawl.dev", "default": null, "is_set": false},
                         {"key": "FIRECRAWL_URL", "default": "https://api.firecrawl.dev", "is_set": true}, {"prompt": "no key"}]},
           {"name": "Lightpanda", "post_setup": "lightpanda", "env_vars": "junk"}]}
        """), name: "web")
        XCTAssertTrue(setup.hasCategory)
        XCTAssertEqual(setup.providers.map(\.name), ["Nous Subscription", "Firecrawl", "Lightpanda"])
        XCTAssertEqual(setup.providers[0].status, .needsAuth)
        XCTAssertEqual(setup.providers[1].status, .ready, "an unknown status reads as ready")
        XCTAssertEqual(setup.providers[1].envKeys.map(\.key), ["FIRECRAWL_API_KEY", "FIRECRAWL_URL"])
        XCTAssertEqual(setup.providers[1].envKeys[1].prompt, "FIRECRAWL_URL")
        XCTAssertEqual(setup.providers[1].envKeys[1].defaultValue, "https://api.firecrawl.dev")
        XCTAssertNil(setup.providers[2].status)
        XCTAssertEqual(setup.providers[2].postSetup, "lightpanda")
        XCTAssertTrue(setup.providers[2].envKeys.isEmpty)
        XCTAssertEqual(setup.initialProvider, "Firecrawl", "the active provider opens first")
        XCTAssertTrue(setup.reportsWebBackends)
        XCTAssertTrue(setup.serves(setup.providers[1], search: true))
        XCTAssertFalse(setup.serves(setup.providers[1], search: false), "extract rides the Nous gateway")
        XCTAssertTrue(setup.serves(setup.providers[0], search: false))
        XCTAssertEqual(setup.webBackendLabel(search: false), "Nous Subscription")
        XCTAssertEqual(setup.webBackendLabel(search: true), "firecrawl")

        // Keys saved on the phone win over the server's stale readiness.
        let firecrawl = setup.providers[1]
        XCTAssertEqual(firecrawl.readiness([:]), .needsKeys)
        XCTAssertEqual(firecrawl.readiness(["FIRECRAWL_API_KEY": true]), .ready)
        XCTAssertEqual(setup.providers[0].readiness([:]), .needsAuth)
        XCTAssertEqual(setup.providers[2].readiness([:]), .ready)

        let bare = ToolsetSetup(response: try any(#"{"name": "todo", "has_category": false, "providers": []}"#), name: "todo")
        XCTAssertFalse(bare.hasCategory)
        XCTAssertFalse(bare.reportsWebBackends)
        XCTAssertNil(bare.initialProvider)

        let models = ToolsetModelCatalog(response: try any("""
        {"name": "image_gen", "has_models": true, "provider": "FAL", "plugin": "fal", "current": null, "default": "flux",
         "models": [{"id": "flux", "display": "FLUX", "speed": "fast", "strengths": "", "price": "$"}, {"display": "no id"}]}
        """))
        XCTAssertEqual(models.models.map(\.id), ["flux"])
        XCTAssertEqual(models.selected, "flux", "nothing chosen yet: the default is in use")
        XCTAssertTrue(ToolsetModelCatalog(response: try any(#"{"has_models": false, "models": [{"id": "x"}]}"#)).models.isEmpty)

        let backends = TerminalBackend.list(try any("""
        {"active": "docker", "backends": [{"name": "local", "label": "Local", "description": "This machine", "active": false, "status": "ready", "detail": ""},
          {"name": "docker", "label": "Docker", "active": true, "status": "needs_setup", "detail": "Docker not reachable"},
          {"name": "plugin_x", "status": "warming_up"}]}
        """))
        XCTAssertEqual(backends.map(\.name), ["local", "docker", "plugin_x"])
        XCTAssertEqual(backends[1].status, .needsSetup)
        XCTAssertEqual(backends[2].status, .unavailable, "an unknown probe status isn't ready")
        XCTAssertEqual(backends[2].label, "Plugin X")

        let computer = ComputerUseStatus(response: try any("""
        {"platform": "darwin", "platform_supported": true, "installed": true, "version": "cua-driver 0.5", "ready": null,
         "can_grant": true, "checks": [], "accessibility": true, "screen_recording": false, "error": null}
        """))
        XCTAssertNil(computer.ready)
        XCTAssertEqual(computer.accessibility, true)
        XCTAssertEqual(computer.screenRecording, false)

        XCTAssertEqual(ToolsetsAPI.toolCalls(try any("""
        {"tools": [{"tool": "web_search", "count": 3}, {"tool": "web_search", "count": 2}, {"name": "todo", "count": "4"},
                   {"count": 9}, {"tool": "x", "count": -1}]}
        """)), ["web_search": 5, "todo": 4, "x": 0])
        XCTAssertEqual(ToolsetsAPI.toolCalls(try any("[]")), [:])
    }

    // MARK: Toolsets requests

    func testToolsetRequestsAreScopedAndShaped() async throws {
        let transport = RecordingCapabilitiesTransport()
        let api = ToolsetsAPI(transport: transport, profile: "work")

        transport.responses["PUT /api/tools/toolsets/browser"] = ["ok": true, "post_setup_started": "lightpanda"]
        let started = try await api.setEnabled("browser", true)
        XCTAssertEqual(started, "lightpanda")
        XCTAssertEqual(transport.last?.query, ["profile": "work"])
        XCTAssertEqual(try canonical(transport.last?.body), #"{"enabled":true}"#)
        let none = try await api.setEnabled("todo", false)
        XCTAssertNil(none)

        _ = try await api.selectProvider("web", provider: "Brave", capability: "search")
        XCTAssertEqual(transport.last?.path, "/api/tools/toolsets/web/provider")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"capability":"search","provider":"Brave"}"#)
        transport.responses["PUT /api/tools/toolsets/image_gen/provider"] = ["ok": true, "needs_nous_auth": true, "feature": "image_gen"]
        let choice = try await api.selectProvider("image_gen", provider: "Nous Subscription")
        XCTAssertTrue(choice.needsNousAuth)
        XCTAssertEqual(try canonical(transport.last?.body), #"{"provider":"Nous Subscription"}"#)

        try await api.saveKeys("web", ["FIRECRAWL_API_KEY": "  fc-secret-value-123  ", "FIRECRAWL_URL": " "])
        XCTAssertEqual(transport.last?.path, "/api/tools/toolsets/web/env")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"env":{"FIRECRAWL_API_KEY":"fc-secret-value-123"}}"#,
                       "values are trimmed and blank ones are never sent")

        let sent = transport.calls.count
        for refused in [["K": "   "], ["K": "«redacted:fc-s...0123»"], ["K": "abcd...wxyz"]] {
            do {
                try await api.saveKeys("web", refused)
                XCTFail("\(refused) must not be sent")
            } catch {}
        }
        XCTAssertEqual(transport.calls.count, sent, "an empty value or a saved key's preview never leaves the phone")

        transport.failures["PUT /api/tools/toolsets/web/env"] = DashboardError.http(400, #"{"detail": "Bad key fc-secret-value-123"}"#)
        do {
            try await api.saveKeys("web", ["FIRECRAWL_API_KEY": "fc-secret-value-123"])
            XCTFail("the refusal comes through")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("fc-secret-value-123"), "an error never echoes the typed key")
        }

        try await api.removeKey("FIRECRAWL_API_KEY")
        XCTAssertEqual(transport.last?.method, "DELETE")
        XCTAssertEqual(transport.last?.path, "/api/env")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"key":"FIRECRAWL_API_KEY","profile":"work"}"#)
        transport.failures["DELETE /api/env"] = DashboardError.http(404, "gone")
        try await api.removeKey("FIRECRAWL_API_KEY")

        _ = try await api.runPostSetup("browser", key: "lightpanda")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"key":"lightpanda"}"#)
        try await api.selectModel("image_gen", model: "flux", provider: "FAL")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"model":"flux","provider":"FAL"}"#)
        _ = try await api.models("image_gen", provider: "FAL")
        XCTAssertEqual(transport.last?.query, ["profile": "work", "provider": "FAL"])
        try await api.selectTerminalBackend("docker")
        XCTAssertEqual(transport.last?.path, "/api/tools/terminal/backend")
        XCTAssertEqual(try canonical(transport.last?.body), #"{"backend":"docker"}"#)
        _ = try await api.toolCalls()
        XCTAssertEqual(transport.last?.path, "/api/analytics/usage")
        XCTAssertEqual(transport.last?.query, ["profile": "work", "days": "365"])
    }

    // MARK: Plugins

    func testPluginRowsDecodeLeniently() throws {
        let plugins = PluginsAPI.plugins(try value("""
        {"plugins": [
          {"name": "hermes_voice", "key": "hermes_voice", "version": "0.1.0", "description": "Calls", "source": "git",
           "status": "enabled", "portable": false, "install_dir": "/srv", "has_desktop_half": false,
           "servers": [{"name": "app", "state": "app_not_running", "sentence": "Start the app."}, {"state": "connected"}],
           "settings_schema": [{"key": "a"}, {"key": "b"}], "future_field": [1, 2]},
          {"name": "legacy", "version": 3, "status": "Not Enabled"},
          {"name": "fal", "key": "image_gen/fal", "source": "bundled", "status": "disabled", "catalog_name": "fal",
           "catalog_tier": "verified", "installed_sha": "abcdef0123", "catalog_sha": "0123456789abcdef0123456789abcdef01234567",
           "update_available": true, "servers": null},
          {"key": "no-name"}], "user_count": 1}
        """))
        XCTAssertEqual(plugins.map(\.name), ["hermes_voice", "legacy", "fal"])
        let voice = plugins[0]
        XCTAssertTrue(voice.enabled)
        XCTAssertTrue(voice.toggleable)
        XCTAssertTrue(voice.removable)
        XCTAssertEqual(voice.servers.map(\.name), ["app"])
        XCTAssertEqual(voice.servers[0].stateLabel, "app not running")
        XCTAssertEqual(voice.settingsCount, 2)
        XCTAssertEqual(voice.provenance, "git")
        let legacy = plugins[1]
        XCTAssertFalse(legacy.toggleable, "a row without a key is read-only")
        XCTAssertEqual(legacy.version, "")
        XCTAssertEqual(legacy.status, "not enabled")
        XCTAssertFalse(legacy.enabled)
        XCTAssertEqual(legacy.id, "legacy")
        let fal = plugins[2]
        XCTAssertFalse(fal.removable, "bundled plugins can't be uninstalled")
        XCTAssertEqual(fal.provenance, "Verified")
        XCTAssertEqual(fal.updateLabel, "01234567")
        XCTAssertTrue(PluginsAPI.plugins(try value(#"{"ok": false}"#)).isEmpty)
        XCTAssertEqual(AgentPluginServer(row: ["name": "s", "state": "teleporting"])?.stateLabel, "status unknown")
    }

    func testPluginCurationListsWhatTheUserManages() {
        func plugin(_ name: String, key: String?, source: String) -> AgentPlugin { AgentPlugin(name: name, key: key, source: source) }
        XCTAssertTrue(PluginCuration.isListed(plugin("hermes_voice", key: "hermes_voice", source: "git")), "our own plugin lists like any other")
        XCTAssertTrue(PluginCuration.isListed(plugin("disk-cleanup", key: "disk-cleanup", source: "bundled")))
        XCTAssertFalse(PluginCuration.isListed(plugin("fal", key: "image_gen/fal", source: "bundled")))
        XCTAssertFalse(PluginCuration.isListed(plugin("telegram", key: "platforms/telegram", source: "user")))
        XCTAssertFalse(PluginCuration.isListed(plugin("x", key: "model-providers/x", source: "entrypoint")))
        XCTAssertTrue(PluginCuration.isListed(plugin("old", key: nil, source: "user")))

        let installed = [plugin("b-plugin", key: "b", source: "user"), plugin("A-plugin", key: "a", source: "git"),
                         plugin("hidden", key: "platforms/x", source: "user")]
        XCTAssertEqual(PluginCuration.filter(installed, query: "").map(\.name), ["A-plugin", "b-plugin"])
        XCTAssertEqual(PluginCuration.filter(installed, query: " B-PL ").map(\.name), ["b-plugin"])

        var mine = plugin("spotify-local", key: "spotify", source: "git")
        mine.catalogName = "spotify"
        let catalog = PluginCatalogEntry.list([
            "entries": [
                ["name": "spotify", "repo": "https://example.com/spotify.git", "sha": "s", "description": "Music", "maintainer": "m",
                 "tier": "verified", "installed": false],
                ["name": "nvidia", "repo": "https://example.com/n.git", "subdir": "plugins/n", "description": "GPU", "tier": "OFFICIAL",
                 "capabilities": ["provides_tools": ["gpu_status"], "requires_env": ["NV_KEY"]], "installed": false],
                ["name": "done", "repo": "https://example.com/d.git", "installed": true],
                ["name": "norepo"],
            ] as [Any],
        ] as JSON)
        XCTAssertEqual(catalog.map(\.name), ["spotify", "nvidia", "done"])
        XCTAssertEqual(catalog[1].installIdentifier, "https://example.com/n.git#plugins/n")
        XCTAssertEqual(catalog[0].installIdentifier, "https://example.com/spotify.git")
        XCTAssertEqual(catalog[1].tierLabel, "Official")
        XCTAssertEqual(catalog[1].tools, ["gpu_status"])
        XCTAssertEqual(catalog[1].requiresEnv, ["NV_KEY"])
        XCTAssertEqual(catalog[2].title, "Done")
        XCTAssertEqual(PluginCuration.available(catalog, installed: [mine], query: "").map(\.name), ["nvidia"],
                       "installed entries, by flag or by catalog name, aren't offered")
        XCTAssertEqual(PluginCuration.available(catalog, installed: [], query: "gpu_status").map(\.name), ["nvidia"],
                       "search reads the tools a plugin registers")
    }

    func testPluginResultsDecode() throws {
        let outcome = PluginInstallOutcome(result: try value("""
        {"ok": true, "plugin_name": "spotify", "warnings": ["w1"], "missing_env": ["SPOTIFY_ID"], "enabled": true,
         "activation": {"live_now": {"skills": [{"name": "spotify:play"}, "bare"],
                                     "mcp_servers": [{"name": "s", "connected": true, "tools": ["a", "b"]},
                                                     {"name": "t", "connected": false, "tools": ["c"]}]},
                        "deferred": {"tools": ["x"]}}}
        """))
        XCTAssertEqual(outcome.liveSkills, ["play", "bare"])
        XCTAssertEqual(outcome.liveTools, 2)
        XCTAssertTrue(outcome.nextChat)
        XCTAssertEqual(outcome.missingEnv, ["SPOTIFY_ID"])
        XCTAssertEqual(outcome.summary(fallbackName: "x"),
                       "spotify installed · 2 tools connected · 2 skills ready · more tools available in your next chat")
        XCTAssertEqual(PluginInstallOutcome(result: ["ok": true]).summary(fallbackName: "repo"), "repo installed")

        XCTAssertEqual(try PluginUpdateOutcome(result: ["ok": true]), .applied)
        XCTAssertEqual(try PluginUpdateOutcome(result: ["ok": true, "unchanged": true]), .unchanged)
        XCTAssertEqual(try PluginUpdateOutcome(result: try value("""
        {"ok": false, "consent_required": true, "sha": "0123456789abcdef", "delta_lines": ["+ tool: x"]}
        """)), .consent(sha: "01234567", deltaLines: ["+ tool: x"]))
        XCTAssertEqual(try PluginUpdateOutcome(result: try value("""
        {"ok": false, "scan_blocked": true, "scan_verdict": "caution",
         "scan_findings": [{"severity": "medium", "file": "a.py", "line": 3, "description": "eval"}]}
        """)), .scan(verdict: "caution", findings: ["medium · a.py · eval"]))
        XCTAssertThrowsError(try PluginUpdateOutcome(result: ["ok": false, "error": "pinned"])) { error in
            XCTAssertEqual(error.localizedDescription, "pinned")
        }
    }

    func testPluginRequestsAreScopedAndShaped() async throws {
        let gateway = RecordingGateway()
        let api = PluginsAPI(gateway: gateway, profile: "work")

        gateway.reply = { _ in ["plugins": [["name": "p", "key": "p"]]] }
        let listed = try await api.list()
        XCTAssertEqual(listed.map(\.name), ["p"])
        XCTAssertEqual(gateway.calls.last?.method, "plugins.manage")
        XCTAssertEqual(gateway.calls.last?.params, ["action": "list", "profile": "work"])

        gateway.reply = { _ in ["ok": true, "plugin": ["name": "p", "key": "p", "status": "disabled"]] }
        let refreshed = try await api.toggle(key: "p", enable: false)
        XCTAssertEqual(refreshed?.status, "disabled")
        XCTAssertEqual(gateway.calls.last?.params, ["action": "toggle", "profile": "work", "key": "p", "enable": false])

        gateway.reply = { _ in ["ok": true, "plugin_name": "p"] }
        _ = try await api.install(identifier: " owner/repo ", catalogName: nil, enable: true, force: false, ref: " ")
        XCTAssertEqual(gateway.calls.last?.params, ["action": "install", "profile": "work", "identifier": "owner/repo",
                                                    "force": false, "enable": true], "a blank pin is left out")
        XCTAssertEqual(gateway.calls.last?.timeout, PluginsAPI.installTimeout)
        _ = try await api.install(identifier: "https://example.com/r.git#sub", catalogName: "r", enable: false, force: true,
                                  ref: "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(gateway.calls.last?.params["catalog_name"], "r")
        XCTAssertEqual(gateway.calls.last?.params["ref"], "0123456789abcdef0123456789abcdef01234567")
        XCTAssertEqual(gateway.calls.last?.params["enable"], false)

        gateway.reply = { _ in ["ok": false, "error": "clone failed"] }
        do {
            _ = try await api.install(identifier: "x")
            XCTFail("ok:false is a failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "clone failed")
        }

        gateway.reply = { _ in ["ok": true] }
        _ = try await api.update(name: "p", acceptCapabilities: true)
        XCTAssertEqual(gateway.calls.last?.params, ["action": "update", "profile": "work", "name": "p", "accept_capabilities": true])
        try await api.remove(name: "p")
        XCTAssertEqual(gateway.calls.last?.params, ["action": "remove", "profile": "work", "name": "p"])

        _ = try await PluginsAPI(gateway: gateway, profile: nil).list()
        XCTAssertEqual(gateway.calls.last?.params, ["action": "list"], "the launch profile sends no scope")

        XCTAssertTrue(PluginsAPI.isCommit("0123456789ABCDEF0123456789abcdef01234567"))
        XCTAssertFalse(PluginsAPI.isCommit("main"))
        XCTAssertFalse(PluginsAPI.isCommit("0123456"))
    }

    // MARK: Search, filters and the strip rule

    func testSkillSearchAndOrder() {
        let skills = [
            CapabilitySkill(name: "zeta", description: "x", category: "ops", usage: 0),
            CapabilitySkill(name: "alpha", category: "research", usage: 0),
            CapabilitySkill(name: "busy", category: "ops", usage: 9),
        ]
        XCTAssertEqual(CapabilitySearch.skills(skills, query: "").map(\.name), ["busy", "alpha", "zeta"], "most used first, then A–Z")
        XCTAssertEqual(CapabilitySearch.skills(skills, query: " OPS ").map(\.name), ["busy", "zeta"], "search reads categories")
        XCTAssertEqual(CapabilitySearch.skills(skills, query: "nothing"), [])
        XCTAssertEqual(CapabilitySearch.skillHints(skills), ["ops", "research"])

        let official = OfficialSkill.list(["skills": [
            ["name": "b", "tags": ["pdf"]], ["name": "a", "description": "PDF reader"], ["name": "c"],
        ]] as JSON)
        XCTAssertEqual(CapabilitySearch.official(official, query: "pdf").map(\.name), ["a", "b"], "tags are searchable; A–Z")
    }

    func testToolsetFilterHidesCuratedAndStrippedToolsets() {
        let toolsets = ["web", "browser", "file", "code_execution", "memory", "terminal", "todo", "kanban", "spotify",
                        "discord", "moa", "tts", "stt", "voice", "wake_word"].map { CapabilityToolset(name: $0, tools: ["\($0)_tool"]) }
        let visible = ToolsetCuration.filter(toolsets, query: "", calls: [:])
        XCTAssertEqual(Set(visible.map(\.name)), ["web", "browser", "file", "code_execution", "memory", "terminal", "todo", "kanban", "spotify"])
        XCTAssertEqual(ToolsetCuration.filter(toolsets, query: "spotify_tool", calls: [:]).map(\.name), ["spotify"], "search reads tool names")
        XCTAssertEqual(ToolsetCuration.filter(toolsets, query: "tts", calls: [:]), [], "a stripped toolset never shows, even searched for")

        // Before there is usage: the essentials lead, the rest sit under what they do; empty groups are left out.
        let sections = ToolsetCuration.sections(visible, query: "", calls: nil)
        XCTAssertEqual(sections.map(\.id), ["featured", "work", "connect"])
        XCTAssertEqual(sections[0].label, "Essentials")
        XCTAssertEqual(Set(sections[0].toolsets.map(\.name)), ["browser", "file", "code_execution", "memory"])
        XCTAssertFalse(sections[1].toolsets.contains { ["browser", "file"].contains($0.name) }, "a featured toolset isn't listed twice")
        XCTAssertEqual(sections.last?.toolsets.map(\.name), ["spotify"])

        // With calls for the top four: they are the feature row, most used first.
        let calls = ["todo_tool": 9, "web_tool": 8, "kanban_tool": 7, "spotify_tool": 6]
        let ranked = ToolsetCuration.sections(ToolsetCuration.filter(toolsets, query: "", calls: calls), query: "", calls: calls)
        XCTAssertEqual(ranked[0].label, "Most used")
        XCTAssertEqual(ranked[0].toolsets.map(\.name), ["todo", "web", "kanban", "spotify"])

        XCTAssertFalse(ToolsetCuration.sections(visible, query: "web", calls: nil).contains { $0.id == "featured" }, "no feature row while searching")
        XCTAssertFalse(ToolsetCuration.sections(Array(visible.prefix(8)), query: "", calls: nil).contains { $0.id == "featured" },
                       "no feature row with eight toolsets or fewer")
    }

    func testStripRuleMatchesSettings() {
        for prefix in SettingsCatalog.strippedPrefixes {
            XCTAssertTrue(ToolsetCuration.isStripped(String(prefix.dropLast())), "\(prefix) toolsets are stripped like their config keys")
        }
        XCTAssertTrue(ToolsetCuration.isStripped("TTS"))
        XCTAssertFalse(ToolsetCuration.isStripped("web"))
        XCTAssertFalse(ToolsetCuration.isStripped("ttsx"), "only the exact section, as with config keys")
        XCTAssertFalse(ToolsetCuration.isVisible("stt"))
        XCTAssertFalse(ToolsetCuration.isVisible("context_engine"))
        XCTAssertTrue(ToolsetCuration.isVisible("vision"))
    }

    // MARK: Stores

    @MainActor
    func testSkillToggleRevertsWhenTheSaveFails() async throws {
        let transport = RecordingCapabilitiesTransport()
        transport.responses["GET /api/skills"] = [["name": "a", "enabled": true], ["name": "b", "enabled": true, "usage": 2]] as [Any]
        let store = SkillsStore(api: SkillsAPI(transport: transport, profile: nil), actions: CapabilityActionsAPI(transport: transport))
        await store.reloadSkills()
        transport.failures["PUT /api/skills/toggle"] = DashboardError.http(500, "boom")
        // The reload after the failure answers the server's truth, which still has it on.
        await store.setEnabled([try XCTUnwrap(store.skill(named: "a"))], false)
        XCTAssertEqual(store.skill(named: "a")?.enabled, true)
        XCTAssertNotNil(store.failure)
        XCTAssertFalse(store.busy)
    }

    @MainActor
    func testSkillBulkChangesOnlyWhatDiffersOneAtATime() async throws {
        let transport = RecordingCapabilitiesTransport()
        transport.responses["GET /api/skills"] = [["name": "a", "enabled": true], ["name": "b", "enabled": false],
                                                  ["name": "c", "enabled": true, "usage": 3]] as [Any]
        let store = SkillsStore(api: SkillsAPI(transport: transport, profile: "work"), actions: CapabilityActionsAPI(transport: transport))
        await store.reloadSkills()
        XCTAssertEqual(store.unused.map(\.name), ["a"])
        await store.setAll(true)
        let toggles = transport.calls.filter { $0.path == "/api/skills/toggle" }
        XCTAssertEqual(toggles.map { $0.body?["name"] as? String }, ["b"])
        XCTAssertEqual(store.notice, "Updated 1 item for new sessions.")
        await store.disableUnused()
        XCTAssertEqual(transport.calls.filter { $0.path == "/api/skills/toggle" }.last?.body?["name"] as? String, "a")
    }

    @MainActor
    func testPluginInstallReportsWhatItStillNeeds() async throws {
        let gateway = RecordingGateway()
        gateway.reply = { params in
            params["action"] == "install"
                ? ["ok": true, "plugin_name": "spotify", "missing_env": ["SPOTIFY_ID"], "warnings": []]
                : ["plugins": [["name": "spotify", "key": "spotify", "source": "git", "status": "enabled"]]]
        }
        let store = PluginsStore(api: PluginsAPI(gateway: gateway, profile: "work"),
                                 catalogAPI: PluginCatalogAPI(transport: RecordingCapabilitiesTransport()))
        let installed = await store.install(identifier: "https://example.com/spotify.git", catalogName: "spotify")
        XCTAssertTrue(installed)
        XCTAssertEqual(store.notice, "spotify installed")
        XCTAssertEqual(store.report, "spotify installed\n\nIt needs SPOTIFY_ID: set it in Settings ▸ API keys.")
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.plugins?.map(\.name), ["spotify"], "the list reloads after an install")
        XCTAssertFalse(store.installing)

        gateway.reply = { _ in ["ok": false, "error": "Remove failed."] }
        let removed = await store.remove(try XCTUnwrap(store.plugins?.first))
        XCTAssertFalse(removed)
        XCTAssertEqual(store.plugins?.count, 1, "a refused uninstall keeps the row")
        XCTAssertEqual(store.failure, "Could not uninstall spotify. Remove failed.")
    }

    @MainActor
    func testToolsetToggleRevertsWhenTheSaveFails() async throws {
        let transport = RecordingCapabilitiesTransport()
        transport.responses["GET /api/tools/toolsets"] = [["name": "web", "enabled": false]] as [Any]
        let store = ToolsetsStore(api: ToolsetsAPI(transport: transport, profile: nil))
        await store.reload()
        transport.failures["PUT /api/tools/toolsets/web"] = DashboardError.http(400, #"{"detail": "Unknown toolset: web"}"#)
        await store.setEnabled(try XCTUnwrap(store.toolset(named: "web")), true)
        XCTAssertEqual(store.toolset(named: "web")?.enabled, false)
        XCTAssertEqual(store.failure, "Failed to update web. Unknown toolset: web")
    }
}
