#!/bin/bash
set -e

# /proc/1/environ is root-only. Login shells source
# /etc/profile.d/container-env.sh, which reads this copy.
mkdir -p /run
cat /proc/self/environ > /run/container.env
chmod 644 /run/container.env

mkdir -p /data/.openclaw/ssh
chown -R openclaw:openclaw /data
chmod 700 /data /data/.openclaw/ssh

# Plugins are installed at image build into /opt/openclaw-plugin-seed.
# Copy them onto the volume state dir. A symlink is not discovered.
# The stamp skips this after the first boot of a given image.
seed_plugins() {
  local seed=/opt/openclaw-plugin-seed/npm/projects
  local stamp_src=/opt/openclaw-plugin-seed/STAMP
  local state="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
  local stamp_file="$state/npm/.image-plugins-stamp"
  local project name
  [ -d "$seed" ] && [ -f "$stamp_src" ] || return 0
  if [ -f "$stamp_file" ] && cmp -s "$stamp_src" "$stamp_file"; then
    return 0
  fi
  mkdir -p "$state/npm/projects"
  for project in "$seed"/*; do
    [ -d "$project" ] || continue
    name="$(basename "$project")"
    case "$name" in
      .*) continue ;;
    esac
    rm -rf "$state/npm/projects/$name"
    cp -a "$project" "$state/npm/projects/$name"
  done
  cp -a "$stamp_src" "$stamp_file"
  chown -R openclaw:openclaw "$state/npm"
}
seed_plugins
# Keys are created on the volume (github / github.pub). ~/.ssh follows that
# directory. /etc/ssh/ssh_config.d/github.conf selects this key for github.com.
# Private key must be 600 or ssh refuses it.
if [ -f /data/.openclaw/ssh/github ]; then
  chmod 600 /data/.openclaw/ssh/github
fi
ln -sfn /data/.openclaw/ssh /home/openclaw/.ssh
chown -h openclaw:openclaw /home/openclaw/.ssh

if [ ! -d /data/.linuxbrew ]; then
  cp -a /home/linuxbrew/.linuxbrew /data/.linuxbrew
fi

rm -rf /home/linuxbrew/.linuxbrew
ln -sfn /data/.linuxbrew /home/linuxbrew/.linuxbrew

# Stay as the supervisor so SIGTERM (redeploy) reaches the wrapper and the
# background jobs. update-models watches models.md under the state dir.
# r2-sync, when R2_BUCKET is set, needs the signal so it can run a final sync
# before exit.
gosu openclaw /app/bin/update-models --watch "${OPENCLAW_STATE_DIR:-/data/.openclaw}/workspace/models.md" &
MODELS_PID=$!

SYNC_PID=""
if [ -n "${R2_BUCKET:-}" ]; then
  gosu openclaw /app/bin/r2-sync &
  SYNC_PID=$!
fi

gosu openclaw node src/server.js &
APP_PID=$!

trap 'kill -TERM "$APP_PID" 2>/dev/null || true' TERM INT

APP_CODE=0
while kill -0 "$APP_PID" 2>/dev/null; do
  wait "$APP_PID" && APP_CODE=0 || APP_CODE=$?
done

kill -TERM "$MODELS_PID" 2>/dev/null || true
if [ -n "$SYNC_PID" ]; then
  kill -TERM "$SYNC_PID" 2>/dev/null || true
fi
wait "$MODELS_PID" 2>/dev/null || true
if [ -n "$SYNC_PID" ]; then
  wait "$SYNC_PID" 2>/dev/null || true
fi
exit "$APP_CODE"
