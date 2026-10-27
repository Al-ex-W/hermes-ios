"""The fake Hermes behind the settings screens (M3): config + schema, models, memory providers, .env keys, OAuth
providers, profiles and SOUL.md, status, the vault.* / billing.* RPCs and the plugin's alert pushes, checked
against the Hermes shapes and the pinned gateway contract."""

from __future__ import annotations

import asyncio
from typing import Any

import httpx
import pytest

from fakeclient import CONTRACT_PATH, Contract, Gateway, RpcFailure, serving, signed_in, until
from fake_hermes import CATEGORY_ORDER, DEFAULT_SOUL, FAKE_MEMORY_PROVIDER, REDACTED_WRITE_DETAIL
from fake_voice_plugin import PREFIX

CONTRACT = Contract(CONTRACT_PATH) if CONTRACT_PATH else None
VOIP, ALERT = "ab" * 32, "cd" * 32


def contract_problems(*gateways: Gateway) -> list[str]:
    return [p for g in gateways for p in CONTRACT.check_gateway(g)] if CONTRACT else []


async def failure(gateway: Gateway, method: str, params: dict) -> RpcFailure:
    with pytest.raises(RpcFailure) as caught:
        await gateway.call(method, params)
    return caught.value


async def put(http: httpx.AsyncClient, config: dict[str, Any], **query: str) -> httpx.Response:
    return await http.put("/api/config", params=query, json={"config": config})


def test_schema_and_config_come_from_the_defaults_and_each_profile_has_its_own():
    async def scenario():
        async with serving() as (fake, base):
            async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                anonymous_codes = [(await anonymous.get(path)).status_code for path in (
                    "/api/config", "/api/env", "/api/config/schema", "/api/config/defaults", "/api/model/info")]
            async with signed_in(base) as http:
                schema = (await http.get("/api/config/schema")).json()
                config = (await http.get("/api/config")).json()
                raw = (await http.get("/api/config", params={"include_defaults": "false"})).json()
                research = (await http.get("/api/config", params={"profile": "research"})).json()
                missing = await http.get("/api/config", params={"profile": "nobody"})
                invalid = await http.get("/api/config", params={"profile": "Not A Name"})
        return anonymous_codes, schema, config, raw, research, missing, invalid

    anonymous_codes, schema, config, raw, research, missing, invalid = asyncio.run(scenario())
    assert anonymous_codes == [401, 401, 200, 200, 200], "schema, defaults and model info are public paths"
    fields = schema["fields"]
    assert schema["category_order"] == CATEGORY_ORDER
    assert list(fields)[:2] == ["model", "model_context_length"], "the virtual field sits right after model"
    assert fields["terminal.backend"]["type"] == "select" and "docker" in fields["terminal.backend"]["options"]
    assert fields["approvals.mode"]["category"] == "security", "small categories fold into bigger tabs"
    assert fields["checkpoints.enabled"] == {"type": "boolean", "description": "Checkpoints → Enabled",
                                             "category": "agent"}
    assert fields["agent.max_turns"]["type"] == "string", "a null default infers string, as on the server"
    assert fields["memory.provider"]["options"] == ["", FAKE_MEMORY_PROVIDER]
    assert fields["timezone"]["clearable"] and "UTC" in fields["timezone"]["options"]
    assert {"tts.provider", "stt.provider", "voice.auto_tts", "wake_word.enabled"} <= set(fields), \
        "voice fields stay in the schema; the app strips them"
    assert "_config_version" not in fields and "moa.presets.default.aggregator.model" in fields
    assert config["model"] == "fake-hermes" and config["model_context_length"] == 0
    assert config["approvals"]["mode"] == "smart" and not any(k.startswith("_") for k in config)
    assert raw == {"model": "fake-hermes", "model_context_length": 0}
    assert research["model"] == "echo-1"
    assert (missing.status_code, missing.json()) == (404, {"detail": "Profile 'nobody' does not exist."})
    assert invalid.status_code == 400 and "is not a valid profile name" in invalid.json()["detail"]


