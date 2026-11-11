FROM docker.io/library/node:26-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      openssh-client \
      less \
      jq \
      make \
      unzip \
      fzf \
      vim \
      just \
      procps \
      python3 \
      python3-pip \
      python3-venv \
  && rm -rf /var/lib/apt/lists/*

# uv, from its official image. Debian's python3 refuses a global `pip install` (PEP 668),
# so use `uv` (or a venv) to install Python packages and tools.
ARG UV_VERSION=latest
COPY --from=ghcr.io/astral-sh/uv:${UV_VERSION} /uv /uvx /usr/local/bin/

# Go, pinned via build arg or resolved at build time with "latest".
ARG GO_VERSION=latest
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    ver="$GO_VERSION"; \
    if [ "$ver" = "latest" ]; then ver="$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)"; fi; \
    case "$ver" in go*) ;; *) ver="go$ver" ;; esac; \
    curl -fsSL "https://go.dev/dl/${ver}.linux-${arch}.tar.gz" -o /tmp/go.tgz; \
    tar -C /usr/local -xzf /tmp/go.tgz; \
    rm /tmp/go.tgz /usr/local/go/test /usr/local/go/api -rf; \
    /usr/local/go/bin/go version

ARG WIKI_VERSION=v0.17.0
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    mkdir -p /tmp/wiki && cd /tmp/wiki && \
    curl -fsSL -O "https://github.com/agentic-wiki/wiki/releases/download/${WIKI_VERSION}/wiki_linux_${arch}.tar.gz" && \
    tar xfz "wiki_linux_${arch}.tar.gz" && \
    mv ./wiki /usr/local/bin && \
    cd .. && \
    rm -Rf /tmp/wiki

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global \
    GOPATH=/home/node/go \
    DENO_INSTALL=/home/node/.deno \
    BUN_INSTALL=/home/node/.bun \
    PATH=/usr/local/share/npm-global/bin:/usr/local/go/bin:/home/node/go/bin:/home/node/.foundry/bin:/home/node/.deno/bin:/home/node/.bun/bin:/home/node/.local/bin:$PATH \
    DEVCONTAINER=true

# The harness config dirs are bind-mounted over these; they exist so they're owned by node.
RUN mkdir -p /usr/local/share/npm-global /home/node/.claude /home/node/.codex \
  && chown -R node:node /usr/local/share/npm-global /home/node/.claude /home/node/.codex

USER node

RUN curl -fsSL https://bun.sh/install | bash
RUN curl -fsSL https://deno.land/install.sh | sh -s -- -y

ARG FOUNDRY_VERSION=1.7.1
# Foundry (forge, cast, anvil, chisel). foundryup keeps a second copy of every
# binary under versions/; hardlinking them together saves ~220 MB.
RUN curl -fsSL https://foundry.paradigm.xyz | bash \
  && /home/node/.foundry/bin/foundryup --install ${FOUNDRY_VERSION} \
  && for f in /home/node/.foundry/versions/*/*; do \
       if [ -f "$f" ]; then ln -f "$f" "/home/node/.foundry/bin/$(basename "$f")"; fi; \
     done

# The harnesses go last, because they move fastest: a version bump reuses every layer
# above. One layer each, so bumping one doesn't reinstall the other.
ARG CODEX_VERSION=latest
RUN npm install -g @openai/codex@${CODEX_VERSION} \
  && npm cache clean --force

ARG CLAUDE_CODE_VERSION=latest
RUN npm install -g @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
  && npm cache clean --force

RUN forge --version && deno --version && bun --version && go version && wiki --version \
  && python3 --version && uv --version && codex --version && claude --version

# The command is exactly what you pass; with none, a shell. The launchers bind-mount
# each project at its host path and pass a matching --workdir.
ENTRYPOINT []
CMD ["bash"]
