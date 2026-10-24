"""Tests for gen_swift_gateway.py: `python3 -m unittest HermesVoice/tools/test_gen_swift_gateway.py`.

The Swift runtime test compiles a small fixture contract with the Support files and runs it on macOS;
it is skipped where `xcrun swiftc` isn't available.
"""

from __future__ import annotations

import contextlib
import copy
import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
APP_DIR = TOOLS.parent
SUPPORT = APP_DIR / "HermesVoice" / "Gateway" / "Support"

_spec = importlib.util.spec_from_file_location("gen_swift_gateway", TOOLS / "gen_swift_gateway.py")
gen = importlib.util.module_from_spec(_spec)
sys.modules["gen_swift_gateway"] = gen
_spec.loader.exec_module(gen)


def ref(name: str) -> dict:
    return {"$ref": f"#/components/schemas/{name}"}


def nullable(schema: dict) -> dict:
    return {"anyOf": [schema, {"type": "null"}], "default": None}


def method(name: str, params: str, result: str) -> dict:
    return {"name": name, "summary": f"{name} summary.", "params": [{"name": "params", "schema": ref(params)}],
            "result": {"name": "result", "schema": ref(result)}}


def event(name: str, payload: str | None) -> dict:
    schema = ref(payload) if payload else {"type": "object", "additionalProperties": False}
    return {"name": name, "summary": f"{name} summary.", "params": [{"name": "payload", "schema": schema}]}


def obj(properties: dict, required=(), extra=False, description=None) -> dict:
    schema = {"additionalProperties": extra, "properties": properties, "required": list(required), "type": "object"}
    if description:
        schema["description"] = description
    return schema


WAIT_BARRIER = {
    "discriminator": {
        "mapping": {"pid": "#/components/schemas/WaitBarrierTarget",
                    "session": "#/components/schemas/WaitBarrierTarget",
                    "until": "#/components/schemas/WaitBarrierUntil"},
        "propertyName": "type",
    },
    "oneOf": [ref("WaitBarrierUntil"), ref("WaitBarrierTarget")],
}
ANSWERS = nullable({"additionalProperties": nullable({"type": "string"}), "type": "object"})

FIXTURE = {
    "openrpc": "1.3.2",
    "info": {"title": "fixture", "version": "1"},
    "methods": [
        method("demo.echo", "EchoParams", "EchoResult"),
        method("demo.ping", "EmptyParams", "Shared"),
        method("voice.toggle", "VoiceParams", "Shared"),
        method("wake.start", "WakeOnly", "WakeOnly"),
    ],
    "x-server-requests": [method("clarify", "ClarifyRequestParams", "ClarifyResult")],
    "x-notifications": [
        event("goal.update", "GoalPayload"),
        event("message.start", None),
        event("voice.status", "VoiceStatusPayload"),
        event("wake.detected", "WakePayload"),
        event("wake.state", "GoalPayload"),
    ],
    "components": {"schemas": {
        "EchoParams": obj({
            "session_id": {"type": "string"},
            "note": nullable({"type": "string"}),
            "repeat": nullable({"anyOf": [{"type": "integer"}, {"type": "string"}]}),
            "default": {"default": "", "type": "string"},
            "stamp": {"anyOf": [{"type": "number"}, {"type": "integer"}]},
            "mode": nullable(ref("Mode")),
            "wait_barrier": nullable(WAIT_BARRIER),
            "_lineage_ids": {"items": {"type": "string"}, "type": "array"},
            "as": nullable({"type": "string"}),
        }, required=["session_id"], description="Echo ``params`` back."),
        "EchoResult": obj({
            "ok": {"type": "boolean"},
            "detail": nullable({"type": "string"}),
            "payload": {},
            "shared": nullable(ref("Shared")),
        }, required=["ok", "detail"], extra=True),
        "EmptyParams": obj({}),
        "Mode": {"enum": ["fast", "deny-all", "unknown", "continue", "NOT_OWNER", "as"], "type": "string"},
        "WaitBarrierTarget": obj({
            "type": {"enum": ["session", "pid"], "type": "string"},
            "target": {"anyOf": [{"type": "string"}, {"type": "integer"}]},
            "reason": {"default": "", "type": "string"},
        }, required=["type", "target"]),
        "WaitBarrierUntil": obj({"type": {"const": "until", "type": "string"}, "until_at": {"type": "number"}},
                                required=["type", "until_at"]),
        "ClarifyRequestParams": obj({"session_id": {"type": "string"},
                                     "questions": {"items": {"type": "string"}, "type": "array"},
                                     "answers": ANSWERS}, required=["session_id", "questions"]),
        "ClarifyResult": obj({"answers": ANSWERS}),
        "GoalPayload": obj({"goal_id": {"type": "string"}}, required=["goal_id"]),
        "Shared": obj({"value": {"type": "string"}}),
        "VoiceParams": obj({"enabled": {"type": "boolean"}, "detail": nullable(ref("VoiceDetail"))}),
        "VoiceDetail": obj({"level": {"type": "number"}}),
        "VoiceStatusPayload": obj({"state": {"type": "string"}}),
        "WakePayload": obj({"phrase": {"type": "string"}}),
        "WakeOnly": obj({"x": {"type": "integer"}}),
        "Orphan": obj({"y": {"type": "integer"}}),
    }},
}


