# wt session container — one per wt session, hard-capped at run time.
# Ubuntu + git/bun/node + Claude Code + tmux + Chrome (headless AND headful via
# Xvfb/noVNC). Nothing repo-specific is baked in: the worktree, the .env files
# and the conversation all arrive at run time on a volume.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=America/Los_Angeles

# --- base toolchain -------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg git openssh-client rsync \
        tmux ripgrep jq less vim-tiny procps psmisc unzip zip \
        python3 python3-venv build-essential sudo locales zsh \
    && rm -rf /var/lib/apt/lists/*

# --- node (Claude Code runtime) ------------------------------------------
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# --- chrome: headless driving + headful viewing ---------------------------
# Playwright pulls the browser and every shared library it needs; Xvfb and
# noVNC turn the same binary into a browser you can watch over the tailnet.
RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb x11vnc novnc websockify fonts-liberation \
    && rm -rf /var/lib/apt/lists/*

# --- unprivileged user ----------------------------------------------------
# UID/GID MUST match the host account that owns the bind-mounted worktree, or
# the container cannot write to /work. csetup passes the host's real ids.
ARG UID=1000
ARG GID=1000
RUN userdel -r ubuntu 2>/dev/null || true; \
    groupadd -g ${GID} dev 2>/dev/null || true; \
    useradd -m -u ${UID} -g ${GID} -s /bin/bash dev; \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev

# mount points must exist and be owned before dropping privileges — only root
# can create directories at /
# /work  = the worktree · /state = ~/.claude + chrome profile (both bind-mounted)
RUN mkdir -p /work /state/claude /state/chrome-profile \
    && chown -R ${UID}:${GID} /work /state
USER dev
WORKDIR /home/dev
ENV PATH=/home/dev/.bun/bin:/home/dev/.local/bin:/home/dev/.npm-global/bin:$PATH

# --- bun + claude code + playwright chromium ------------------------------
RUN curl -fsSL https://bun.sh/install | bash
RUN npm config set prefix /home/dev/.npm-global \
    && npm install -g @anthropic-ai/claude-code
# The BROWSERS alone are not enough — an agent needs the playwright package to
# drive them. Installed globally so it works from any worktree, whether or not
# the repo happens to depend on playwright.
# agent-browser gives the agent a CLI (open/snapshot/click/eval) instead of
# making it write throwaway Playwright scripts — far fewer tokens and the
# browser persists between commands. The claude-in-chrome MCP cannot work here:
# it drives a Chrome extension on the user's Mac.
RUN npm install -g agent-browser
RUN npm install -g playwright \
    && npx --yes playwright@latest install chromium \
    && npx --yes playwright@latest install-deps chromium 2>/dev/null || true
ENV NODE_PATH=/home/dev/.npm-global/lib/node_modules

# --- session plumbing -----------------------------------------------------
# ~/.claude lives on the /state mount so the conversation survives a restart.
# No VOLUME declaration: every run bind-mounts these, and VOLUME would leak an
# anonymous volume per container.
RUN ln -sfn /state/claude /home/dev/.claude
WORKDIR /work

# a container has no route to the other sessions; this shim queues outbound
# messages into the shared outbox the hub already polls
COPY --chown=dev:dev wt-shim /usr/local/bin/wt
COPY --chown=dev:dev entrypoint.sh /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
