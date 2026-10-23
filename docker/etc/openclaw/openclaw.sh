# /app/bin and Homebrew on PATH, plus the `cdw` alias.
# Installed as /home/openclaw/openclaw.sh. Login bash and the console zsh
# both source this file. /etc/profile rebuilds PATH, so these directories
# are prepended again here.
for d in /home/linuxbrew/.linuxbrew/sbin /home/linuxbrew/.linuxbrew/bin /app/bin; do
  case ":$PATH:" in
    *":$d:"*) ;;
    *) PATH="$d:$PATH" ;;
  esac
done
export PATH
alias cdw='cd "${OPENCLAW_WORKSPACE_DIR:-${OPENCLAW_STATE_DIR:-/data/.openclaw}/workspace}"'