def render(contract: dict = FIXTURE) -> tuple[dict[str, str], "gen.Renderer"]:
    return gen.render_contract(copy.deepcopy(contract))


def all_text(files: dict[str, str]) -> str:
    return "\n".join(files.values())


class NamingTests(unittest.TestCase):
    def test_lower_camel(self):
        cases = {"session_id": "sessionId", "deny-all": "denyAll", "NOT_OWNER": "notOwner",
                 "_lineage_ids": "lineageIds", "cancelToken": "cancelToken", "session.events.since":
                 "sessionEventsSince", "vault.save_login": "vaultSaveLogin", "1h": "_1h"}
        for wire, swift in cases.items():
            self.assertEqual(gen.lower_camel(wire), swift, wire)

    def test_reserved_words_are_escaped(self):
        self.assertEqual(gen.ident("repeat"), "`repeat`")
        self.assertEqual(gen.ident("default"), "`default`")
        self.assertEqual(gen.ident("as"), "`as`")
        self.assertEqual(gen.ident("sessionId"), "sessionId")
        self.assertEqual(gen.unique("self", set()), "self_")
        taken = {"value"}
        self.assertEqual(gen.unique("value", taken), "value2")


class FixtureRenderTests(unittest.TestCase):
    def setUp(self):
        self.files, self.renderer = render()
        self.text = all_text(self.files)

    def test_file_split(self):
        self.assertEqual(sorted(self.files), [
            "Events.swift", "Methods.swift", "Models.swift", "ModelsA-C.swift", "ModelsD-O.swift",
            "ModelsP-R.swift", "ModelsS-Z.swift", "ServerRequests.swift"])

    def test_nil_members_are_omitted(self):
        self.assertIn("var note: String?\n", self.text)
        # EchoParams uses the synthesized encoder, which writes optionals with encodeIfPresent.
        self.assertNotIn("extension EchoParams", self.text)
        # Custom encoders omit optional members too, but write a required nullable member as null.
        self.assertIn("try container.encodeIfPresent(self.shared, forKey: .shared)", self.text)
        self.assertIn("try container.encode(self.detail, forKey: .detail)", self.text)
        self.assertIn("self.detail = try container.decodeIfPresent(String.self, forKey: .detail)", self.text)

    def test_reserved_words_and_wire_names(self):
        self.assertIn("var `repeat`: IntOrString?", self.text)
        self.assertIn("var `default`: String?", self.text)
        self.assertIn("case `repeat`\n", self.text)
        self.assertIn('case lineageIds = "_lineage_ids"', self.text)
        self.assertIn('case sessionId = "session_id"', self.text)
        self.assertIn("case `continue`\n", self.text)
        self.assertIn("var `as`: String?", self.text)
        self.assertIn("case `as`\n", self.text)
        self.assertIn('case "as": self = .`as`', self.text)

    def test_discriminator_cases_named_from_tags(self):
        models = self.files["Models.swift"]
        self.assertIn("enum WaitBarrier: Codable, Hashable, Sendable {", models)
        self.assertIn("    case pid(WaitBarrierTarget)\n    case session(WaitBarrierTarget)\n"
                      "    case until(WaitBarrierUntil)\n", models)
        self.assertIn('case "pid"?: self = .pid(try WaitBarrierTarget(from: decoder))', models)
        self.assertIn('try JSONValue.encode(value).setting("type", "pid").encode(to: encoder)', models)
        self.assertIn("case unknown(JSONValue)", models)
        self.assertIn("var waitBarrier: WaitBarrier?", self.text)
        # A const discriminator gets its value as the default.
        self.assertIn('var type: String = "until"', self.text)

    def test_union_name_qualified_by_first_user(self):
        contract = copy.deepcopy(FIXTURE)
        schemas = contract["components"]["schemas"]
        schemas["AccountOwner"] = obj({"type": {"const": "account", "type": "string"}}, required=["type"])
        schemas["SessionOwner"] = obj({"type": {"const": "session", "type": "string"}}, required=["type"])
        schemas["ConnectionOperationParams"] = obj({"owner": {
            "discriminator": {"mapping": {"account": "#/components/schemas/AccountOwner",
                                          "session": "#/components/schemas/SessionOwner"}, "propertyName": "type"},
            "oneOf": [ref("SessionOwner"), ref("AccountOwner")]}}, required=["owner"])
        contract["methods"].append(method("connection.operation", "ConnectionOperationParams", "Shared"))
        files, _ = render(contract)
        self.assertIn("var owner: ConnectionOwner\n", all_text(files))
        self.assertIn("case account(AccountOwner)\n    case session(SessionOwner)\n", files["Models.swift"])

    def test_extras_round_trip_code(self):
        self.assertIn("    /// Members outside the contract, kept as sent.\n"
                      "    var extras: [String: JSONValue] = [:]\n", self.text)
        self.assertIn("enum CodingKeys: String, CodingKey, CaseIterable {", self.text)
        self.assertIn("self.extras = try decoder.extraValues(excluding: Set(CodingKeys.allCases.map(\\.stringValue)))",
                      self.text)
        self.assertIn("try encoder.encodeExtras(self.extras, excluding: Set(CodingKeys.allCases.map(\\.stringValue)))",
                      self.text)

    def test_schema_valued_map_keeps_nulls(self):
        self.assertIn("struct ClarifyResult: Codable, Hashable, Sendable {\n    var answers: [String: String?]?\n}",
                      self.text)

    def test_string_enum_unknown_fallback(self):
        self.assertIn("enum Mode: Codable, Hashable, Sendable, CaseIterable, RawRepresentable {", self.text)
        self.assertIn("    case unknown(String)\n", self.text)
        self.assertIn('static let allCases: [Mode] = [.fast, .denyAll, .unknown("unknown"), .`continue`, .notOwner, .`as`]',
                      self.text)
        self.assertIn('case "deny-all": self = .denyAll', self.text)
        self.assertIn("default: self = .unknown(rawValue)", self.text)
        self.assertNotIn("    case unknown\n", self.text)

    def test_multi_type_any_of(self):
        self.assertIn("var stamp: IntOrDouble?", self.text)
        models = self.files["Models.swift"]
        self.assertLess(models.index("try? container.decode(Int.self)", models.index("enum IntOrDouble")),
                        models.index("try? container.decode(Double.self)", models.index("enum IntOrDouble")))
        self.assertIn("var target: IntOrString\n", self.text)

    def test_opaque_and_number_types(self):
        self.assertIn("var payload: JSONValue?", self.text)
        self.assertIn("var untilAt: Double\n", self.text)

    def test_strip_list(self):
        c = self.renderer.contract
        self.assertEqual([m.name for m in c.stripped_methods], ["voice.toggle", "wake.start"])
        self.assertEqual([e.name for e in c.stripped_events], ["voice.status", "wake.detected"])
        self.assertEqual(c.stripped_schemas, ["VoiceDetail", "VoiceParams", "VoiceStatusPayload", "WakeOnly",
                                              "WakePayload"])
        self.assertIn("struct Shared:", self.text)  # also used by a kept method
        self.assertIn("struct Orphan:", self.text)  # unreachable, but not from a stripped root
        self.assertNotIn("voiceToggle", self.files["Methods.swift"])
        self.assertNotIn("wakeStart", self.files["Methods.swift"])
        self.assertNotIn("voiceStatus", self.files["Events.swift"])
        self.assertNotIn("wakeDetected", self.files["Events.swift"])
        self.assertIn("case wakeState(GoalPayload)", self.files["Events.swift"])

    def test_orphan_keeps_what_it_references(self):
        contract = copy.deepcopy(FIXTURE)
        contract["components"]["schemas"]["Orphan"]["properties"]["d"] = nullable(ref("VoiceDetail"))
        files, renderer = render(contract)
        self.assertEqual(renderer.contract.stripped_schemas, ["VoiceParams", "VoiceStatusPayload", "WakeOnly",
                                                              "WakePayload"])
        self.assertIn("var d: VoiceDetail?", all_text(files))
        self.assertIn("struct VoiceDetail:", all_text(files))

    def test_methods_events_and_requests(self):
        methods = self.files["Methods.swift"]
        self.assertIn("func demoEcho(_ params: EchoParams, timeout: TimeInterval? = nil) async throws -> EchoResult {",
                      methods)
        self.assertIn("func demoPing(_ params: EmptyParams = .init(), timeout: TimeInterval? = nil)", methods)
        events = self.files["Events.swift"]
        self.assertIn("    case messageStart\n", events)
        self.assertIn('case "goal.update": return typed(type, payload, GatewayEvent.goalUpdate)', events)
        self.assertIn("case unknown(type: String, payload: JSONValue?)", events)
        requests = self.files["ServerRequests.swift"]
        self.assertIn("case clarify(id: String, params: ClarifyRequestParams)", requests)
        self.assertIn("case let .clarify(_, params): return nonEmpty(params.sessionId)", requests)

    def test_unsupported_construct_raises(self):
        contract = copy.deepcopy(FIXTURE)
        contract["components"]["schemas"]["Shared"]["properties"]["bad"] = {"allOf": [{"type": "string"}]}
        with self.assertRaises(gen.UnsupportedSchema):
            render(contract)

    def test_reserved_type_names_are_prefixed(self):
        contract = copy.deepcopy(FIXTURE)
        contract["components"]["schemas"]["Result"] = obj({"z": {"type": "string"}})
        contract["components"]["schemas"]["Shared"]["properties"]["result"] = ref("Result")
        files, _ = render(contract)
        self.assertIn("struct GatewayResult:", all_text(files))
        self.assertIn("var result: GatewayResult?", all_text(files))

    def test_deterministic(self):
        self.assertEqual(render()[0], self.files)