def test_config_saves_deep_merge_round_trip_and_bad_values_are_refused():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                sparse = await put(http, {"approvals": {"timeout": 120}, "display": {"personality": "concise"}})
                after = (await http.get("/api/config")).json()
                raw = (await http.get("/api/config", params={"include_defaults": "false"})).json()
                round_trip = await put(http, after)
                same = (await http.get("/api/config")).json()
                context = await put(http, {"model_context_length": 64000})
                info = (await http.get("/api/model/info")).json()
                cleared = await put(http, {"model_context_length": 0})
                info_after = (await http.get("/api/model/info")).json()
                switched = await put(http, {"model": "echo-2-pro"})
                switched_info = (await http.get("/api/model/info")).json()
                engine = [await put(http, {"context": {"engine": value}}) for value in ("default", "compressor")]
                bad = {name: await put(http, body) for name, body in {
                    "string for a number": {"approvals": {"timeout": "soon"}},
                    "bool as number": {"tool_output": {"max_bytes": True}},
                    "scalar for a section": {"terminal": "docker"},
                    "unknown select choice": {"approvals": {"mode": "yolo"}},
                    "list field": {"command_allowlist": "ls"},
                }.items()}
                unknown_keys = await put(http, {"personalities": {"pirate": {"prompt": "Arr"}}, "agent": {
                    "max_turns": 90, "personalities": {"bard": "Sing"}}})
                missing = await http.put("/api/config", json={"profile": "research"})
                not_object = await http.put("/api/config", json={"config": ["x"]})
                scoped = await http.put("/api/config", json={"config": {"memory": {"memory_enabled": False}},
                                                             "profile": "research"})
                default_memory = (await http.get("/api/config")).json()["memory"]["memory_enabled"]
                research_memory = (await http.get("/api/config", params={"profile": "research"})).json()
                final = (await http.get("/api/config")).json()
        return (sparse, after, raw, round_trip, same, context, info, cleared, info_after, switched, switched_info,
                engine, bad, unknown_keys, missing, not_object, scoped, default_memory, research_memory, final)

    (sparse, after, raw, round_trip, same, context, info, cleared, info_after, switched, switched_info, engine, bad,
     unknown_keys, missing, not_object, scoped, default_memory, research_memory, final) = asyncio.run(scenario())
    assert sparse.json() == {"ok": True}
    assert after["approvals"]["timeout"] == 120 and after["approvals"]["mode"] == "smart", "siblings keep defaults"
    assert after["display"]["personality"] == "concise"
    assert raw == {"model": "fake-hermes", "model_context_length": 0, "approvals": {"timeout": 120},
                   "display": {"personality": "concise"}}, "defaults are not written into the file"
    assert round_trip.json() == {"ok": True} and same == after
    assert context.json() == {"ok": True}
    assert (info["config_context_length"], info["auto_context_length"], info["effective_context_length"]) == \
        (64000, 200_000, 64000)
    # Hermes deep-merges the PUT over the file, so the model block it rebuilt without context_length gets the old
    # override back: 0 does not clear it on the real server either (web_server_config.py + config_env.py).
    assert cleared.json() == {"ok": True} and info_after["config_context_length"] == 64000
    assert switched.json() == {"ok": True}
    assert (switched_info["model"], switched_info["provider"]) == ("echo-2-pro", "echo-cloud"), \
        "a model another provider serves switches the provider"
    assert [r.status_code for r in engine] == [200, 200], "the default and the desktop's extra choices pass"
    assert {name: r.status_code for name, r in bad.items()} == {name: 400 for name in bad}
    assert bad["string for a number"].json()["detail"] == \
        'Invalid value for approvals.timeout: expected a number, got "soon"'
    assert "is a section" in bad["scalar for a section"].json()["detail"]
    assert unknown_keys.status_code == 200, "keys outside the schema deep-merge like on the server"
    assert final["personalities"] == {"pirate": {"prompt": "Arr"}} and final["agent"]["max_turns"] == 90
    assert missing.status_code == 422 and missing.json()["detail"][0]["loc"] == ["body", "config"]
    assert not_object.status_code == 422
    assert scoped.json() == {"ok": True} and default_memory is True
    assert research_memory["memory"]["memory_enabled"] is False


