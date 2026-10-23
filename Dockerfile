FROM node:26-bookworm

RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gh \
    git \
    gosu \
    openssh-client \
    inotify-tools \
    procps \
    python3 \
    python3-pip \
    tini \
    build-essential \
    zip \
    unzip \
    zsh \
  && python3 --version | grep -Eq '^Python 3\.11\.' \
  && rm -rf /var/lib/apt/lists/*

# Default interpreter is Bookworm python3. Add packages in requirements.txt.
COPY requirements.txt /tmp/requirements.txt
RUN pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt \
  && rm /tmp/requirements.txt \
  && python3 -c 'import click, pydantic, pydantic_settings, requests'

RUN npm install -g \
    --allow-scripts=openclaw \
    openclaw@2026.9.7 \
  && node --version | grep -Eq '^v26\.' \
  && openclaw --version | grep -Eq '^OpenClaw 2026\.9\.7( |$)'

# Same release as OpenClaw. An unpinned spec resolves the newest ClawHub
# build, and that build requires a newer plugin API than 2026.9.7.
# The Railway volume hides /data, so this seed stays in the image.
# entrypoint.sh copies npm/projects onto $OPENCLAW_STATE_DIR.
RUN mkdir -p /opt/openclaw-plugin-seed \
  && OPENCLAW_STATE_DIR=/opt/openclaw-plugin-seed \
     openclaw plugins install @openclaw/deepinfra-provider@2026.9.7 \
  && OPENCLAW_STATE_DIR=/opt/openclaw-plugin-seed \
     openclaw plugins install @openclaw/groq-provider@2026.9.7 \
  && OPENCLAW_STATE_DIR=/opt/openclaw-plugin-seed \
     openclaw plugins install @openclaw/perplexity-plugin@2026.9.7 \
  && OPENCLAW_STATE_DIR=/opt/openclaw-plugin-seed \
     openclaw plugins install @openclaw/duckduckgo-plugin@2026.9.7 \
  && printf '%s\n' \
    '@openclaw/deepinfra-provider@2026.9.7' \
    '@openclaw/groq-provider@2026.9.7' \
    '@openclaw/perplexity-plugin@2026.9.7' \
    '@openclaw/duckduckgo-plugin@2026.9.7' \
    > /opt/openclaw-plugin-seed/STAMP \
  && find /opt/openclaw-plugin-seed -mindepth 1 -maxdepth 1 \
    ! -name npm ! -name STAMP -exec rm -rf {} + \
  && rm -rf /opt/openclaw-plugin-seed/npm/projects/.openclaw-install-stage-*

RUN npm install -g clawhub@latest

# rclone (pinned) for optional R2 workspace sync; apt's version is too old for bisync
ARG RCLONE_RELEASE=v1.75.1
RUN ARCH="$(dpkg --print-architecture)" \
  && curl -fsSL -o /tmp/rclone.zip "https://downloads.rclone.org/${RCLONE_RELEASE}/rclone-${RCLONE_RELEASE}-linux-${ARCH}.zip" \
  && unzip -q /tmp/rclone.zip -d /tmp \
  && install -m 755 /tmp/rclone-${RCLONE_RELEASE}-linux-${ARCH}/rclone /usr/local/bin/rclone \
  && rm -rf /tmp/rclone* \
  && rclone version

WORKDIR /app

COPY package.json pnpm-lock.yaml ./
RUN npm install -g pnpm@11.24.0 \
  && pnpm install --frozen-lockfile --prod

COPY src ./src
COPY --chmod=755 entrypoint.sh ./entrypoint.sh
COPY --chmod=755 bin ./bin

# Tool plugin wrapping bin/ as typed agent tools. Enable it with:
#   openclaw config set --json plugins.load.paths '["/app/plugins/ops-tools"]'
# openclaw is a peer and is not in the lockfile. Link the global install so the
# build uses the same SDK as the gateway. pnpm prune drops that link.
COPY plugins ./plugins
RUN cd plugins/ops-tools \
  && pnpm install --frozen-lockfile \
  && ln -sfn /usr/local/lib/node_modules/openclaw node_modules/openclaw \
  && pnpm run build \
  && pnpm prune --prod \
  && ln -sfn /usr/local/lib/node_modules/openclaw node_modules/openclaw

COPY --chmod=644 docker/etc/profile.d/ /etc/profile.d/
COPY --chmod=644 docker/etc/ssh/ssh_config.d/github.conf /etc/ssh/ssh_config.d/github.conf
COPY docker/etc/bash.bashrc.d/openclaw.sh /tmp/openclaw-bashrc
# --chmod=644 applies to directories the copy creates. These directories
# already exist; restore search permission in case the copy changed it.
RUN cat /tmp/openclaw-bashrc >> /etc/bash.bashrc && rm /tmp/openclaw-bashrc \
  && chmod 755 /etc/profile.d /etc/ssh/ssh_config.d \
  && printf '\n# Railway console: enter the openclaw zsh. See zz-openclaw-console.sh.\n[ -r /etc/profile.d/zz-openclaw-console.sh ] && . /etc/profile.d/zz-openclaw-console.sh\n' >> /root/.bashrc

# ~/.openclaw and ~/.ssh follow the volume so CLI sessions, the default state
# dir, and the GitHub key pair share one persistent directory. The mount hides
# /data at runtime; entrypoint recreates the targets and the ~/.ssh link.
#
# /app stays root-owned and not writable. Removing write on bin/ and plugins/
# alone is not enough: deleting or replacing those directories only needs write
# permission on /app. The wrapper only writes under /data.
# Interactive root bash (the Railway console) sources zz-openclaw-console.sh
# and drops into this user's zsh. `exit` there returns to root bash.
RUN useradd -m -s /bin/zsh openclaw \
  && chown -R root:root /app \
  && chmod -R a-w /app \
  && mkdir -p /data/.openclaw/ssh \
  && chmod 700 /data/.openclaw/ssh \
  && chown openclaw:openclaw /data /data/.openclaw /data/.openclaw/ssh \
  && ln -sfn /data/.openclaw /home/openclaw/.openclaw \
  && ln -sfn /data/.openclaw/ssh /home/openclaw/.ssh \
  && chown -h openclaw:openclaw /home/openclaw/.openclaw /home/openclaw/.ssh \
  && mkdir -p /home/linuxbrew/.linuxbrew && chown -R openclaw:openclaw /home/linuxbrew

# docker/home/openclaw mirrors /home/openclaw. Do not --chmod the copy:
# that mode is applied to directories too, and 644 is not traversable.
COPY --chown=openclaw:openclaw docker/home/openclaw/ /home/openclaw/
RUN chmod 755 /home/openclaw \
  && chmod 644 \
    /home/openclaw/.zshrc \
    /home/openclaw/.aliases \
    /home/openclaw/openclaw.sh \
    /home/openclaw/git.plugin.zsh \
    /home/openclaw/git.plugin.LICENSE

USER openclaw
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

ENV PATH="/app/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"
ENV HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
ENV HOMEBREW_CELLAR="/home/linuxbrew/.linuxbrew/Cellar"
ENV HOMEBREW_REPOSITORY="/home/linuxbrew/.linuxbrew/Homebrew"

# Interactive sh reads $ENV. The console script turns that sh into bash,
# then enters the openclaw zsh. Non-interactive sh ignores it.
ENV ENV=/etc/profile.d/zz-openclaw-console.sh

ENV PORT=8080
ENV OPENCLAW_ENTRY=/usr/local/lib/node_modules/openclaw/dist/entry.js
ENV OPENCLAW_SUPERVISOR_MODE=external
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -f http://localhost:8080/setup/healthz || exit 1

USER root
ENTRYPOINT ["tini", "--", "./entrypoint.sh"]