class CLITests(unittest.TestCase):
    def test_check_detects_stale_and_extra_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            contract, out = Path(tmp) / "contract.json", Path(tmp) / "Generated"
            contract.write_text(json.dumps(FIXTURE), encoding="utf-8")
            args = ["--contract", str(contract), "--out", str(out)]
            with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(gen.main(["--check", *args]), 1)
                self.assertEqual(gen.main(args), 0)
                self.assertEqual(gen.main(["--check", *args]), 0)
                (out / "Models.swift").write_text("// edited\n", encoding="utf-8")
                self.assertEqual(gen.main(["--check", *args]), 1)
                gen.main(args)
                (out / "Leftover.swift").write_text("", encoding="utf-8")
                self.assertEqual(gen.main(["--check", *args]), 1)
                gen.main(args)
            self.assertFalse((out / "Leftover.swift").exists())


class PinnedContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.files, cls.renderer = gen.render_contract(json.loads(gen.CONTRACT.read_text(encoding="utf-8")))
        cls.text = all_text(cls.files)

    def test_committed_output_is_current(self):
        with contextlib.redirect_stderr(io.StringIO()) as err:
            self.assertEqual(gen.main(["--check"]), 0, err.getvalue())

    def test_strip_list(self):
        c = self.renderer.contract
        self.assertTrue(c.stripped_methods)
        self.assertTrue(all(m.name.startswith(("voice.", "wake.")) for m in c.stripped_methods))
        self.assertFalse(any(m.name.startswith(("voice.", "wake.")) for m in c.methods))
        self.assertFalse(any(e.name.startswith("voice.") or e.name == "wake.detected" for e in c.events))

    def test_known_shapes(self):
        models = self.files["Models.swift"]
        self.assertIn("    case pid(WaitBarrierTarget)\n    case session(WaitBarrierTarget)\n", models)
        self.assertIn("var answers: [String: String?]?", self.text)
        self.assertIn("var `repeat`: IntOrString?", self.text)
        self.assertIn("func sessionResume(_ params: SessionResumeParams, timeout: TimeInterval? = nil) "
                      "async throws -> SessionResumeResult", self.files["Methods.swift"])