def test_model_assignment_auxiliary_slots_and_moa():
    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                options = (await http.get("/api/model/options", params={"explicit_only": "1"})).json()
                research_options = (await http.get("/api/model/options", params={"profile": "research"})).json()
                main = (await http.post("/api/model/set", json={"scope": "main", "provider": "fake",
                                                                 "model": "fake-hermes-mini"})).json()
                info = (await http.get("/api/model/info")).json()
                pricey = (await http.post("/api/model/set", json={"scope": "main", "provider": "fake",
                                                                   "model": "fake-hermes-max"})).json()
                confirmed = (await http.post("/api/model/set", json={
                    "scope": "main", "provider": "fake", "model": "fake-hermes-max",
                    "confirm_expensive_model": True})).json()
                wrong = await http.post("/api/model/set", json={"scope": "main", "provider": "fake", "model": "echo-1"})
                bad_scope = await http.post("/api/model/set", json={"scope": "side", "provider": "x", "model": "y"})
                no_model = await http.post("/api/model/set", json={"scope": "main", "provider": "fake"})
                aux = (await http.post("/api/model/set", json={
                    "scope": "auxiliary", "task": "vision", "provider": "echo-cloud", "model": "echo-1",
                    "reasoning_effort": "low"})).json()
                stale = (await http.post("/api/model/set", json={"scope": "main", "provider": "fake",
                                                                  "model": "fake-hermes"})).json()
                slots = (await http.get("/api/model/auxiliary")).json()
                inherit = (await http.post("/api/model/set", json={
                    "scope": "auxiliary", "task": "vision", "provider": "echo-cloud", "model": "echo-1",
                    "reasoning_effort": None})).json()
                vision = next(t for t in (await http.get("/api/model/auxiliary")).json()["tasks"]
                              if t["task"] == "vision")
                bad_effort = await http.post("/api/model/set", json={"scope": "auxiliary", "task": "vision",
                                                                     "provider": "fake", "model": "x",
                                                                     "reasoning_effort": "extreme"})
                bad_task = await http.post("/api/model/set", json={"scope": "auxiliary", "task": "dreams",
                                                                   "provider": "fake", "model": "x"})
                reset = (await http.post("/api/model/set", json={"scope": "auxiliary", "task": "__reset__",
                                                                  "provider": "", "model": ""})).json()
                after_reset = (await http.get("/api/model/auxiliary")).json()["tasks"]
                moa = (await http.get("/api/model/moa")).json()
                saved = await http.put("/api/model/moa", json={"default_preset": "quick", "presets": {"quick": {
                    "reference_models": [{"provider": "fake", "model": "fake-hermes-mini"}],
                    "aggregator": {"provider": "fake", "model": "fake-hermes"}, "fanout": "every_n:3"}}})
                moa_after = (await http.get("/api/model/moa")).json()
                half = await http.put("/api/model/moa", json={"presets": {"quick": {
                    "reference_models": [{"provider": "fake"}], "aggregator": {"provider": "fake", "model": "x"}}}})
        return (options, research_options, main, info, pricey, confirmed, wrong, bad_scope, no_model, aux, stale,
                slots, inherit, vision, bad_effort, bad_task, reset, after_reset, moa, saved, moa_after, half)

    (options, research_options, main, info, pricey, confirmed, wrong, bad_scope, no_model, aux, stale, slots, inherit,
     vision, bad_effort, bad_task, reset, after_reset, moa, saved, moa_after, half) = asyncio.run(scenario())
    assert (options["model"], options["provider"]) == ("fake-hermes", "fake")
    assert [p["slug"] for p in options["providers"] if p["is_current"]] == ["fake"]
    assert research_options["provider"] == "echo-cloud"
    assert main == {"ok": True, "scope": "main", "provider": "fake", "model": "fake-hermes-mini", "base_url": "",
                    "gateway_tools": [], "stale_aux": []}
    assert info["model"] == "fake-hermes-mini" and info["capabilities"]["supports_vision"] is False
    assert pricey["ok"] is False and pricey["confirm_required"] and "fake-hermes-max" in pricey["confirm_message"]
    assert confirmed["ok"] and confirmed["model"] == "fake-hermes-max"
    assert wrong.status_code == 400 and "not available from fake" in wrong.json()["detail"]
    assert bad_scope.json() == {"detail": "scope must be 'main' or 'auxiliary'"}
    assert no_model.status_code == 422
    assert aux == {"ok": True, "scope": "auxiliary", "tasks": ["vision"], "provider": "echo-cloud",
                   "model": "echo-1", "reasoning_effort": "low"}
    assert stale["stale_aux"] == [{"task": "vision", "provider": "echo-cloud", "model": "echo-1"}]
    assert [t["task"] for t in slots["tasks"]][:3] == ["vision", "compression", "skills_hub"]
    assert slots["tasks"][0] == {"task": "vision", "provider": "echo-cloud", "model": "echo-1", "base_url": "",
                                 "reasoning_effort": "low", "local_endpoint": False}
    assert slots["main"] == {"provider": "fake", "model": "fake-hermes"}
    assert inherit["reasoning_effort"] is None and vision["reasoning_effort"] is None
    assert bad_effort.status_code == 400 and bad_task.json() == {"detail": "unknown auxiliary task: dreams"}
    assert reset == {"ok": True, "scope": "auxiliary", "reset": True}
    assert all(t["provider"] == "auto" and t["model"] == "" for t in after_reset)
    assert moa["default_preset"] == "default" and moa["aggregator"]["model"] == "anthropic/claude-opus-4.8"
    assert moa["reference_models"][0] == {"provider": "openai-codex", "model": "gpt-5.5", "enabled": True}
    assert saved.status_code == 200 and saved.json()["default_preset"] == "quick"
    assert list(moa_after["presets"]) == ["quick"], "the submitted preset map is authoritative"
    assert moa_after["fanout"] == "every_n:3" and moa_after["reference_models"][0]["model"] == "fake-hermes-mini"
    assert half.status_code == 422 and half.json()["detail"].startswith("Invalid MoA config: ")


