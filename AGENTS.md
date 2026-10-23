# CLAUDE.md

Guidance for Claude Code in this repo.

## Overview

Railway deployment wrapper for **OpenClaw**. Provides a setup wizard (`/setup`, protected by `SETUP_PASSWORD`), reverse proxy from public URL → internal OpenClaw gateway, and persistent state via Railway Volume at `/data`. Lifecycle: onboarding → gateway startup → traffic proxying.

## Commands

```bash
npm run dev    # local dev (OpenClaw installed globally or OPENCLAW_ENTRY set)
npm start      # production
npm run lint   # syntax check

# Docker
docker build -t openclaw-railway-template .
docker run --rm -p 8080:8080 \
  -e PORT=8080 -e SETUP_PASSWORD=test \
  -e OPENCLAW_STATE_DIR=/data/.openclaw -e OPENCLAW_WORKSPACE_DIR=/data/workspace \
  -v $(pwd)/.tmpdata:/data openclaw-railway-template
open http://localhost:8080/setup  # password: test
```

## Architecture

**Request flow**: Railway → Wrapper (Express on `PORT`) → `/setup/*` goes to setup wizard (Basic auth), everything else proxies (HTTP/WS via `http-proxy`) to gateway (localhost:18789), auto-injecting `Authorization: Bearer <token>`.

**Lifecycle**: Unconfigured (no `openclaw.json` → all routes redirect to `/setup`, onboarding runs `openclaw onboard --non-interactive`) → Configured (`openclaw.json` exists → wrapper spawns `openclaw gateway run`, waits for health, proxies with token).

**Key files**:
- `src/server.js` — wrapper, proxy, gateway lifecycle, config persistence (no inline HTML/CSS)
- `src/public/` — `setup.html`, `styles.css`, `setup-app.js` (vanilla JS, no build step)
- `bin/` — console helpers copied to `/app/bin`, on `PATH` (also re-added in `/home/openclaw/openclaw.sh`).
- `plugins/ops-tools/` — tool plugin exposing `bin/` scripts as typed agent tools; declarations in `tools.json`, generic runner in `src/index.ts`, built into the image at `/app/plugins/ops-tools`
- `Dockerfile` — single-stage: installs OpenClaw via npm + wrapper deps

**Env vars**:
- Required: `SETUP_PASSWORD`
- Recommended: `OPENCLAW_STATE_DIR=/data/.openclaw`, `OPENCLAW_WORKSPACE_DIR=/data/workspace`
- Optional: `OPENCLAW_GATEWAY_TOKEN` (auto-generated if unset), `PORT` (8080), `INTERNAL_GATEWAY_PORT` (18789), `OPENCLAW_ENTRY` (default `/usr/local/lib/node_modules/openclaw/dist/entry.js`)

**Auth**: two-layer — (1) Basic auth w/ `SETUP_PASSWORD` for `/setup` (src/server.js:190); (2) Bearer token for gateway, auto-injected into proxied requests (src/server.js:736, 741), persisted to `${STATE_DIR}/gateway.token` if not in env (src/server.js:25-48).

**Onboarding** (src/server.js:522-693): `openclaw onboard --non-interactive` → writes channel configs (Telegram/Discord/Slack) directly via `openclaw config set --json` (not `channels add`, which is flaky across builds) → force-sets gateway to token auth + loopback bind + trusted proxy/origin → spawns gateway → waits on `/startupz`.

**Token injection**: always injected via `http-proxy` event handlers — `proxyReq` (HTTP, src/server.js:736) and `proxyReqWs` (WebSocket, src/server.js:741). Direct `req.headers` edits don't work reliably for WS upgrades. Lets Control UI (`/openclaw`) authenticate through the wrapper; new browser devices still need one-time approval via `/setup`.

## Common Tasks