SWIFT_MAIN = textwrap.dedent(r"""
    import Foundation

    func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) {
        do {
            if try condition() { return }
            print("FAIL line \(line): \(message)")
        } catch {
            print("FAIL line \(line): \(message): \(error)")
        }
        exit(1)
    }

    func object(_ value: some Encodable) throws -> [String: JSONValue] {
        try JSONValue.encode(value).objectValue ?? [:]
    }

    func parse<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONValue(jsonData: Data(json.utf8)).decode(type)
    }

    final class FakeTransport: GatewayCalling {
        var sent: [(String, JSONValue)] = []
        var reply: JSONValue = [:]

        func call(_ method: String, params: JSONValue, timeout: TimeInterval?) async throws -> JSONValue {
            sent.append((method, params))
            return reply
        }
    }

    // Nil members are omitted; reserved words keep their wire names.
    check(try object(EchoParams(sessionId: "s1")) == ["session_id": "s1"], "nil members omitted")
    let params = EchoParams(sessionId: "s", repeat: .int(3), default: "d", stamp: .double(1.5), mode: .denyAll,
                            lineageIds: ["a"])
    check(try object(params) == ["session_id": "s", "repeat": 3, "default": "d", "stamp": 1.5, "mode": "deny-all",
                                 "_lineage_ids": ["a"]], "wire names")
    check(try object(EchoParams(sessionId: "s", as: "x")) == ["session_id": "s", "as": "x"], "keyword member")
    check(Mode(rawValue: "as") == .`as` && Mode.`as`.rawValue == "as", "keyword enum value")

    // Discriminator: two tags for one schema; the case decides the tag.
    let pid = try parse(WaitBarrier.self, #"{"type": "pid", "target": 42}"#)
    guard case let .pid(target) = pid else { check(false, "pid tag"); exit(1) }
    check(target.target == .int(42), "pid target")
    guard case .session = try parse(WaitBarrier.self, #"{"type": "session", "target": "abc"}"#) else {
        check(false, "session tag"); exit(1)
    }
    guard case .until = try parse(WaitBarrier.self, #"{"type": "until", "until_at": 5}"#) else {
        check(false, "until tag"); exit(1)
    }
    guard case let .unknown(raw) = try parse(WaitBarrier.self, #"{"type": "later", "x": 1}"#) else {
        check(false, "unknown tag"); exit(1)
    }
    check(raw["x"] == 1, "unknown tag keeps raw")
    let written = try object(WaitBarrier.pid(WaitBarrierTarget(type: .session, target: .string("t"))))
    check(written["type"] == "pid" && written["target"] == "t", "tag written from case")
    check(try object(WaitBarrierUntil(untilAt: 2)) == ["type": "until", "until_at": 2], "const default")

    // Extras round-trip; a required nullable member is written as null.
    let result = try parse(EchoResult.self, #"{"ok": true, "detail": null, "zeta": [1, 2], "nested": {"a": 1.5}}"#)
    check(result.ok && result.detail == nil, "typed members")
    check(result.extras == ["zeta": [1, 2], "nested": ["a": 1.5]], "extras decoded")
    check(try object(result) == ["ok": true, "detail": .null, "zeta": [1, 2], "nested": ["a": 1.5]], "extras encoded")

    // Map values keep explicit nulls.
    let answers = try object(ClarifyResult(answers: ["q1": "yes", "q2": nil]))
    check(answers == ["answers": ["q1": "yes", "q2": .null]], "explicit null answers")
    check(try object(ClarifyResult()) == [:], "cancel-all omits answers")

    // String enums keep unknown values.
    check(Mode(rawValue: "brand-new") == .unknown("brand-new"), "unknown enum value")
    check(try parse([Mode].self, #"["unknown", "continue", "NOT_OWNER"]"#) == [.unknown("unknown"), .continue, .notOwner],
          "enum decode")
    check(try JSONValue.encode([Mode.denyAll, .unknown("x")]) == ["deny-all", "x"], "enum encode")

    // Multi-type anyOf tries integers before fractions.
    check(try parse([IntOrDouble].self, "[3, 3.5]") == [.int(3), .double(3.5)], "int or double")

    // Events and server requests decode leniently.
    check(GatewayEvent.decode(type: "goal.update", payload: ["goal_id": "g"]) == .goalUpdate(GoalPayload(goalId: "g")),
          "typed event")
    check(GatewayEvent.decode(type: "goal.update", payload: ["goal_id": 5]) == .unknown(type: "goal.update",
          payload: ["goal_id": 5]), "mismatched event")
    check(GatewayEvent.decode(type: "voice.status", payload: nil).type == "voice.status", "stripped event")
    check(GatewayEvent.decode(type: "message.start", payload: nil) == .messageStart, "payload-less event")
    let request = ServerRequest.decode(id: "7", method: "clarify", params: ["session_id": "s", "questions": ["q"]])
    check(request.id == "7" && request.method == "clarify" && request.sessionID == "s", "server request")
    let bad = ServerRequest.decode(id: "8", method: "clarify", params: ["questions": "nope"])
    check(bad.id == "8" && bad.method == "clarify", "mismatched server request keeps id")
    if case .unknown = bad {} else { check(false, "mismatched server request is unknown") }
    check(ServerRequest.decode(id: "9", method: "clarify", params: ["session_id": "", "questions": []]).sessionID == nil,
          "empty session is nil")

    // Calls encode params and decode results; a mismatch throws with the raw result.
    let transport = FakeTransport()
    let client = GatewayClient(transport: transport)
    transport.reply = ["ok": false, "detail": "x"]
    let echoed = try await client.demoEcho(EchoParams(sessionId: "s"))
    check(echoed.detail == "x" && transport.sent[0].0 == "demo.echo" && transport.sent[0].1 == ["session_id": "s"],
          "call round trip")
    transport.reply = ["ok": "yes"]
    do {
        _ = try await client.demoEcho(EchoParams(sessionId: "s"))
        check(false, "decoding error expected")
    } catch let error as GatewayDecodingError {
        check(error.method == "demo.echo" && error.raw == ["ok": "yes"], "decoding error carries raw")
    }
    _ = try await client.demoPing()
    check(transport.sent.last!.1 == [:], "empty params")

    print("OK")
""")


@unittest.skipUnless(sys.platform == "darwin" and shutil.which("xcrun"), "needs the Swift toolchain (xcrun)")
class SwiftRuntimeTests(unittest.TestCase):
    def test_fixture_behaviour(self):
        files, _ = render()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sources = [str(p) for p in sorted(SUPPORT.glob("*.swift"))]
            for name, text in files.items():
                (root / name).write_text(text, encoding="utf-8")
                sources.append(str(root / name))
            (root / "main.swift").write_text(SWIFT_MAIN, encoding="utf-8")
            sources.append(str(root / "main.swift"))
            binary = root / "runner"
            build = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-o", str(binary), *sources],
                                   capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stderr[-4000:])
            run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
            self.assertEqual(run.stdout.strip().splitlines()[-1:], ["OK"], run.stdout + run.stderr)


if __name__ == "__main__":
    unittest.main()