def test_memory_provider_config_and_env_keys_never_echo_values(capsys):
    secret, tool_key = "fr-live-0123456789abcdef", "exa-0123456789abcdef"

    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                memory = (await http.get("/api/memory")).json()
                declared = (await http.get(f"/api/memory/providers/{FAKE_MEMORY_PROVIDER}/config",
                                           params={"surface": "declared"})).json()
                saved = await http.put(f"/api/memory/providers/{FAKE_MEMORY_PROVIDER}/config",
                                       params={"surface": "declared"},
                                       json={"values": {"api_key": secret, "region": "us", "top_k": "8",
                                                        "rerank": True}})
                after = (await http.get(f"/api/memory/providers/{FAKE_MEMORY_PROVIDER}/config",
                                        params={"surface": "declared"})).text
                provider = (await http.get("/api/config")).json()["memory"]["provider"]
                bad_choice = await http.put(f"/api/memory/providers/{FAKE_MEMORY_PROVIDER}/config",
                                            params={"surface": "declared"}, json={"values": {"region": "mars"}})
                builtin = (await http.get("/api/memory/providers/builtin/config",
                                          params={"surface": "declared"})).json()
                unknown = await http.put("/api/memory/providers/builtin/config", params={"surface": "declared"},
                                         json={"values": {}})
                traversal = await http.get("/api/memory/providers/..%2Fx/config")

                env = (await http.get("/api/env")).json()
                set_key = await http.put("/api/env", json={"key": "EXA_API_KEY", "value": tool_key})
                env_after = await http.get("/api/env")
                preview = env_after.json()["EXA_API_KEY"]["redacted_value"]
                write_back = await http.put("/api/env", json={"key": "EXA_API_KEY", "value": preview})
                legacy = await http.put("/api/env", json={"key": "EXA_API_KEY", "value": "exa-...cdef"})
                denied = await http.put("/api/env", json={"key": "PATH", "value": "/tmp"})
                bad_name = await http.put("/api/env", json={"key": "1BAD", "value": "x"})
                scoped = await http.put("/api/env", params={"profile": "research"},
                                        json={"key": "FAL_KEY", "value": "fal-research-key"})
                default_fal = (await http.get("/api/env")).json()["FAL_KEY"]["is_set"]
                research_fal = (await http.get("/api/env", params={"profile": "research"})).json()["FAL_KEY"]
                removed = await http.request("DELETE", "/api/env", json={"key": "EXA_API_KEY"})
                again = await http.request("DELETE", "/api/env", json={"key": "EXA_API_KEY"})
                reveals = [(await http.post("/api/env/reveal", json={"key": "MY_CUSTOM_TOKEN"})).status_code
                           for _ in range(6)]
                checks = [(await http.post("/api/providers/validate", json={"key": key, "value": value})).json()
                          for key, value in (("OPENROUTER_API_KEY", "bad-key-123456"),
                                             ("OPENROUTER_API_KEY", "or-offline-123456"),
                                             ("OPENROUTER_API_KEY", "or-good-123456"),
                                             ("EXA_API_KEY", "anything-at-all"), ("XAI_API_KEY", " "))]
        return (memory, declared, saved, after, provider, bad_choice, builtin, unknown, traversal, env, set_key,
                env_after, preview, write_back, legacy, denied, bad_name, scoped, default_fal, research_fal, removed,
                again, reveals, checks)

    (memory, declared, saved, after, provider, bad_choice, builtin, unknown, traversal, env, set_key, env_after,
     preview, write_back, legacy, denied, bad_name, scoped, default_fal, research_fal, removed, again, reveals,
     checks) = asyncio.run(scenario())
    logs = capsys.readouterr().out
    assert memory["active"] == "" and memory["providers"][0]["status"] == "needs_config"
    fields = {f["key"]: f for f in declared["fields"]}
    assert declared["label"] == "Fake Recall" and fields["api_key"]["options"] == []
    assert (fields["api_key"]["value"], fields["api_key"]["is_set"]) == ("", False)
    assert fields["region"]["value"] == "eu" and [o["value"] for o in fields["region"]["options"]] == ["eu", "us"]
    assert saved.json() == {"ok": True} and provider == FAKE_MEMORY_PROVIDER
    assert secret not in after and '"is_set":true' in after.replace(" ", "")
    assert '"value":"us"' in after.replace(" ", "") and '"value":"8"' in after.replace(" ", "")
    assert bad_choice.json() == {"detail": "Invalid value for 'region'"}
    assert builtin == {"name": "builtin", "label": "builtin", "docs_url": "", "fields": []}
    assert unknown.status_code == 404 and traversal.status_code == 404

    assert env["OPENROUTER_API_KEY"]["is_set"] and env["OPENROUTER_API_KEY"]["redacted_value"].startswith("«redacted:")
    assert env["OPENROUTER_API_KEY"]["provider"] == "openrouter" and env["OPENROUTER_API_KEY"]["provider_primary"]
    assert env["ECHO_CLOUD_API_KEY"]["category"] == "provider", "catalog-only provider keys are listed too"
    assert env["MY_CUSTOM_TOKEN"]["custom"] and env["MY_CUSTOM_TOKEN"]["category"] == "custom"
    assert env["TELEGRAM_BOT_TOKEN"]["channel_managed"] and env["EXA_API_KEY"]["tools"] == ["web_search", "web_extract"]
    assert set_key.json() == {"ok": True, "key": "EXA_API_KEY", "config_updates": []}
    assert tool_key not in env_after.text and preview == "«redacted:exa-...cdef»"
    assert write_back.json() == {"detail": REDACTED_WRITE_DETAIL} and legacy.status_code == 400
    assert denied.status_code == 400 and "denylist" in denied.json()["detail"]
    assert bad_name.json() == {"detail": "Invalid environment variable name: '1BAD'"}
    assert scoped.status_code == 200 and default_fal is False and research_fal["is_set"]
    assert removed.json()["found"] and again.status_code == 404
    assert reveals == [200] * 5 + [429]
    assert [(c["ok"], c["reachable"]) for c in checks] == [(False, True), (False, False), (True, True),
                                                            (True, False), (False, True)]
    assert all(value not in logs for value in (secret, tool_key, "fal-research-key")), "values never reach the log"


