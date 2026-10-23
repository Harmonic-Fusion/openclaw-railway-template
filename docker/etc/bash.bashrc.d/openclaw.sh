# Interactive non-login shells do not read /etc/profile.
[ -r /etc/profile.d/container-env.sh ] && . /etc/profile.d/container-env.sh
[ -r /home/openclaw/openclaw.sh ] && . /home/openclaw/openclaw.sh
# After the profile snippets: a Railway console (root bash) enters openclaw zsh.
[ -r /etc/profile.d/zz-openclaw-console.sh ] && . /etc/profile.d/zz-openclaw-console.sh
