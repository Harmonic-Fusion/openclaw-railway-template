# Problem Statement

`bin/r2-sync` is a bash watchdog that two-way syncs the OpenClaw workspace with a Cloudflare R2 bucket. There is no way to make one side win: an operator who restores files locally, or who wants the bucket to overwrite the workspace, can only run `--resync`, which merges by newest mtime. The script should be rewritten in Python, and it should be able to force the workspace onto R2 (push) or R2 onto the workspace (pull).

# Scope

In scope:

- Replace `bin/r2-sync` with a Python 3 program. The executable path stays `bin/r2-sync` so `entrypoint.sh` (`/app/bin/r2-sync`) and operator docs keep working. Python 3 is already in the image. No new packages.
- Preserve the unattended job: no arguments, opt-in on `R2_BUCKET`, two-way sync, inotify debounce plus `R2_SYNC_INTERVAL`, pause file, git snapshots, filters, singleton, stale-lock cleanup, log rotation, and a final sync on SIGTERM.
- Add three explicit operator commands:
  - **push** — the workspace is authoritative. R2 is updated to match it, including deletes.
  - **pull** — R2 is authoritative. The workspace is updated to match it, including deletes.
  - **resync** — merge both sides, newest file wins. Same merge as today's `--resync`. The `--resync` flag is removed.
- After a push or pull, the next unattended two-way cycle must start from that result. It must not merge the other side back and undo the force.
- The unattended two-way safety cap (refuse when more than 25% of files would be deleted) does not apply to push or pull. It still applies to two-way cycles and to `resync`.
- `push`, `pull`, and `resync` run even when `/data/.r2-sync-paused` exists. The pause file still skips cycles of the unattended job.
- Git snapshots still run before and after `push`, `pull`, and `resync` when `R2_GIT_SNAPSHOTS` is true (default).
- One worker serializes every rclone operation through a single in-memory queue: two-way cycles, push, pull, and resync. The worker runs one item at a time. An in-flight item finishes before the next starts. The queue is not stored on the volume and does not survive a worker restart.
- `r2-sync push`, `r2-sync pull`, and `r2-sync resync` are foreground commands. Each enqueues one item. If the worker is not running, the command starts it. The command waits until that item finishes, then exits with the item's status. It does not stay in the watch loop. If the worker exits before the item finishes, the command exits non-zero.
- A queued push, pull, or resync starts without waiting out `R2_SYNC_INTERVAL`. Items already on the queue stay in FIFO order.
- Update the R2 section of `README.md` so `push`, `pull`, and `resync` are distinguishable.

Out of scope:

- Replacing rclone. It stays the transfer engine (image pin `v1.75.1`). Python orchestrates it.
- Changing which directory is synced (`OPENCLAW_WORKSPACE_DIR`, default `$OPENCLAW_STATE_DIR/workspace`). `/data/.openclaw` stays unsynced.
- Changing filter rules, pause-file path, log path, env var names, or the newest-wins result of a resync merge.
- A persistent one-way unattended job. Push and pull are operator commands only. The background process stays two-way.
- New ops-tools entries. `r2-sync` is not an agent tool today.

Preserved operator contract (must still hold after the rewrite):

- Missing `R2_BUCKET` exits 0 with no log. Bucket set but credentials or account/endpoint missing: log and exit 0, so the container does not crash-loop.
- Env: `R2_BUCKET`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID`, `R2_ENDPOINT`, `R2_PREFIX`, `R2_SYNC_INTERVAL` (120), `R2_SYNC_DEBOUNCE` (5), `R2_GIT_REMOTE`, `R2_GIT_SNAPSHOTS` (true), `R2_DATA_DIR` (`/data`), `OPENCLAW_STATE_DIR`, `OPENCLAW_WORKSPACE_DIR`.
- Pause: `touch /data/.r2-sync-paused` / `rm /data/.r2-sync-paused`.
- The first unattended cycle, when bisync has no listings, merges newest-wins.
- Ignore rules: built-in excludes (`.git`, `node_modules`, `.obsidian`, `.trash`, `_remotely-save-metadata-on-remote.json`, `.DS_Store`, `*.tmp`) plus `.r2-sync-ignore` files, gitignore-style, nested rules overriding parents.
- Two-way conflicts: newer file wins; the older copy is kept with a numeric suffix.
- Logs: stdout and `$OPENCLAW_STATE_DIR/r2-sync.log`, trimmed around 1MB.
- One unattended process per volume. A second start exits 0.

# Solution

Keep rclone and the existing two-way watchdog. Rewrite the bash orchestration in Python (stdlib only, `#!/usr/bin/env python3`, same filename) so direction handling is not another layer of shell.

Explicit work is three subcommands with the same foreground behavior. Only the rclone operation differs:

- `r2-sync` — unattended two-way job.
- `r2-sync push` — make R2 match the workspace, including deletes.
- `r2-sync pull` — make the workspace match R2, including deletes.
- `r2-sync resync` — merge both sides, newest file wins. Replaces the `--resync` flag. The flag is not accepted.

One-way transfers go through bisync’s resync with one path authoritative (`path1` = workspace for push, `path2` = R2 for pull), not a separate `rclone sync`. A plain one-way copy would leave bisync listings stale, and the next unattended cycle could undo the force. Resync with a single winner updates those listings, so the following two-way cycle treats the forced tree as the baseline.