def test_oauth_device_code_sign_in_and_disconnect():
    async def scenario():
        async with serving(oauth_approve_after=0.2) as (fake, base):
            async with signed_in(base) as http:
                listed = (await http.get("/api/providers/oauth")).json()["providers"]
                started = (await http.post("/api/providers/oauth/nous/start")).json()
                sid = started["session_id"]
                pending = (await http.get(f"/api/providers/oauth/nous/poll/{sid}")).json()
                approved = (await http.get(f"/api/providers/oauth/nous/poll/{sid}", params={"wait": 5})).json()
                nous = next(p for p in (await http.get("/api/providers/oauth")).json()["providers"]
                            if p["id"] == "nous")
                denied_start = (await http.post("/api/providers/oauth/xai-oauth/start")).json()
                fake.oauth_sessions[denied_start["session_id"]]["user_code"] = "DENY-0000"
                denied = (await http.get(f"/api/providers/oauth/xai-oauth/poll/{denied_start['session_id']}",
                                         params={"wait": 5})).json()
                external = await http.post("/api/providers/oauth/anthropic/start")
                unknown = await http.post("/api/providers/oauth/nobody/start")
                mismatch = await http.get(f"/api/providers/oauth/openai-codex/poll/{sid}")
                lost = await http.get("/api/providers/oauth/nous/poll/nope")
                scoped = (await http.post("/api/providers/oauth/minimax-oauth/start",
                                          params={"profile": "research"})).json()
                wrong_profile = await http.get(f"/api/providers/oauth/minimax-oauth/poll/{scoped['session_id']}")
                cancelled = (await http.delete(f"/api/providers/oauth/sessions/{scoped['session_id']}",
                                               params={"profile": "research"})).json()
                gone = (await http.delete(f"/api/providers/oauth/sessions/{scoped['session_id']}")).json()
                submit = await http.post("/api/providers/oauth/nous/submit", json={"session_id": sid, "code": "x"})
                disconnected = (await http.delete("/api/providers/oauth/openai-codex")).json()
                twice = await http.delete("/api/providers/oauth/openai-codex")
                cli_managed = await http.delete("/api/providers/oauth/copilot-acp")
        return (listed, started, pending, approved, nous, denied, external, unknown, mismatch, lost, scoped,
                wrong_profile, cancelled, gone, submit, disconnected, twice, cli_managed)

    (listed, started, pending, approved, nous, denied, external, unknown, mismatch, lost, scoped, wrong_profile,
     cancelled, gone, submit, disconnected, twice, cli_managed) = asyncio.run(scenario())
    by_id = {p["id"]: p for p in listed}
    assert list(by_id)[:2] == ["nous", "openai-codex"]
    assert by_id["openai-codex"]["status"]["logged_in"] and by_id["openai-codex"]["disconnectable"]
    assert by_id["nous"]["status"] == {"logged_in": False}
    assert by_id["copilot-acp"]["disconnect_hint"] == "Managed by that provider's CLI; remove it there."
    assert set(started) == {"session_id", "flow", "user_code", "verification_url", "expires_in", "poll_interval"}
    assert started["flow"] == "device_code" and started["user_code"] in started["verification_url"]
    assert pending["status"] == "pending" and approved["status"] == "approved"
    assert nous["status"]["logged_in"] and nous["status"]["token_preview"].startswith("…")
    assert (denied["status"], denied["reason"]) == ("denied", "denied")
    assert external.json() == {"detail": "anthropic uses an external CLI; run `hermes auth add anthropic` manually"}
    assert unknown.json() == {"detail": "Unknown provider nobody"}
    assert mismatch.json() == {"detail": "Provider mismatch for session"} and lost.status_code == 404
    assert wrong_profile.json() == {"detail": "OAuth session profile mismatch"}
    assert cancelled == {"ok": True, "session_id": scoped["session_id"]}
    assert gone == {"ok": False, "message": "session not found"}
    assert submit.json() == {"detail": "submit not supported for nous"}
    assert disconnected == {"ok": True, "provider": "openai-codex"}
    assert twice.status_code == 409 and cli_managed.status_code == 400


