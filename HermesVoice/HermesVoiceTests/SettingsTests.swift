import XCTest
@testable import HermesVoice

/// A config transport that records saves and fails the ones it is told to.
private final class FakeConfigTransport: ConfigTransport {
    var schemaValue = JSONValue.object([:])
    var configValue = JSONValue.object([:])
    var saved: [JSONValue] = []
    /// Fails the save with this index (0-based), once.
    var failing: Set<Int> = []
    private var saveCount = 0

    func schema() async throws -> ConfigSchema { ConfigSchema(response: schemaValue) }
    func config() async throws -> JSONValue { configValue }

    func save(_ patch: JSONValue) async throws {
        defer { saveCount += 1 }
        if failing.contains(saveCount) { throw DashboardError.rpc("Disk is full.") }
        saved.append(patch)
    }
}

final class SettingsTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONValue(jsonData: Data(text.utf8))
    }

    // MARK: Schema decoding

    func testSchemaDecodesEveryFieldKindLeniently() throws {
        let schema = ConfigSchema(response: try json("""
        {"fields": {
          "agent.max_turns": {"type": "number", "description": "Agent → Max Turns", "category": "agent"},
          "checkpoints.enabled": {"type": "boolean", "category": "agent"},
          "approvals.mode": {"type": "select", "options": ["manual", "smart", "off"], "category": "security"},
          "memory.provider": {"type": "select", "options": ["", "honcho", null, 3, {"value": "mem0", "label": "Mem0 Cloud"}]},
          "timezone": {"type": "select", "options": ["", "UTC", "Europe/Stockholm"], "searchable": true, "clearable": true},
          "toolsets": {"type": "list"},
          "personalities": {"type": "object"},
          "terminal.cwd": {"type": "string"},
          "agent.system_prompt": {"type": "text"},
          "providers.key": {"type": "secret"},
          "future.thing": {"type": "slider", "min": 0, "max": 1.5, "step": 0.1, "restart_required": "Restart the gateway."},
          "agent.reload": {"type": "boolean", "restart_required": true},
          "_internal": {"type": "string"},
          "broken": "not an object"
        }, "category_order": ["general", "agent", 7]}
        """))

        XCTAssertEqual(schema["agent.max_turns"]?.kind, .number)
        XCTAssertEqual(schema["agent.max_turns"]?.description, "Agent → Max Turns")
        XCTAssertEqual(schema["agent.max_turns"]?.category, "agent")
        XCTAssertEqual(schema["checkpoints.enabled"]?.kind, .boolean)
        XCTAssertEqual(schema["approvals.mode"]?.options, ["manual", "smart", "off"])
        XCTAssertEqual(schema["memory.provider"]?.options, ["", "honcho", "", "3", "mem0"])
        XCTAssertEqual(schema["memory.provider"]?.optionLabels["mem0"], "Mem0 Cloud")
        XCTAssertEqual(schema["timezone"]?.searchable, true)
        XCTAssertEqual(schema["timezone"]?.clearable, true)
        XCTAssertEqual(schema["toolsets"]?.kind, .list)
        XCTAssertEqual(schema["personalities"]?.kind, .object)
        XCTAssertEqual(schema["terminal.cwd"]?.kind, .string)
        XCTAssertEqual(schema["agent.system_prompt"]?.kind, .text)
        XCTAssertEqual(schema["providers.key"]?.kind, .secret)
        XCTAssertEqual(schema["future.thing"]?.kind, .unknown("slider"))
        XCTAssertEqual(schema["future.thing"]?.minimum, 0)
        XCTAssertEqual(schema["future.thing"]?.maximum, 1.5)
        XCTAssertEqual(schema["future.thing"]?.step, 0.1)
        XCTAssertEqual(schema["future.thing"]?.restartRequired, true)
        XCTAssertEqual(schema["future.thing"]?.restartHint, "Restart the gateway.")
        XCTAssertEqual(schema["agent.reload"]?.restartRequired, true)
        XCTAssertNil(schema["agent.reload"]?.restartHint)
        XCTAssertEqual(schema["agent.max_turns"]?.restartRequired, false)
        XCTAssertNil(schema["_internal"])
        XCTAssertNil(schema["broken"])
        XCTAssertEqual(schema.categoryOrder, ["general", "agent"])
    }

    func testSchemaReadsABareFieldMapAndNothingFromJunk() throws {
        let bare = ConfigSchema(response: try json(#"{"model": {"type": "string"}}"#))
        XCTAssertEqual(bare["model"]?.kind, .string)
        XCTAssertTrue(ConfigSchema(response: .array([])).fields.isEmpty)
        XCTAssertTrue(ConfigSchema(response: try json(#"{"fields": []}"#)).fields.isEmpty)
    }

    func testFieldKindSpellingsAndInference() {
        XCTAssertEqual(ConfigFieldKind(type: " Bool "), .boolean)
        XCTAssertEqual(ConfigFieldKind(type: "integer"), .number)
        XCTAssertEqual(ConfigFieldKind(type: "enum"), .select)
        XCTAssertEqual(ConfigFieldKind(type: "array"), .list)
        XCTAssertEqual(ConfigFieldKind(type: "password"), .secret)
        XCTAssertEqual(ConfigFieldKind(type: nil), .string)
        XCTAssertEqual(ConfigFieldKind(inferredFrom: .bool(true)), .boolean)
        XCTAssertEqual(ConfigFieldKind(inferredFrom: .double(0.5)), .number)
        XCTAssertEqual(ConfigFieldKind(inferredFrom: .array([])), .list)
        XCTAssertEqual(ConfigFieldKind(inferredFrom: .object([:])), .object)
        XCTAssertEqual(ConfigFieldKind(inferredFrom: .string("x")), .string)
    }

    func testResolvedFieldFallsBackToTheConfigValue() throws {
        let schema = ConfigSchema(response: try json(#"{"fields": {"a.b": {"type": "boolean"}}}"#))
        let config = try json(#"{"a": {"b": true}, "c": {"d": [1, 2]}, "e": null}"#)
        XCTAssertEqual(schema.resolvedField("a.b", in: config)?.kind, .boolean)
        XCTAssertEqual(schema.resolvedField("c.d", in: config)?.kind, .list)
        XCTAssertNil(schema.resolvedField("e", in: config))
        XCTAssertNil(schema.resolvedField("missing.key", in: config))
    }

    // MARK: Field renderer mapping

    private func control(_ key: String, _ field: ConfigFieldSchema, _ value: JSONValue?, config: JSONValue = .object([:])) -> FieldControl {
        FieldControl.resolve(key: key, field: field, value: value, config: config)
    }

    func testControlsFollowTheFieldType() {
        XCTAssertEqual(control("checkpoints.enabled", .init(kind: .boolean), .bool(true)), .toggle)
        XCTAssertEqual(control("toolsets", .init(kind: .list), .array(["web"])), .list)
        XCTAssertEqual(control("personalities", .init(kind: .object), .object([:])), .json)
        XCTAssertEqual(control("providers.key", .init(kind: .secret), .string("x")), .secret)
        XCTAssertEqual(control("agent.system_prompt", .init(kind: .text), .string("")), .text(multiline: true))
        XCTAssertEqual(control("terminal.cwd", .init(kind: .string), .string("/srv")), .text(multiline: false))
        XCTAssertEqual(control("terminal.cwd", .init(kind: .string), .string(String(repeating: "x", count: 101))),
                       .text(multiline: true))
        // A string schema over a structured value edits the value's shape (inferred, like the desktop).
        XCTAssertEqual(control("custom.block", .init(kind: .string), .object(["a": 1])), .json)
        XCTAssertEqual(control("custom.list", .init(kind: .unknown("tags")), .array([])), .list)
        // Credential-looking keys never show in clear text.
        XCTAssertEqual(control("web.api_key", .init(kind: .string), .string("k")), .secret)
        XCTAssertEqual(control("bot.token", .init(kind: .string), .string("k")), .secret)
        XCTAssertEqual(control("fallback_providers", .init(kind: .list), .array([])), .fallbackModels)
        XCTAssertEqual(control("delegation.model", .init(kind: .string), .string("")), .delegationRoute)
    }

    func testSelectsKeepTheCurrentValueAndMergeCuratedOptions() {
        let select = ConfigFieldSchema(kind: .select, options: ["local", "docker", "vercel_sandbox"])
        // Curated list first, then the schema's extra options, then the current value.
        XCTAssertEqual(control("terminal.backend", select, .string("my_plugin")),
                       .picker(options: ["local", "docker", "singularity", "modal", "daytona", "ssh", "vercel_sandbox", "my_plugin"]))
        // A string schema with curated options is still a menu.
        XCTAssertEqual(control("approvals.mode", .init(kind: .string), .string("smart")), .picker(options: ["manual", "smart", "off"]))
        XCTAssertEqual(control("delegation.reasoning_effort", .init(kind: .select), .string("")),
                       .picker(options: [""] + SettingsCatalog.reasoningEfforts))
        XCTAssertEqual(control("memory.provider", ConfigFieldSchema(kind: .select, options: ["", "honcho"]), .string("gone")),
                       .picker(options: ["", "honcho", "gone"]))
    }

    func testSearchableSelectsDropTheEmptyChoice() {
        var timezone = ConfigFieldSchema(kind: .select, options: ["", "UTC", "Europe/Stockholm"])
        timezone.searchable = true
        timezone.clearable = true
        XCTAssertEqual(control("timezone", timezone, .string("")),
                       .searchablePicker(options: ["UTC", "Europe/Stockholm"], clearable: true))
    }

    func testPersonalityOptionsFoldCustomNamesLikeTheRuntime() throws {
        let config = try json(#"{"personalities": {" Pirate ": {}, "Mentor": {}, "none": {}}, "agent": {"personalities": {"mentor": {}, "Coach": {}}}}"#)
        let options = SettingsCatalog.personalityOptions(config)
        XCTAssertEqual(options.first, "")
        XCTAssertEqual(Array(options.suffix(2)), ["mentor", "coach"])
        XCTAssertEqual(options.filter { $0 == "pirate" }.count, 1, "a built-in name stays once")
        XCTAssertFalse(options.contains("none"))
        XCTAssertEqual(SettingsCatalog.optionLabel("", key: "display.personality", field: nil), "None")
        XCTAssertEqual(SettingsCatalog.optionLabel("", key: "memory.provider", field: nil), "Built-in only")
        XCTAssertEqual(SettingsCatalog.optionLabel("title_generation", key: "x", field: nil), "Title Generation")
    }

    func testNumberBoundsPreferTheSchemaAndKeepIntegersWhole() {
        var ranged = ConfigFieldSchema(kind: .number)
        ranged.minimum = 2
        ranged.maximum = 10
        XCTAssertEqual(control("agent.max_turns", ranged, .int(5)), .number(NumberBounds(min: 2, max: 10, integral: true)))
        XCTAssertEqual(control("agent.max_turns", .init(kind: .number), .int(90)), .number(NumberBounds(min: 1, max: nil, integral: true)))
        XCTAssertEqual(control("compression.threshold", .init(kind: .number), .double(0.5)), .number(NumberBounds(min: 0, max: 1, integral: false)))
        // A ratio stored as 0 is still a fraction field.
        XCTAssertEqual(control("compression.threshold", .init(kind: .number), .int(0)), .number(NumberBounds(min: 0, max: 1, integral: false)))
    }

    func testNullDefaultNumbersAreNumbersDespiteAStringSchema() {
        // The live schema types `agent.max_turns` as a string: its default is null.
        XCTAssertEqual(control("agent.max_turns", .init(kind: .string), .null), .number(NumberBounds(min: 1, max: nil, integral: true)))
        XCTAssertEqual(control("agent.max_turns", .init(kind: .string), nil), .number(NumberBounds(min: 1, max: nil, integral: true)))
        XCTAssertEqual(control("agent.max_turns", .init(kind: .string), .string("90")), .number(NumberBounds(min: 1, max: nil, integral: true)))
        XCTAssertEqual(control("agent.max_turns", .init(kind: .string), .string("lots")), .text(multiline: false))
        XCTAssertEqual(control("terminal.cwd", .init(kind: .string), .null), .text(multiline: false))
    }

    func testNumberParsing() {
        let whole = NumberBounds(min: 1, max: 100, integral: true)
        XCTAssertEqual(whole.parse("42"), .success(.int(42)))
        XCTAssertEqual(whole.parse(" 7 "), .success(.int(7)))
        XCTAssertEqual(whole.parse("0"), .failure(.belowMinimum(1)))
        XCTAssertEqual(whole.parse(""), .failure(.belowMinimum(1)), "empty is 0, as on the desktop")
        XCTAssertEqual(whole.parse("101"), .failure(.aboveMaximum(100)))
        XCTAssertEqual(whole.parse("2.5"), .failure(.notWhole))
        XCTAssertEqual(whole.parse("abc"), .failure(.notANumber))
        let ratio = NumberBounds(min: 0, max: 1, integral: false)
        XCTAssertEqual(ratio.parse("0,85"), .success(.double(0.85)))
        XCTAssertEqual(ratio.parse("1"), .success(.int(1)))
        XCTAssertEqual(ratio.parse("1.0"), .success(.double(1)))
        XCTAssertEqual(NumberBounds.unbounded.parse("inf"), .failure(.notANumber))
        XCTAssertEqual(whole.summary, "1 – 100")
        XCTAssertEqual(NumberBounds(min: 0, max: nil, integral: true).summary, "At least 0")
        XCTAssertNil(NumberBounds.unbounded.summary)
    }

    func testListDraftParsing() {
        XCTAssertEqual(ListDraft.parse(" one, , two,   "), ["one", "two"])
        XCTAssertEqual(ListDraft.parse("first,"), ["first"])
        XCTAssertEqual(ListDraft.text(.array(["a", 2])), "a, 2")
    }

    // MARK: Paths and patches

    func testDotPathsReadWriteAndRemove() throws {
        let config = try json(#"{"agent": {"max_turns": 90}, "model": "x"}"#)
        XCTAssertEqual(config.value(atPath: "agent.max_turns"), .int(90))
        XCTAssertNil(config.value(atPath: "agent.missing"))
        XCTAssertNil(config.value(atPath: "model.default"), "a scalar has no children")
        let set = config.settingPath("display.platforms.cli.show_reasoning", to: false)
        XCTAssertEqual(set.value(atPath: "display.platforms.cli.show_reasoning"), .bool(false))
        XCTAssertEqual(set.value(atPath: "agent.max_turns"), .int(90))
        XCTAssertEqual(config.settingPath("model.default", to: "y").value(atPath: "model.default"), .string("y"))
        XCTAssertNil(set.removingPath("agent.max_turns").value(atPath: "agent.max_turns"))
        XCTAssertNotNil(set.removingPath("agent.max_turns").value(atPath: "agent"))
    }

    func testPatchesAreSparse() {
        let patch = ConfigPatch.make([("agent.max_turns", 5), ("agent.api_max_retries", 2), ("timezone", "UTC")])
        XCTAssertEqual(patch, ["agent": ["max_turns": 5, "api_max_retries": 2], "timezone": "UTC"])
    }

    func testValueDisplayTextAndTruthiness() {
        XCTAssertEqual(JSONValue.double(3).displayText, "3")
        XCTAssertEqual(JSONValue.double(0.25).displayText, "0.25")
        XCTAssertEqual(JSONValue.null.displayText, "")
        XCTAssertTrue(JSONValue.string(" Verbose ").truthy)
        XCTAssertFalse(JSONValue.string("off").truthy)
        XCTAssertTrue(JSONValue.int(1).truthy)
    }

    // MARK: Store

    @MainActor
    private func loadedStore(_ transport: FakeConfigTransport) async -> SettingsStore {
        let store = SettingsStore(transport: transport)
        await store.load()
        return store
    }

    @MainActor
    func testEditsShowAtOnceAndSaveSparsePatches() async throws {
        let transport = FakeConfigTransport()
        transport.schemaValue = try json(#"{"fields": {"agent.max_turns": {"type": "number"}, "approvals.mode": {"type": "select", "options": ["manual", "off"]}}}"#)
        transport.configValue = try json(#"{"agent": {"max_turns": 90, "api_max_retries": 3}, "approvals": {"mode": "manual"}}"#)
        let store = await loadedStore(transport)
        XCTAssertEqual(store.phase, .loaded)

        store.set("agent.max_turns", 120)
        XCTAssertEqual(store.value("agent.max_turns"), .int(120))
        XCTAssertTrue(store.saving.contains("agent.max_turns"))
        await store.settle()
        XCTAssertFalse(store.saving.contains("agent.max_turns"))
        XCTAssertEqual(transport.saved, [["agent": ["max_turns": 120]]], "only the edited field is sent")
        XCTAssertNil(store.errors["agent.max_turns"])
    }

    @MainActor
    func testAFailedSaveRollsBackToTheConfirmedValue() async throws {
        let transport = FakeConfigTransport()
        transport.configValue = try json(#"{"agent": {"max_turns": 90}}"#)
        transport.failing = [1]
        let store = await loadedStore(transport)

        store.set("agent.max_turns", 100) // saved
        store.set("agent.max_turns", 110) // fails
        await store.settle()
        XCTAssertEqual(store.value("agent.max_turns"), .int(100), "back to what the dashboard last confirmed, not the load-time value")
        XCTAssertEqual(store.errors["agent.max_turns"], "Disk is full.")

        store.set("agent.max_turns", 105)
        XCTAssertNil(store.errors["agent.max_turns"], "a new edit clears the error")
        await store.settle()
        XCTAssertEqual(store.value("agent.max_turns"), .int(105))
    }

    @MainActor
    func testAFailedOlderSaveDoesNotUndoANewerEdit() async throws {
        let transport = FakeConfigTransport()
        transport.configValue = try json(#"{"timezone": ""}"#)
        transport.failing = [0]
        let store = await loadedStore(transport)

        store.set("timezone", "UTC")             // fails
        store.set("timezone", "Europe/Stockholm") // saved
        await store.settle()
        XCTAssertEqual(store.value("timezone"), .string("Europe/Stockholm"))
        XCTAssertEqual(transport.saved, [["timezone": "Europe/Stockholm"]])
    }

    @MainActor
    func testAFailedSaveOfANewKeyRemovesIt() async throws {
        let transport = FakeConfigTransport()
        transport.failing = [0]
        let store = await loadedStore(transport)
        store.set("browser.use_real_profile", true)
        XCTAssertEqual(store.value("browser.use_real_profile"), .bool(true))
        await store.settle()
        XCTAssertNil(store.value("browser.use_real_profile"))
    }

    @MainActor
    func testReasoningBlocksReadsAndWritesTheLocalKeyToo() async throws {
        let transport = FakeConfigTransport()
        transport.configValue = try json(#"{"display": {"show_reasoning": true, "platforms": {"cli": {"show_reasoning": "off"}}}}"#)
        let store = await loadedStore(transport)
        XCTAssertEqual(store.value("display.show_reasoning"), .bool(false), "the local key wins, read like _norm_bool")

        store.set("display.show_reasoning", true)
        await store.settle()
        XCTAssertEqual(transport.saved, [["display": ["show_reasoning": true, "platforms": ["cli": ["show_reasoning": true]]]]])
        XCTAssertEqual(store.value("display.show_reasoning"), .bool(true))
    }

    @MainActor
    func testClearingEveryToolsetAsksFirst() async throws {
        let transport = FakeConfigTransport()
        transport.configValue = try json(#"{"toolsets": ["web", "terminal"]}"#)
        let store = await loadedStore(transport)

        store.set("toolsets", .array([]))
        let confirmation = try XCTUnwrap(store.confirmation)
        XCTAssertEqual(store.value("toolsets"), .array(["web", "terminal"]), "nothing changes before the yes")
        await store.settle()
        XCTAssertTrue(transport.saved.isEmpty)

        store.confirm(confirmation)
        await store.settle()
        XCTAssertEqual(transport.saved, [["toolsets": []]])
        XCTAssertFalse(SettingsStore.clearsToolsets(from: nil, to: .array([])), "a missing list isn't a clear")
    }

    @MainActor
    func testStrippedVoiceKeysAreNeverWritten() async throws {
        let transport = FakeConfigTransport()
        let store = await loadedStore(transport)
        store.set([SettingsStore.Entry(key: "tts.provider", value: "edge"), SettingsStore.Entry(key: "voice.auto_tts", value: true)])
        await store.settle()
        XCTAssertTrue(transport.saved.isEmpty)
        XCTAssertNil(store.value("tts.provider"))
    }

    @MainActor
    func testRestartRequiredFieldsAreFlaggedOnceSaved() async throws {
        let transport = FakeConfigTransport()
        transport.schemaValue = try json(#"{"fields": {"runtime.limit": {"type": "number", "restart_required": true}, "agent.max_turns": {"type": "number"}}}"#)
        transport.configValue = try json(#"{"runtime": {"limit": 1}, "agent": {"max_turns": 1}}"#)
        let store = await loadedStore(transport)
        store.set("runtime.limit", 2)
        store.set("agent.max_turns", 2)
        await store.settle()
        XCTAssertEqual(store.restartPending, ["runtime.limit"])
    }

    @MainActor
    func testSectionFieldsComeFromTheSchemaOrTheConfigAndHonorVisibility() async throws {
        let transport = FakeConfigTransport()
        transport.schemaValue = try json(#"{"fields": {"terminal.backend": {"type": "select", "options": ["local", "docker"]}, "terminal.timeout": {"type": "number"}}}"#)
        transport.configValue = try json(#"{"terminal": {"backend": "docker", "docker_image": "python:3", "modal_image": "x", "timeout": 60}, "agent": {"max_turns": 9}}"#)
        let store = await loadedStore(transport)
        let advanced = try XCTUnwrap(SettingsCatalog.section(.advanced))
        let terminal = try XCTUnwrap(advanced.subpages.first { $0.id == "terminal" })
        XCTAssertEqual(store.fields(in: advanced, subpage: terminal).map(\.key), ["terminal.backend", "terminal.timeout", "terminal.docker_image"])
        let runtime = try XCTUnwrap(advanced.subpages.first { $0.id == "runtime" })
        XCTAssertEqual(store.fields(in: advanced, subpage: runtime).map(\.key), ["agent.max_turns"], "inferred from the config value")
        let entry = try XCTUnwrap(store.searchEntries().first { $0.id == "config-field:terminal.timeout" })
        XCTAssertEqual(entry.label, "Command Timeout")
        XCTAssertEqual(entry.context, "Advanced · Terminal backend")
        XCTAssertEqual(entry.target, SettingsTarget(page: .advanced, subpage: "terminal", anchor: "terminal.timeout"))
    }

    // MARK: Catalog

    func testEverySectionKeyHasAPageAndNoStrippedKeys() {
        for section in SettingsCatalog.sections {
            for key in section.keys {
                XCTAssertNotNil(section.subpage(for: key), "\(key) has no subpage on \(section.title)")
                XCTAssertFalse(SettingsCatalog.isStripped(key), key)
            }
        }
        XCTAssertTrue(SettingsCatalog.isStripped("voice.auto_tts"))
        XCTAssertTrue(SettingsCatalog.isStripped("stt.provider"))
        XCTAssertTrue(SettingsCatalog.isStripped("desktop.repo_scan_enabled"))
        XCTAssertFalse(SettingsCatalog.isStripped("model"))
        XCTAssertFalse(SettingsPageID.allCases.map(\.title).contains("Voice"))
        XCTAssertEqual(Set(SettingsPageID.groups.flatMap { $0 }), Set(SettingsPageID.allCases), "every page is in the navigation")
    }

    func testSubpagesFollowTheDesktopRouting() throws {
        let model = try XCTUnwrap(SettingsCatalog.section(.model))
        XCTAssertEqual(model.subpage(for: "fallback_providers")?.id, "fallbacks")
        XCTAssertEqual(model.subpage(for: "delegation.max_iterations")?.id, "delegation")
        XCTAssertEqual(model.subpage(for: "model_context_length")?.id, "main")
        let memory = try XCTUnwrap(SettingsCatalog.section(.memory))
        XCTAssertEqual(memory.subpage(for: "auxiliary.compression.timeout")?.id, "context")
        XCTAssertEqual(SettingsCatalog.subpages(.appearance).map(\.id), ["theme", "chat-display"])
        XCTAssertTrue(SettingsCatalog.subpages(.notifications).isEmpty, "alerts only, no sounds page")
    }

    func testBackendImageFieldsShowOnlyForTheirBackend() throws {
        let config = try json(#"{"terminal": {"backend": "modal"}}"#)
        XCTAssertTrue(SettingsCatalog.isVisible("terminal.modal_image", config: config))
        XCTAssertFalse(SettingsCatalog.isVisible("terminal.docker_image", config: config))
        XCTAssertFalse(SettingsCatalog.isVisible("terminal.docker_image", config: .object([:])), "local by default")
        XCTAssertFalse(SettingsCatalog.isVisible("delegation.provider", config: config), "edited with delegation.model")
        XCTAssertTrue(SettingsCatalog.isExternalMemoryProvider(.string("honcho")))
        XCTAssertFalse(SettingsCatalog.isExternalMemoryProvider(.string(" Built-in ")))
        XCTAssertFalse(SettingsCatalog.isExternalMemoryProvider(.string("")))
    }

    func testDescriptionsThatOnlyRepeatTheLabelAreHidden() {
        XCTAssertNil(SettingsCatalog.description(for: "agent.api_max_retries", schema: .init(kind: .number, description: "Agent → Api Max Retries")))
        XCTAssertEqual(SettingsCatalog.description(for: "terminal.cwd", schema: nil), SettingsCatalog.descriptions["terminal.cwd"])
        XCTAssertEqual(SettingsCatalog.label(for: "terminal.some_new_flag"), "Some New Flag")
    }

    // MARK: Search

    private func entry(_ label: String, context: String = "Chat", keywords: [String] = []) -> SettingsSearchEntry {
        SettingsSearchEntry(id: label, label: label, context: context, icon: "gear", keywords: keywords,
                            target: SettingsTarget(page: .chat))
    }

    func testSearchRanksLabelMatchesFirstAndNeedsEveryTerm() {
        let entries = [
            entry("Compression Target", context: "Memory & Context"),
            entry("Timezone", context: "Chat"),
            entry("Auto-Compression", context: "Memory & Context"),
            entry("Compression", context: "Model · Auxiliary"),
            entry("Persistent Memory", context: "Memory & Context", keywords: ["durable"]),
        ]
        XCTAssertEqual(SettingsSearch.filter(entries, query: "compression").map(\.label),
                       ["Compression", "Compression Target", "Auto-Compression"])
        XCTAssertEqual(SettingsSearch.filter(entries, query: "memory").map(\.label),
                       ["Persistent Memory", "Compression Target", "Auto-Compression"])
        XCTAssertEqual(SettingsSearch.filter(entries, query: "DURABLE memory").map(\.label), ["Persistent Memory"])
        XCTAssertTrue(SettingsSearch.filter(entries, query: "timezone memory").isEmpty)
        XCTAssertTrue(SettingsSearch.filter(entries, query: "  ").isEmpty)
    }

    func testManifestAndCredentialEntriesPointAtTheirRows() {
        let theme = SettingsManifest.entries.first { $0.id == "setting:appearance.theme" }
        XCTAssertEqual(theme?.target, SettingsTarget(page: .appearance, subpage: "theme", anchor: "appearance.theme"))
        XCTAssertEqual(theme?.context, "Appearance · Theme")
        XCTAssertEqual(SettingsSearch.filter(SettingsManifest.entries, query: "tailscale").first?.target.page, .connection)

        var catalog = EnvCatalog()
        catalog.vars["FIRECRAWL_API_KEY"] = EnvVar(key: "FIRECRAWL_API_KEY", category: "tool", isPassword: true)
        catalog.vars["GATEWAY_PROXY"] = EnvVar(key: "GATEWAY_PROXY", category: "messaging")
        var telegram = EnvVar(key: "TELEGRAM_BOT_TOKEN", category: "messaging")
        telegram.channelManaged = true
        catalog.vars["TELEGRAM_BOT_TOKEN"] = telegram
        catalog.vars["OPENROUTER_API_KEY"] = EnvVar(key: "OPENROUTER_API_KEY", category: "provider")
        let entries = SettingsSearch.credentialEntries(catalog)
        XCTAssertEqual(entries.map(\.id), ["credential:FIRECRAWL_API_KEY", "credential:GATEWAY_PROXY"])
        XCTAssertEqual(entries.first?.target, SettingsTarget(page: .apiKeys, subpage: "tools", anchor: "FIRECRAWL_API_KEY"))
        XCTAssertEqual(entries.first?.label, "FIRECRAWL")
        XCTAssertEqual(entries.last?.target.subpage, "settings")
    }

    // MARK: Pages

    func testMainModelDefaultsReadHandWrittenValues() {
        XCTAssertEqual(MainModelSection.effort(.bool(false)), "none")
        XCTAssertEqual(MainModelSection.effort(.string("Disabled")), "none")
        XCTAssertEqual(MainModelSection.effort(nil), "medium")
        XCTAssertEqual(MainModelSection.effort(.string("high")), "high")
        XCTAssertTrue(MainModelSection.fastOn(.string("priority")))
        XCTAssertFalse(MainModelSection.fastOn(.string("auto")))
    }

    func testModelAssignmentBodies() {
        let main = ConfigAPI.ModelAssignment(scope: .main, provider: "custom:lab", model: "m", baseURL: "http://lab:8000/v1")
        XCTAssertEqual(main.body, ["scope": "main", "provider": "custom:lab", "model": "m", "base_url": "http://lab:8000/v1"])
        let inherit = ConfigAPI.ModelAssignment(scope: .auxiliary, provider: "auto", model: "", task: "vision", reasoningEffort: .null)
        XCTAssertEqual(inherit.body, ["scope": "auxiliary", "provider": "auto", "model": "", "task": "vision", "reasoning_effort": .null])
        let confirm = ConfigAPI.ModelAssignmentResult(["ok": false, "confirm_required": true, "confirm_message": "Pricey."])
        XCTAssertEqual(confirm.confirmMessage, "Pricey.")
        XCTAssertFalse(confirm.ok)
    }

    func testFallbackEntriesKeepRoutingAndReadLegacyStrings() {
        let rows = FallbackModelsEditor.entries(.array([
            ["provider": "openrouter", "model": "a", "base_url": "http://x"],
            "anthropic/claude",
            "bare",
        ]))
        XCTAssertEqual(rows[0]["base_url"], .string("http://x"))
        XCTAssertEqual(MoaSection.route(rows[1]), ModelRoute(provider: "anthropic", model: "claude"))
        XCTAssertEqual(MoaSection.route(rows[2]), ModelRoute(provider: "", model: "bare"))
    }

    func testMemoryProviderSendsOnlyChangesAndTypedSecrets() throws {
        let provider = ConfigAPI.MemoryProvider(try json("""
        {"name": "honcho", "label": "Honcho", "fields": [
          {"key": "apiKey", "kind": "secret", "value": "", "is_set": true},
          {"key": "workspace", "kind": "text", "value": "hermes"},
          {"key": "recall", "kind": "bool", "value": true},
          {"key": "mode", "kind": "select", "value": "hybrid", "options": [{"value": "hybrid", "label": "Hybrid"}]},
          {"kind": "text"}
        ]}
        """))
        XCTAssertEqual(provider.fields.map(\.key), ["apiKey", "workspace", "recall", "mode"])
        XCTAssertEqual(provider.fields[2].value, "true")
        XCTAssertEqual(provider.fields[3].options, [.init(value: "hybrid", label: "Hybrid")])
        let changes = MemoryProviderPanel.changes(provider.fields, drafts: ["apiKey": "  ", "workspace": "hermes", "recall": "false"])
        XCTAssertEqual(changes, ["recall": "false"])
        XCTAssertEqual(MemoryProviderPanel.changes(provider.fields, drafts: ["apiKey": "sk-new"]), ["apiKey": "sk-new"])
    }

    func testVaultDraftChecksAndPayloads() {
        var draft = VaultAddForm.Draft()
        draft.label = "Mail"
        draft.origin = "mail.example.com"
        XCTAssertNotNil(draft.problem, "an origin needs its scheme")
        draft.origin = "https://mail.example.com"
        XCTAssertEqual(draft.problem, "A login needs an identifier and a password.")
        draft.identifier = " me@example.com "
        draft.password = "pw"
        XCTAssertNil(draft.problem)
        XCTAssertEqual(draft.secret, ["identifier_type": "email", "identifier": "me@example.com", "password": "pw"])

        draft.kind = "address"
        draft.line1 = "1 Main St"
        draft.state = "  "
        XCTAssertNil(draft.secret["state"])
        XCTAssertEqual(draft.secret["address_line1"], "1 Main St")

        draft.kind = "payment"
        draft.cardNumber = "4242 4242 4242 4242"
        XCTAssertEqual(draft.secret["card_number"], "4242424242424242")
    }

    func testDefaultProjectFolderIsScopedToDashboardAndProfile() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SettingsTests.\(UUID().uuidString)"))
        let home = try XCTUnwrap(URL(string: "https://hermes.example.ts.net"))
        let other = try XCTUnwrap(URL(string: "https://other.example.ts.net"))
        DefaultProjectFolder.set(" /srv/app ", base: home, profile: nil, defaults: defaults)
        XCTAssertEqual(DefaultProjectFolder.dir(base: home, profile: nil, defaults: defaults), "/srv/app")
        XCTAssertEqual(DefaultProjectFolder.dir(base: home, profile: "default", defaults: defaults), "/srv/app")
        XCTAssertNil(DefaultProjectFolder.dir(base: home, profile: "work", defaults: defaults))
        XCTAssertNil(DefaultProjectFolder.dir(base: other, profile: nil, defaults: defaults))
        DefaultProjectFolder.set("  ", base: home, profile: nil, defaults: defaults)
        XCTAssertNil(DefaultProjectFolder.dir(base: home, profile: nil, defaults: defaults))
    }

    func testStatusAndModelInfoDecoding() throws {
        let status = ConfigAPI.Status(try json(#"{"version": "0.9.1", "release_date": "2026-10-01", "config_version": 41, "latest_config_version": 42, "gateway_running": true, "gateway_state": "running", "active_sessions": 2}"#))
        XCTAssertEqual(status.version, "0.9.1")
        XCTAssertEqual(status.configVersion, 41)
        XCTAssertEqual(status.latestConfigVersion, 42)
        XCTAssertTrue(status.gatewayRunning)
        XCTAssertEqual(status.activeSessions, 2)
        let info = ConfigAPI.ModelInfo(try json(#"{"model": "m", "provider": "p", "auto_context_length": 200000, "config_context_length": 0}"#))
        XCTAssertEqual(MainModelSection.contextNote(info), "Detected: \(200000.formatted()) tokens.")
        XCTAssertNil(MainModelSection.contextNote(ConfigAPI.ModelInfo(.object([:]))))
    }
}
