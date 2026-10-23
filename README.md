# OpenClaw Railway Template

## Security Notice

> **This template exposes your OpenClaw gateway to the public internet.** **Please read the [OpenClaw security documentation](https://docs.openclaw.ai/gateway/security) before deploying** to understand the risks and recommended configuration. If you only use chat channels (Telegram, Discord, Slack) and don't need the gateway dashboard, you can remove the public endpoint from Railway after setup.

<img width="1860" height="2624" alt="CleanShot 2026-02-23 at 21 59 06@2x" src="https://github.com/user-attachments/assets/2605d44c-4319-4e92-838c-3caa726b9595" />

## What you get

- **OpenClaw Gateway + Control UI** (served at `/` and `/openclaw`)
- A friendly **Setup Wizard** at `/setup` (protected by a password)
- Persistent state via **Railway Volume** (so config/credentials/memory survive redeploys)

## How it works (high level)

- The container runs a wrapper web server.
- The wrapper protects `/setup` with `SETUP_PASSWORD`.
- During setup, the wrapper runs `openclaw onboard ...` inside the container, writes state to the volume, and then starts the gateway. API-key providers use non-interactive setup. Interactive device-code logins (ChatGPT/Codex, xAI/Grok) can't run from the web wizard — complete those by running `openclaw wizard` in the Railway console.
- After setup, **`/` is OpenClaw**. The wrapper reverse-proxies all traffic (including WebSockets) to the local gateway process.

## Getting chat tokens (so you don't have to scramble)

### ChatGPT / OpenAI Codex and Grok / xAI subscription login

These providers use an interactive device-code login that the web `/setup` wizard can't drive. Complete them from the Railway console instead:

1. Open your service in Railway and launch the **console** (a shell inside the running container).
2. Run `openclaw wizard` and follow the prompts. Choose the ChatGPT/Codex or xAI/Grok device login, open the URL it prints in your browser, and enter the short code.
3. Once the wizard finishes saving the OAuth profile, return to `/setup` — the instance will be configured and the gateway will start.

This lets you use a ChatGPT/Codex account or an eligible SuperGrok / X Premium subscription without pasting an API key.

### Telegram bot token

1. Open Telegram and message **@BotFather**
2. Run `/newbot` and follow the prompts
3. BotFather will give you a token that looks like: `123456789:AA...`
4. Paste that token into `/setup`

### Discord bot token

1. Go to the Discord Developer Portal: https://discord.com/developers/applications
2. **New Application** → pick a name
3. Open the **Bot** tab → **Add Bot**
4. Copy the **Bot Token** and paste it into `/setup`
5. Invite the bot to your server (OAuth2 URL Generator → scopes: `bot`, `applications.commands`; then choose permissions)

## Local testing

```bash
docker build -t openclaw-railway-template .

docker run --rm -p 8080:8080 \
  -e PORT=8080 \
  -e SETUP_PASSWORD=test \
  -e OPENCLAW_STATE_DIR=/data/.openclaw \
  -e OPENCLAW_WORKSPACE_DIR=/data/workspace \
  -v $(pwd)/.tmpdata:/data \
  openclaw-railway-template

# Setup wizard: http://localhost:8080/setup (password: test)
```

## Console helpers

A new Railway console starts as root `bash`, which immediately enters the `openclaw` user with `zsh` in `OPENCLAW_STATE_DIR` (default `/data/.openclaw`). `exit` leaves that zsh and returns to the root `bash`.

Scripts in `bin/` are installed to `/app/bin` and are on `PATH` in the Railway console:

- `cdw` — `cd` to the workspace directory (`OPENCLAW_WORKSPACE_DIR`, falling back to `${OPENCLAW_STATE_DIR:-/data/.openclaw}/workspace`). It is a shell alias, so it changes your current shell's directory.
- `provider-quota` — remaining quota for every configured model provider, plus a link to add tokens. `provider-quota --json` prints the same report as JSON.
- `disk-usage` — finds the biggest files and directories under `/data` (or any path) so you know what's safe to delete. `disk-usage --min-size 1G` raises the threshold (default `500M`); `disk-usage --json` prints the same report as JSON.
- `r2-sync` — the R2 workspace sync job (see below). The entrypoint already runs it in the background when `R2_BUCKET` is set.

## Sync the workspace with Cloudflare R2 (Obsidian)

Optional. A background job two-way syncs `/data/workspace` (`MEMORY.md`, `memory/`, `AGENTS.md`, skills, ...) with an R2 bucket using `rclone bisync`, so you can edit the markdown in Obsidian. Leave `R2_BUCKET` unset to disable it. `/data/.openclaw` (config, gateway token) is never synced.

### 1. Cloudflare

1. Create an R2 bucket (e.g. `openclaw-workspace`).
2. Create an R2 API token with **Object Read & Write**, scoped to that bucket.
3. Note your Account ID.

### 2. Railway variables

| Variable | Required | Description |
| --- | --- | --- |
| `R2_BUCKET` | yes | Bucket name. Enables the sync. |
| `R2_ACCOUNT_ID` | yes* | Cloudflare account ID (*or set `R2_ENDPOINT`). |
| `R2_ACCESS_KEY_ID` | yes | API token access key. |
| `R2_SECRET_ACCESS_KEY` | yes | API token secret. |
| `R2_PREFIX` | no | Key prefix inside the bucket. |
| `R2_SYNC_INTERVAL` | no | Max seconds between syncs (default `120`). |
| `R2_SYNC_DEBOUNCE` | no | Quiet period after the last change before syncing (default `5`). |
| `R2_GIT_REMOTE` | no | Private git remote URL (token included) that snapshots are pushed to. |

The job watches the workspace with inotify, so a sync starts a few seconds after the agent writes a file rather than on a fixed schedule. `R2_SYNC_INTERVAL` is the ceiling: if nothing changes locally it still syncs that often, which is how edits made in Obsidian get pulled down.

On first run the local workspace and the bucket are merged (newest file wins). After that, deletes and edits propagate both ways. If the same file changes on both sides within one cycle, the newer one wins and the older is kept as a numbered copy (e.g. `MEMORY.md.conflict1`). On redeploy, the job runs one last sync before the container stops. Logs: stdout and `/data/.openclaw/r2-sync.log`.

### 3. Obsidian

Install the **Remotely Save** community plugin and set:

- Service: S3 or S3-compatible; endpoint `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`; region `auto`; the same bucket and keys.
- "Remote Base Subdir": match `R2_PREFIX` if you use one.
- Enable scheduled sync (e.g. every 5 minutes) and sync on startup.
- Desktop: enable "Bypass CORS". Mobile: add a CORS rule to the bucket.
- Do not sync the `.obsidian` config folder (the server also ignores it).

The OpenClaw memory index watches the workspace, so synced edits are picked up without a restart. Expect a delay of a few minutes in each direction.

### Rolling back

R2 has no object versioning, so history is kept as git commits in `/data/workspace/.git` (never synced to R2). A snapshot is committed before and after every sync when something changed. From the Railway Console:

```bash
git -C /data/workspace log --oneline -- MEMORY.md      # history
git -C /data/workspace diff <sha> -- MEMORY.md         # compare
git -C /data/workspace checkout <sha> -- MEMORY.md     # restore one file
git -C /data/workspace checkout <sha> -- .             # restore everything
```

A restore gives files a fresh modified time, so the next sync pushes them to R2 and Obsidian. For a large restore, pause the sync first and resume afterwards:

```bash
touch /data/.r2-sync-paused    # pause
rm /data/.r2-sync-paused       # resume
r2-sync --resync               # merge both sides again (newest wins)
```

If a sync is killed mid-run, the next start drops the leftover bisync lock when that rclone process is gone. `--resync` is also what to run after a filters change. When a sync is already running, the command just asks that process to resync; it does not start a second one.

Set `R2_GIT_REMOTE` to also push snapshots to a private repo, so history survives losing the volume. Changes are captured per sync cycle, not per edit.

## FAQ

**Q: How do I access the setup page?**

A: Go to `/setup` on your deployed instance. When prompted for credentials, use the generated `SETUP_PASSWORD` from your Railway Variables as the password. The username field is ignored—you can leave it empty or enter anything.

**Q: I see "gateway disconnected" or authentication errors in the Control UI. What should I do?**

A: Go back to `/setup` and click the "Open OpenClaw UI" button from there. The setup page passes the required auth token to the UI. Accessing the UI directly without the token will cause connection errors.

**Q: How do I approve pairing for Telegram or Discord?**

A: Go to `/setup` and use the "Approve Pairing" dialog to approve pending pairing requests from your chat channels.

**Q: I see "pairing required" when opening the Control UI. How do I fix it?**

A: New browsers/devices need a one-time approval from the gateway. Go to `/setup`, click "Manage Devices" in the Devices section, and click "Approve Latest Request". Refresh the Control UI and it should connect. Local connections (127.0.0.1) are auto-approved; remote connections (LAN, public URL) require explicit approval.

**Q: How do I change the AI model after setup?**

A: Use the OpenClaw CLI to switch models. Railway provides an integrated in-browser shell directly in your dashboard — no external SSH client needed. Open the Railway dashboard, click your service, go to the **Console** tab, and use the connected shell to run:

```bash
openclaw models set provider/model-id
```

For example: `openclaw models set anthropic/claude-sonnet-4-20250514` or `openclaw models set openai/gpt-4-turbo`. Use `openclaw models list --all` to see available models.

**Q: How do I access configuration after the initial setup?**

A: Visit `/setup` on your deployed instance at any time — it works both before and after setup. Once configured, the setup page shows your current status along with management tools: device approval, health checks (Run Doctor), data export, and a reset option. You'll need your `SETUP_PASSWORD` to access it.

**Q: My config seems broken or I'm getting strange errors. How do I fix it?**

A: Go to `/setup` and click the "Run Doctor" button. This runs `openclaw doctor --fix` which performs health checks on your gateway and channels, creates a backup of your config, and removes any unrecognized or corrupted configuration keys.

## Screenshots

## Setup

<img width="2110" height="2032" alt="CleanShot 2026-02-23 at 21 57 59@2x" src="https://github.com/user-attachments/assets/28640eec-fa35-42f2-ba56-cb1fbb9525de" />

## Device approval

<img width="1712" height="1376" alt="CleanShot 2026-02-23 at 21 59 21@2x" src="https://github.com/user-attachments/assets/f30ab683-dbc2-4980-ace7-152265e00c79" />

## Support

Need help? [Request support on Railway Station](https://station.railway.com/all-templates/d0880c01-2cc5-462c-8b76-d84c1a203348)