def test_profiles_create_clone_rename_delete_soul_and_export_import():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            async with signed_in(base) as http:
                created = (await http.post("/api/profiles", json={"name": "work", "soul": "Be terse."})).json()
                soul = (await http.get("/api/profiles/work/soul")).json()
                saved = (await http.put("/api/profiles/work/soul", json={"content": "Be kind."})).json()
                soul_after = (await http.get("/api/profiles/work/soul")).json()
                clone = (await http.post("/api/profiles", json={"name": "Ops", "clone_from": "research",
                                                                 "description": "On call"})).json()
                clone_config = (await http.get("/api/config", params={"profile": "ops"})).json()
                clone_soul = (await http.get("/api/profiles/ops/soul")).json()
                fresh = (await http.post("/api/profiles", json={"name": "lab", "provider": "fake",
                                                                 "model": "fake-hermes-mini"})).json()
                refused = {name: (await http.post("/api/profiles", json={"name": name})).status_code
                           for name in ("My Work", "default", "test", "work")}
                listed = [p["name"] for p in (await http.get("/api/profiles")).json()["profiles"]]
                rows = {p["name"]: p for p in (await http.get("/api/profiles")).json()["profiles"]}
                sidebar = (await http.get("/api/profiles/sessions/sidebar")).json()["recents"]["profiles_usage"]
                renamed = (await http.patch("/api/profiles/work", json={"new_name": "deep-work"})).json()
                titled = (await http.patch("/api/profiles/default", json={"new_name": "Home"})).json()
                to_default = await http.patch("/api/profiles/ops", json={"new_name": "default"})
                active = (await http.post("/api/profiles/active", json={"name": "deep-work"})).json()
                sticky = (await http.get("/api/profiles/active")).json()
                missing_active = await http.post("/api/profiles/active", json={"name": "ghost"})
                deleted = (await http.delete("/api/profiles/deep-work")).json()
                sticky_after = (await http.get("/api/profiles/active")).json()
                delete_default = await http.delete("/api/profiles/default")
                delete_missing = await http.delete("/api/profiles/ghost")
                soul_missing = await http.get("/api/profiles/ghost/soul")
                exported = (await http.post("/api/profiles/research/export",
                                            json={"extra_files": {}, "output": ""})).json()
                imported = (await http.post("/api/profiles/import",
                                            json={"archive": exported["archive"], "name": "research-copy"})).json()
                imported_soul = (await http.get("/api/profiles/research-copy/soul")).json()
                clash = await http.post("/api/profiles/import", json={"archive": exported["archive"]})
                no_archive = await http.post("/api/profiles/import", json={"archive": "/nowhere.tar.gz"})
                setup = (await http.get("/api/profiles/lab/setup-command")).json()
                setup = {**setup, "soul": (await http.get("/api/profiles/lab/soul")).json()}
                model = (await http.put("/api/profiles/lab/model", json={"provider": "echo-cloud",
                                                                           "model": "echo-2-pro"})).json()
                lab = next(p for p in (await http.get("/api/profiles")).json()["profiles"] if p["name"] == "lab")
        return (created, soul, saved, soul_after, clone, clone_config, clone_soul, fresh, refused, listed, rows,
                sidebar, renamed, titled, to_default, active, sticky, missing_active, deleted, sticky_after,
                delete_default, delete_missing, soul_missing, exported, imported, imported_soul, clash, no_archive,
                setup, model, lab)

    (created, soul, saved, soul_after, clone, clone_config, clone_soul, fresh, refused, listed, rows, sidebar,
     renamed, titled, to_default, active, sticky, missing_active, deleted, sticky_after, delete_default,
     delete_missing, soul_missing, exported, imported, imported_soul, clash, no_archive, setup, model,
     lab) = asyncio.run(scenario())
    assert created["ok"] and created["soul_set"] and created["path"].endswith("/profiles/work")
    assert soul == {"content": "Be terse.", "exists": True}
    assert saved == {"ok": True} and soul_after["content"] == "Be kind."
    assert clone["name"] == "Ops" and not clone["soul_set"], "the response names the profile as requested"
    assert clone_config["model"] == "echo-1" and clone_soul["content"].startswith("You read papers")
    assert fresh["model_set"] and fresh["model_error"] == ""
    assert refused == {"My Work": 400, "default": 400, "test": 400, "work": 400}
    assert listed == ["default", "research", "work", "ops", "lab"]
    assert rows["ops"]["description"] == "On call" and rows["lab"]["model"] == "fake-hermes-mini"
    assert set(sidebar) == set(listed)
    assert renamed == {"ok": True, "name": "deep-work", "path": renamed["path"]}
    assert titled["display_name"] == "Home" and titled["name"] == "default"
    assert to_default.json() == {"detail": "Cannot rename to 'default' — it is reserved."}
    assert active == {"ok": True, "active": "deep-work"} and sticky == {"active": "deep-work", "current": "default"}
    assert missing_active.status_code == 404
    assert deleted["ok"] and sticky_after["active"] == "default", "deleting the sticky profile falls back"
    assert delete_default.status_code == 400 and delete_missing.status_code == 404
    assert soul_missing.json() == {"detail": "Profile 'ghost' does not exist."}
    assert exported["archive"].endswith(".tar.gz") and "/profile-exports/research-" in exported["archive"]
    assert imported["name"] == "research-copy" and imported_soul["content"].startswith("You read papers")
    assert clash.status_code == 400 and no_archive.status_code == 404
    assert setup == {"command": "lab setup", "soul": {"content": DEFAULT_SOUL, "exists": True}}
    assert model == {"ok": True, "provider": "echo-cloud", "model": "echo-2-pro"} and lab["provider"] == "echo-cloud"


def test_status_is_public_and_carries_the_versions():
    async def scenario():
        async with serving() as (fake, base):
            async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                status = (await anonymous.get("/api/status")).json()
                missing = await anonymous.get("/api/status", params={"profile": "nobody"})
        return status, missing

    status, missing = asyncio.run(scenario())
    assert status["version"] and status["release_date"] and status["config_version"] == status["latest_config_version"]
    assert status["gateway_running"] and status["gateway_state"] == "running" and status["overall"] == "ok"
    assert status["auth_required"] and status["profiles"] == ["default", "research"]
    assert "hermes_home" not in status, "a gated bind keeps host paths out of the public probe"
    assert missing.status_code == 404


