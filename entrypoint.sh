#!/bin/bash
set -e

# /proc/1/environ is root-only. Login shells source
# /etc/profile.d/container-env.sh, which reads this copy.
mkdir -p /run
cat /proc/self/environ > /run/container.env
chmod 644 /run/container.env

# State and the GitHub key live on the volume. ~/.ssh for both root and the
# openclaw user is a link to <state>/ssh, so the console zsh (HOME is
# /home/openclaw) and the root bash after `exit` see the same keys.
state="${OPENCLAW_STATE_DIR:-/data/.openclaw}"
ssh_dir="$state/ssh"
mkdir -p "$ssh_dir"
chown -R openclaw:openclaw /data "$state"
chmod 700 /data "$ssh_dir"

# Point a home .ssh at the volume key directory. Copy keys out of a real
# directory, or out of a symlink that already points somewhere else, before
# replacing it. `ln -sfn` alone leaves a real directory in place and creates
# the link inside it. Existing volume keys are left as they are.
copy_ssh_missing() {
  local src="$1" dest="$2" f base
  for f in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [ -e "$f" ] || continue
    base=$(basename "$f")
    if [ ! -e "$dest/$base" ]; then
      cp -a "$f" "$dest/$base"
    fi
  done
}
link_ssh_home() {
  local link="$1" dest="$2" owner="${3:-}" current="" dest_real=""
  mkdir -p "$dest"
  dest_real=$(readlink -f "$dest" 2>/dev/null || true)
  if [ -L "$link" ]; then
    current=$(readlink -f "$link" 2>/dev/null || true)
  fi
  if [ -n "$current" ] && [ "$current" != "$dest_real" ] && [ -d "$current" ]; then
    copy_ssh_missing "$current" "$dest"
  elif [ -d "$link" ] && [ ! -L "$link" ]; then
    copy_ssh_missing "$link" "$dest"
    rm -rf "$link"
  elif [ -e "$link" ] && [ ! -L "$link" ]; then
    rm -f "$link"
  fi
  ln -sfn "$dest" "$link"
  if [ -n "$owner" ]; then
    chown -h "$owner:$owner" "$link"
  fi
}

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

link_ssh_home /home/openclaw/.ssh "$ssh_dir" openclaw
link_ssh_home /root/.ssh "$ssh_dir"
# A real ~/.openclaw directory is state the volume does not have yet. Leave it.
if [ -L /home/openclaw/.openclaw ] || [ ! -e /home/openclaw/.openclaw ]; then
  ln -sfn "$state" /home/openclaw/.openclaw
  chown -h openclaw:openclaw /home/openclaw/.openclaw
fi
chown -R openclaw:openclaw "$ssh_dir"
chmod 700 "$ssh_dir"
find "$ssh_dir" -type f \( -name github -o -name 'id_*' \) ! -name '*.pub' -exec chmod 600 {} +
find "$ssh_dir" -type f -name '*.pub' -exec chmod 644 {} +
# Absolute path so github.com does not depend on which home ssh expands.
cat > /etc/ssh/ssh_config.d/github.conf << EOF
Host github.com
  User git
  IdentityFile ${ssh_dir}/github
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
EOF
chmod 644 /etc/ssh/ssh_config.d/github.conf

if [ ! -d /data/.linuxbrew ]; then
  cp -a /home/linuxbrew/.linuxbrew /data/.linuxbrew
fi

rm -rf /home/linuxbrew/.linuxbrew
ln -sfn /data/.linuxbrew /home/linuxbrew/.linuxbrew

# Stay as the supervisor so SIGTERM (redeploy) reaches the wrapper and the
# background jobs. update-models watches models.md under the state dir.
# r2-sync, when R2_BUCKET is set, needs the signal so it can run a final sync
# before exit.
gosu openclaw env HOME=/home/openclaw USER=openclaw LOGNAME=openclaw \
  /app/bin/update-models --watch "${state}/workspace/models.md" &
MODELS_PID=$!

SYNC_PID=""
if [ -n "${R2_BUCKET:-}" ]; then
  gosu openclaw env HOME=/home/openclaw USER=openclaw LOGNAME=openclaw \
    /app/bin/r2-sync &
  SYNC_PID=$!
fi

gosu openclaw env HOME=/home/openclaw USER=openclaw LOGNAME=openclaw \
  node src/server.js &
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
