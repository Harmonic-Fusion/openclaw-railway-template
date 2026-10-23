# Railway's console is an interactive root shell. Drop into the openclaw
# user's zsh, with the working directory set to OPENCLAW_STATE_DIR.
# Exiting that zsh returns to root bash. If the console was sh, it is
# replaced with bash first so that return shell is bash.

if [ -n "${OPENCLAW_CONSOLE_ENTERED:-}" ]; then
  return 0
fi

case $- in
  *i*) ;;
  *) return 0 ;;
esac

# Skip non-console shells (scripts, `bash -lc`). Railway allocates a tty.
[ -t 0 ] || return 0
[ "$(id -u)" -eq 0 ] || return 0

# Railway uses bash when the image has it, and sh otherwise. `exit` from the
# openclaw zsh should land in bash, so replace an interactive root sh first.
# The new bash sources this file again and continues below.
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash -i
fi

if command -v gosu >/dev/null 2>&1; then
  _openclaw_gosu=$(command -v gosu)
elif [ -x /usr/sbin/gosu ]; then
  _openclaw_gosu=/usr/sbin/gosu
else
  return 0
fi

_openclaw_zsh=$(command -v zsh 2>/dev/null || true)
if [ -z "$_openclaw_zsh" ]; then
  unset _openclaw_gosu
  return 0
fi

export OPENCLAW_CONSOLE_ENTERED=1

if [ -r /etc/profile.d/container-env.sh ]; then
  # shellcheck disable=SC1091
  . /etc/profile.d/container-env.sh
fi
if [ -r /etc/profile.d/openclaw.sh ]; then
  # shellcheck disable=SC1091
  . /etc/profile.d/openclaw.sh
fi

_openclaw_console_dir=${OPENCLAW_STATE_DIR:-/data/.openclaw}
(
  if [ -d "$_openclaw_console_dir" ]; then
    cd "$_openclaw_console_dir" || true
  fi
  # -u so the nested zsh does not inherit the guard. This root shell keeps
  # it, so a later bashrc source does not enter zsh a second time.
  # -i forces an interactive zsh, which reads ~/.zshrc and defines `cdw`.
  exec "$_openclaw_gosu" openclaw env -u OPENCLAW_CONSOLE_ENTERED \
    HOME=/home/openclaw \
    USER=openclaw \
    LOGNAME=openclaw \
    SHELL="$_openclaw_zsh" \
    "$_openclaw_zsh" -i
) || true

unset _openclaw_gosu _openclaw_zsh _openclaw_console_dir