def test_vault_and_billing_rpcs_follow_the_contract(capsys):
    password, card = "hunter2-correct-horse", "4242424242424242"

    async def scenario():
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                sources = await gateway.call("vault.sources", {})
                listed = await gateway.call("vault.list", {})
                login = await gateway.call("vault.add", {"kind": "login", "label": "Forum", "origin":
                                                         "https://forum.example.com:443/login", "secret": {
                                                             "identifier_type": "username", "identifier": "me",
                                                             "password": password}})
                payment = await gateway.call("vault.add", {"kind": "payment", "label": "Card", "secret": {
                    "card_number": card, "exp_month": "12", "exp_year": "2030", "cvc": "123", "nickname": "x"}})
                refusals = [(await failure(gateway, "vault.add", params)).message for params in (
                    {"kind": "login", "label": "x", "secret": {}},
                    {"kind": "note", "label": "x", "secret": {"a": "b"}},
                    {"kind": "login", "label": "x", "origin": "forum.example.com",
                     "secret": {"identifier_type": "email", "identifier": "a", "password": "b"}},
                    {"kind": "address", "label": "Home", "secret": {"city": "Oslo"}})]
                wrong = await failure(gateway, "vault.unlock", {"name": "onepassword", "password": "wrong"})
                not_installed = await failure(gateway, "vault.unlock", {"name": "bitwarden", "password": "x"})
                unlocked = await gateway.call("vault.unlock", {"name": "onepassword", "password": password})
                with_manager = await gateway.call("vault.list", {})
                locked = await gateway.call("vault.lock", {"name": "onepassword"})
                after_lock = await gateway.call("vault.sources", {})
                disabled = await gateway.call("vault.source.set", {"name": "onepassword", "enabled": False})
                after_disable = await gateway.call("vault.sources", {})
                enabled = await gateway.call("vault.source.set", {"name": "onepassword", "enabled": True})
                unknown_source = await failure(gateway, "vault.source.set", {"name": "keepass", "enabled": True})
                removed = await gateway.call("vault.remove", {"id": login["id"]})
                removed_again = await gateway.call("vault.remove", {"id": login["id"]})
                research = await gateway.call("vault.list", {"profile": "research"})

                state = await gateway.call("billing.state", {})
                before_scope = await gateway.call("billing.charge", {"amount_usd": 25})
                granted = await gateway.call("billing.step_up", {})
                verification = await gateway.event("billing.step_up.verification")
                charge = await gateway.call("billing.charge", {"amount_usd": 25, "idempotency_key": "k1"})
                retry = await gateway.call("billing.charge", {"amount_usd": 25, "idempotency_key": "k1"})
                too_much = await gateway.call("billing.charge", {"amount_usd": 5000})
                pending = await gateway.call("billing.charge_status", {"charge_id": charge["charge_id"]})
                await asyncio.sleep(fake.charge_settle_after + 0.05)
                settled = await gateway.call("billing.charge_status", {"charge_id": charge["charge_id"]})
                no_id = await gateway.call("billing.charge_status", {})
                reload = await gateway.call("billing.auto_reload", {"enabled": True, "threshold": 10,
                                                                    "top_up_amount": 40})
                reload_missing = await gateway.call("billing.auto_reload", {"enabled": True})
                state_after = await gateway.call("billing.state", {})
                problems = contract_problems(gateway)
                await gateway.close()
        return (sources, listed, login, payment, refusals, wrong, not_installed, unlocked, with_manager, locked,
                after_lock, disabled, after_disable, enabled, unknown_source, removed, removed_again, research, state,
                before_scope, granted, verification, charge, retry, too_much, pending, settled, no_id, reload,
                reload_missing, state_after, problems)

    (sources, listed, login, payment, refusals, wrong, not_installed, unlocked, with_manager, locked, after_lock,
     disabled, after_disable, enabled, unknown_source, removed, removed_again, research, state, before_scope, granted,
     verification, charge, retry, too_much, pending, settled, no_id, reload, reload_missing, state_after,
     problems) = asyncio.run(scenario())
    logs = capsys.readouterr().out
    assert problems == []
    assert [(s["name"], s["enabled"], s["installed"]) for s in sources["sources"]] == [
        ("local", True, True), ("onepassword", True, True), ("bitwarden", False, False)]
    assert [i["backend"] for i in listed["items"]] == ["local"] and "secret" not in listed["items"][0]
    assert login["id"].startswith("vault_") and payment["id"].startswith("vault_")
    assert refusals == ["secret payload is required",
                        "unknown vault kind 'note' (expected one of ('login', 'payment', 'address'))",
                        "origin must include a scheme (got 'forum.example.com')",
                        "address items require address_line1, postal_code, country"]
    assert wrong.code == 5095 and not_installed.message == "bitwarden is not an enabled password manager"
    assert unlocked == {"name": "onepassword", "unlocked": True}
    forum = next(i for i in with_manager["items"] if i["label"] == "Forum")
    assert forum["origin"] == "https://forum.example.com" and forum["identifier"] == "me"
    assert {i["backend"] for i in with_manager["items"]} == {"local", "onepassword"}
    assert locked == {"locked": True} and not after_lock["sources"][1]["unlocked"]
    assert disabled == {"name": "onepassword", "enabled": False} and not after_disable["sources"][1]["enabled"]
    assert enabled["enabled"] and unknown_source.message == "unknown vault source: keepass"
    assert removed == {"removed": True} and removed_again == {"removed": False} and research == {"items": []}
    assert state["logged_in"] and state["balance_display"] == "$12.34" and state["charge_presets_display"][0] == "$10"
    assert before_scope["error"] == "insufficient_scope" and before_scope["idempotency_key"]
    assert granted == {"ok": True, "granted": True} and verification["payload"]["user_code"]
    assert charge["ok"] and retry["charge_id"] == charge["charge_id"], "the same key is the same charge"
    assert too_much["ok"] is False and too_much["error"] == "invalid_amount"
    assert pending["status"] == "pending" and settled["status"] == "settled" and settled["settled_at"]
    assert no_id == {"ok": False, "error": "invalid_charge_id", "message": "charge_id is required"}
    assert reload == {"ok": True} and reload_missing["error"] == "invalid_request"
    assert state_after["balance_usd"] == "37.34" and state_after["auto_reload"]["enabled"]
    assert state_after["auto_reload"]["reload_to_display"] == "$40"
    assert password not in logs and card not in logs, "vault secrets never reach the log"


