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
    tini \
    build-essential \
    zip \
    unzip \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g \
    --allow-scripts=openclaw \
    openclaw@2026.9.7 \
  && node --version | grep -Eq '^v26\.' \
  && openclaw --version | grep -Eq '^OpenClaw 2026\.9\.7( |$)'
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
RUN cat /tmp/openclaw-bashrc >> /etc/bash.bashrc && rm /tmp/openclaw-bashrc

# ~/.openclaw and ~/.ssh follow the volume so CLI sessions, the default state
# dir, and the GitHub key pair share one persistent directory. The mount hides
# /data at runtime; entrypoint recreates the targets and the ~/.ssh link.
#
# /app stays root-owned and not writable. Removing write on bin/ and plugins/
# alone is not enough: deleting or replacing those directories only needs write
# permission on /app. The wrapper only writes under /data.
RUN useradd -m -s /bin/bash openclaw \
  && chown -R root:root /app \
  && chmod -R a-w /app \
  && mkdir -p /data/.openclaw/ssh \
  && chmod 700 /data/.openclaw/ssh \
  && chown openclaw:openclaw /data /data/.openclaw /data/.openclaw/ssh \
  && ln -sfn /data/.openclaw /home/openclaw/.openclaw \
  && ln -sfn /data/.openclaw/ssh /home/openclaw/.ssh \
  && chown -h openclaw:openclaw /home/openclaw/.openclaw /home/openclaw/.ssh \
  && mkdir -p /home/linuxbrew/.linuxbrew && chown -R openclaw:openclaw /home/linuxbrew

USER openclaw
RUN NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

ENV PATH="/app/bin:/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:${PATH}"
ENV HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
ENV HOMEBREW_CELLAR="/home/linuxbrew/.linuxbrew/Cellar"
ENV HOMEBREW_REPOSITORY="/home/linuxbrew/.linuxbrew/Homebrew"

ENV PORT=8080
ENV OPENCLAW_ENTRY=/usr/local/lib/node_modules/openclaw/dist/entry.js
ENV OPENCLAW_SUPERVISOR_MODE=external
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s \
  CMD curl -f http://localhost:8080/setup/healthz || exit 1

USER root
ENTRYPOINT ["tini", "--", "./entrypoint.sh"]