- **Test setup wizard**: delete `${STATE_DIR}/openclaw.json` (or Reset in UI) → visit `/setup` → check logs.
- **Test auth**: setup wizard — clear browser auth, expect Basic challenge. Gateway — remove header injection (src/server.js:736), expect failures.
- **Debug gateway startup**: look for `[gateway] starting...` (142), `[gateway] ready...` (100), `[gateway] failed to become ready...` (109). Verify `openclaw.json` valid, `STATE_DIR`/`WORKSPACE_DIR` writable, bearer token set.
- **Add a `bin/` command**: see `plugins/ops-tools/AGENTS.md`. Declare it in `tools.json`, then `pnpm run plugin:build`.
- **Modify onboarding args**: edit `buildOnboardArgs()` (src/server.js:442-496).
- **Add channel type**: add fields to `src/public/setup.html` → config-writing logic in `/setup/api/run` → collection logic in `setup-app.js`.

## Railway Deployment

Volume at `/data` required. Set `SETUP_PASSWORD`. Enable public networking (`*.up.railway.app`). OpenClaw installed via `npm install -g openclaw@2026.8.2` in Docker build.

## Serena Semantic Coding

Project is onboarded with Serena (MCP). Before tasks: check `mcp__serena__check_onboarding_performed`, read relevant memories (`mcp__serena__read_memory`). Prefer `get_symbols_overview`, `find_symbol`, `find_referencing_symbols` for exploration, and `replace_symbol_body`/`insert_after_symbol` for edits.

## Quirks & Gotchas

1. Gateway token persisted to volume (stable across redeploys) if not in env.
2. Channels written via `config set --json`, not `channels add` (CLI version compat).
3. Traffic admission uses `/startupz`, not `/readyz`, so UI stays up even if one channel is unhealthy.
4. Discord bots require MESSAGE CONTENT INTENT (documented in setup wizard, src/server.js:295-298).
5. Gateway spawn inherits stdio → logs appear in wrapper output (src/server.js:134).
6. WebSocket auth requires `proxyReqWs` event handler (src/server.js:741); direct header mutation fails for WS upgrades.
7. Control UI devices require pairing — `gateway.controlUi.allowInsecureAuth` retired in OpenClaw 2026.8.1; approve new devices via `/setup`.
8. Wrapper is external supervisor — `OPENCLAW_SUPERVISOR_MODE=external` stops OpenClaw's own service/self-update from competing with Railway/wrapper lifecycle.
9. Config Editor (`/setup/config`) writes `openclaw.json` directly (parse+validate → `.bak-<timestamp>` copy → `fs.writeFileSync` → `restartGateway()`), unlike onboarding's CLI-based writes. Intentional: operator tool for fixing broken config without the CLI.
10. `/app` is root-owned and not writable (`chmod -R a-w`). The gateway user cannot edit `bin/` or `plugins/ops-tools/tools.json` after deploy, and cannot replace those directories because `/app` itself is not writable. Mutable state stays on `/data`. A config change to `plugins.load.paths` can still load a different plugin from the volume.
11. Provider plugins (`@openclaw/deepinfra-provider`, `@openclaw/groq-provider`, `@openclaw/perplexity-plugin`) are installed in the image at `/opt/openclaw-plugin-seed`, pinned to the OpenClaw release. An unpinned `plugins install` resolves a newer ClawHub build that this runtime rejects. `entrypoint.sh` copies `npm/projects` onto `$OPENCLAW_STATE_DIR` when `/opt/openclaw-plugin-seed/STAMP` changes. A symlink is not discovered. The volume hides anything the build writes under `/data`.
12. Railway console is an interactive root shell. `/etc/profile.d/zz-openclaw-console.sh` (also appended to `/etc/bash.bashrc` and `/root/.bashrc`; interactive `sh` reads it via `ENV`) runs `gosu openclaw zsh` with cwd `OPENCLAW_STATE_DIR` (default `/data/.openclaw`). An outer `sh` is replaced with bash first. `exit` returns to that root bash. The zsh is `/home/openclaw/.zshrc`. It sources `/home/openclaw/openclaw.sh`, `/home/openclaw/git.plugin.zsh`, and `/home/openclaw/.aliases` (copied from `~/projects/startup/aliases`).
