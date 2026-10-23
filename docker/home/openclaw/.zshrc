# Interactive zsh for the openclaw user. Installed as /home/openclaw/.zshrc.
# The Railway console enters it from zz-openclaw-console.sh. `exit` returns
# to root bash. `resource` (alias below) sources this file again.

[ -r /etc/profile.d/container-env.sh ] && . /etc/profile.d/container-env.sh
[ -r /home/openclaw/openclaw.sh ] && . /home/openclaw/openclaw.sh

if [[ -o interactive ]] && [[ -z ${OPENCLAW_ZSH_INIT:-} ]]; then
  export OPENCLAW_ZSH_INIT=1
  _openclaw_state_dir=${OPENCLAW_STATE_DIR:-/data/.openclaw}
  if [[ -d "$_openclaw_state_dir" ]]; then
    cd -- "$_openclaw_state_dir" || true
  fi
  unset _openclaw_state_dir
fi

# Oh My Zsh git plugin: gst, gco, and the rest of that alias set.
# `local` in the plugin is only valid inside a function. compdef is completion.
if [[ -r /home/openclaw/git.plugin.zsh ]]; then
  __git_prompt_git() { GIT_OPTIONAL_LOCKS=0 command git "$@"; }
  git_current_branch() {
    local ref
    ref=$(__git_prompt_git symbolic-ref --quiet HEAD 2>/dev/null)
    local ret=$?
    if [[ $ret != 0 ]]; then
      [[ $ret == 128 ]] && return
      ref=$(__git_prompt_git rev-parse --short HEAD 2>/dev/null) || return
    fi
    echo ${ref#refs/heads/}
  }
  _openclaw_load_git_plugin() {
    compdef() { :; }
    . /home/openclaw/git.plugin.zsh
  }
  _openclaw_load_git_plugin
  unfunction _openclaw_load_git_plugin compdef
fi

# Copied from ~/projects/startup/aliases. `complete` is bash-only, and
# `unalias` of a name that is not an alias prints an error under zsh.
# Loaded after the git plugin so gb and gcb stay these functions.
if [[ -r /home/openclaw/.aliases ]]; then
  complete() { :; }
  # `command unalias` still calls this function. `builtin` reaches the real one,
  # which is what removes the git plugin's gb and gcb aliases.
  unalias() { builtin unalias "$@" 2>/dev/null || true; }
  . /home/openclaw/.aliases
  unfunction complete unalias
fi

# `cdw` is a function so it runs in this zsh. The profile alias is removed
# first; an alias would be expanded in its place.
unalias cdw 2>/dev/null || true
cdw() {
  local dest=${OPENCLAW_WORKSPACE_DIR:-}
  [[ -n $dest ]] || dest=${OPENCLAW_STATE_DIR:-/data/.openclaw}/workspace
  cd -- "$dest"
}

# kolo-custom colors: green path, magenta git state, % prompt.
# `%#` stays `%` in this shell and `#` in the root bash after `exit`.
autoload -Uz vcs_info add-zsh-hook
zstyle ':vcs_info:*' stagedstr '%F{green}●'
zstyle ':vcs_info:*' unstagedstr '%F{yellow}●'
zstyle ':vcs_info:*' check-for-changes true
zstyle ':vcs_info:*' enable git

_openclaw_precmd() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
    && [[ -n $(git ls-files --other --exclude-standard 2>/dev/null) ]]; then
    zstyle ':vcs_info:*' formats ' [%b%c%u%F{red}●%F{magenta}]'
  else
    zstyle ':vcs_info:*' formats ' [%b%c%u%F{magenta}]'
  fi
  vcs_info
}
if [[ -z ${_openclaw_prompt:-} ]]; then
  _openclaw_prompt=1
  add-zsh-hook precmd _openclaw_precmd
fi

setopt prompt_subst
PROMPT='%B%F{green}%n:%~%b%f%B%F{magenta}${vcs_info_msg_0_}%b%f %# '

# GNU ls color database. dircolors prints the commands that set LS_COLORS.
if command -v dircolors >/dev/null 2>&1; then
  eval "$(dircolors -b)"
fi
alias ls='ls --color=auto'