The unattended max-delete guard stays on two-way cycles and on `resync`. Push and pull bypass it because the operator asked one side to replace the other.

The worker is the only process that runs rclone. It drains one in-memory `queue.Queue`, shared by two-way cycles and explicit commands. That queue is the worker's only event source: explicit commands, workspace-change notices, the interval timer, and stop. The main thread is the only consumer. Producers are a socket thread, an inotify thread, and a self-pipe for SIGTERM — `queue.Queue.put` is not called from the signal handler. Debounce is coalescing on that queue: a change sets a two-way deadline of now plus `R2_SYNC_DEBOUNCE`, later changes push the deadline out, and an explicit item already queued runs immediately and stays ahead of the pending two-way cycle. A two-way cycle is also queued at least every `R2_SYNC_INTERVAL`.

The socket is a Unix-domain socket in `/tmp` (per container, not on the volume). Binding it is the singleton: the no-args process that binds is the worker; a second no-args start finds the socket live and exits 0. The pidfile, worker flock, and process-argument checks are not the singleton. rclone's own bisync lock files stay as they are. A stale socket file is removed when connect fails and the bind is retried.

`r2-sync push`, `r2-sync pull`, and `r2-sync resync` connect and write one JSON line. They read that item's status from the same connection and exit with it. They do not enter the watch loop and do not take a later two-way cycle with them. If nothing is listening, the command spawns a detached worker and retries the connect. The spawned worker places that first request on the queue before it schedules a two-way cycle, so the force is not stuck behind the startup sync. If the worker exits before the reply, the command sees the socket close and exits non-zero. Nothing is written under `queue/`, `results/`, `queue.lock`, or `queue.seq`. A restart drops whatever was only in memory.

On SIGTERM the worker finishes the in-flight item, runs explicit items already on the queue, runs one final two-way sync, and exits, so a waiting push, pull, or resync still completes across a redeploy.

Rejected alternatives:

- `rclone sync` / `rclone copy` beside bisync. Listings would not match the forced tree, so the next bisync could revert it. `copy` also would not delete destination-only files.
- Dropping bisync and doing one-way only. Obsidian and the agent both edit the workspace; the unattended job still needs both directions.
- A boto3 rewrite. The image already pins rclone for bisync, filters, and conflict copies. Reimplementing that is a larger behavior change than this request.
- An on-disk JSON spool. There is no persistence requirement, and the spool needs a sequence file, a lock, a results directory, and polling to notice new items.
- A named pipe. It has no per-client reply, so a foreground command cannot wait on its own status.
- `multiprocessing.Queue` or a manager. Extra process and pickle machinery for a single-node script.
- SQLite or Redis. Persistence, or a second service this image does not run.

# Tasks

Python rewrite of `bin/r2-sync` with one in-memory worker queue. The unattended job stays two-way. `push`, `pull`, and `resync` are foreground commands that submit one operation over a Unix socket and wait for it. Eight tasks: worker, then the queue, then the three commands.

## Phase 1: Python worker and queue

- [x] Replace `bin/r2-sync` with a Python 3 script at the same path (stdlib only) that preserves the operator contract in Scope: env, opt-in exits, pause file, filters, git snapshots, singleton, stale-lock cleanup, log rotation, inotify debounce, and a newest-wins merge on the first cycle when bisync has no listings.
- [x] Drain two-way cycles through one queue, one rclone operation at a time, as described in Solution. A second no-args start exits 0.
- [x] On SIGTERM, finish the in-flight item, run explicit items already queued, run one final two-way sync, and exit. `entrypoint.sh` still starts `/app/bin/r2-sync` with no arguments when `R2_BUCKET` is set and still signals that process on shutdown.

## Phase 2: In-process queue

- [x] Replace the on-disk spool (`queue/`, `results/`, `queue.lock`, `queue.seq`) with the in-memory queue and `/tmp` Unix-domain socket in Solution. One worker binds the socket and runs rclone; a second no-args start exits 0. Foreground commands connect, submit one item, and exit with the status read from that connection. If no worker is listening they spawn one so their item is queued before the first two-way cycle. Socket close before a reply exits non-zero. Debounce and the interval are events on that queue. SIGTERM still finishes the in-flight item, drains queued explicit items, runs one final two-way sync, and exits.

## Phase 3: push, pull, and resync

- [x] Add `push`, `pull`, and `resync` queue items. `push` and `pull` make one side authoritative, including deletes, skip the max-delete cap, and refresh bisync state so the next two-way cycle keeps the result. `resync` merges newest-wins and keeps the max-delete cap. All three run even when the pause file exists.
- [x] `r2-sync push`, `r2-sync pull`, and `r2-sync resync` submit through the Phase 2 socket and exit with that item's status. They do not enter the watch loop. `--resync` and any other unknown argument exit 2.
- [x] A queued push, pull, or resync starts without waiting out `R2_SYNC_INTERVAL`. Items already queued stay in FIFO order.
- [x] Document `r2-sync push`, `r2-sync pull`, and `r2-sync resync` in the script help and in the R2 section of `README.md`.
