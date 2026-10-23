# Login shells (`su -`, login zsh) start with a clean environment. The
# entrypoint saves the container environment to /run/container.env;
# /proc/1/environ is root-only. Interactive non-login bash sources this
# file from /etc/bash.bashrc. The openclaw zsh sources it too.
if [ -z "${BASH_VERSION:-}" ] && [ -z "${ZSH_VERSION:-}" ]; then
  return 0
fi

_load_container_env() {
  local file=/run/container.env entry name value
  [ -r "$file" ] || return 0
  while IFS= read -r -d '' entry || [ -n "$entry" ]; do
    case "$entry" in
      *=*) ;;
      *) continue ;;
    esac
    name=${entry%%=*}
    case "$name" in
      HOME|USER|LOGNAME|SHELL|PWD|OLDPWD|SHLVL|_|TERM|UID|EUID|PPID) continue ;;
      [A-Za-z_]*) ;;
      *) continue ;;
    esac
    case "$name" in
      *[!A-Za-z0-9_]*) continue ;;
    esac
    value=${entry#*=}
    export "$name=$value"
  done < "$file"
}
_load_container_env
unset -f _load_container_env