def test_alert_registration_and_the_alerts_a_backgrounded_app_would_get():
    async def scenario():
        async with serving(reap_grace=30.0) as (fake, base):
            async with signed_in(base) as http:
                device = {"voip_token": VOIP, "alert_token": ALERT, "environment": "sandbox",
                          "bundle_id": "com.example.hermesvoice"}
                bad = {name: (await http.post(f"{PREFIX}/devices", json={**device, **extra})).status_code
                       for name, extra in {"not bool": {"alerts": {"approval": "yes"}},
                                           "not an object": {"alerts": ["approval"]}}.items()}
                # As the plugin: a kind it doesn't know is ignored, and a kind never named is on.
                unknown_kind = await http.post(f"{PREFIX}/devices", json={**device, "alerts": {"turnDone": False}})
                fresh = (await http.get(f"{PREFIX}/status")).json()["devices"][0]["alerts"]
                registered = await http.post(f"{PREFIX}/devices", json={
                    **device, "alerts": {"approval": True, "clarify": False, "turn_done": True}})
                # What the app sends before iOS hands it an alert token: the stored one stays, the named kinds merge.
                no_alert_token = await http.post(f"{PREFIX}/devices", json={
                    "voip_token": VOIP, "environment": "sandbox", "bundle_id": "com.example.hermesvoice",
                    "alerts": {"approval": True}})
                status = (await http.get(f"{PREFIX}/status")).json()

                gateway = await Gateway.connect(base, http)
                created = await gateway.call("session.create", {"source": "desktop"})
                sid, key = created["session_id"], created["stored_session_id"]
                await gateway.call("prompt.submit", {"session_id": sid, "text": "please approve this"})
                request = await gateway.request("approval")
                await gateway.close()  # the app goes to the background; the approval stays open
                approval = (await http.get(f"{PREFIX}/debug/alerts",
                                           params={"session_id": key, "kind": "approval"})).json()
                # The lock-screen "Run" action: a fresh socket answers the request named in the push.
                answering = await Gateway.connect(base, http)
                answered = await answering.call("request.answer", {"id": approval["alert"]["hermes"]["request_id"],
                                                                   "result": {"choice": "once"}})
                await until(lambda: any(a["kind"] == "turn_done" for a in fake.alerts), 10)
                done = (await http.get(f"{PREFIX}/debug/alerts", params={"session_id": sid})).json()
                await answering.call("session.activate", {"session_id": sid})
                await answering.call("prompt.submit", {"session_id": sid, "text": "clarify please"})
                clarify_request = await answering.request("clarify")
                clarify = (await http.get(f"{PREFIX}/debug/alerts",
                                          params={"session_id": key, "kind": "clarify"})).json()
                await answering.respond(clarify_request["id"], {"answers": {"q0": "Green"}})
                await until(lambda: sum(a["kind"] == "turn_done" for a in fake.alerts) == 2, 10)
                everything = (await http.get(f"{PREFIX}/debug/alerts")).json()
                unknown = await http.get(f"{PREFIX}/debug/alerts", params={"session_id": "nope"})
                bad_kind = await http.get(f"{PREFIX}/debug/alerts", params={"kind": "ring"})
                await answering.close()
                # An explicit null clears the alert token: no alerts reach the phone, VoIP still rings it.
                cleared = await http.post(f"{PREFIX}/devices", json={**device, "alert_token": None})
                after_clear = (await http.get(f"{PREFIX}/status")).json()["devices"]
            async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                anonymous_alerts = (await anonymous.get(f"{PREFIX}/debug/alerts")).status_code
        return (bad, unknown_kind, fresh, no_alert_token, registered, status, key, request, approval, answered, done,
                clarify, everything, unknown, bad_kind, cleared, after_clear, anonymous_alerts)

    (bad, unknown_kind, fresh, no_alert_token, registered, status, key, request, approval, answered, done, clarify,
     everything, unknown, bad_kind, cleared, after_clear, anonymous_alerts) = asyncio.run(scenario())
    assert bad == {"not bool": 422, "not an object": 422}
    assert unknown_kind.json() == {"ok": True}
    assert fresh == {"approval": True, "clarify": True, "turn_done": True}
    assert no_alert_token.json() == {"ok": True}
    assert registered.json() == {"ok": True}
    [listed] = status["devices"]
    assert listed["voip_token"] == VOIP and listed["alert_token"] == ALERT
    assert listed["alerts"] == {"approval": True, "clarify": False, "turn_done": True}

    alert = approval["alert"]
    assert alert["aps"]["category"] == "HERMES_APPROVAL" and alert["aps"]["thread-id"] == key
    assert alert["aps"]["alert"]["title"] == "Approval needed" and "rm -rf" in alert["aps"]["alert"]["body"]
    assert alert["hermes"] == {"kind": "approval", "session_id": key, "profile": "default",
                               "request_id": request["id"], "choices": ["once", "session", "always", "deny"]}
    assert approval["sent_to"] == [ALERT]
    assert answered == {"status": "ok"}
    assert done["kind"] == "turn_done" and done["alert"]["aps"]["category"] == "HERMES_TURN_DONE"
    assert "Approved (once)" in done["alert"]["aps"]["alert"]["body"] and done["sent_to"] == [ALERT]
    questions = clarify["alert"]["hermes"]["questions"]
    assert [q["qid"] for q in questions] == ["q0", "q1", "q2"] and questions[0]["choices"][0] == "Blue (Recommended)"
    assert "choices" not in questions[2] and clarify["sent_to"] == [], "clarify alerts were switched off"
    assert clarify["alert"]["aps"]["alert"]["body"].startswith("Which color should the demo use?\nBlue")
    assert [a["kind"] for a in everything["alerts"]] == ["approval", "turn_done", "clarify", "turn_done"]
    assert unknown.status_code == 404 and bad_kind.status_code == 422 and anonymous_alerts == 401
    assert cleared.json() == {"ok": True}
    assert [(d["voip_token"], d["alert_token"]) for d in after_clear] == [(VOIP, None)]
    assert after_clear[0]["alerts"] == {"approval": False, "clarify": False, "turn_done": False}
