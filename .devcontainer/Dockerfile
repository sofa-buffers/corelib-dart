FROM ubuntu:26.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/opt/dart/bin:/root/.pub-cache/bin:$PATH

# Base tooling.
#   valgrind — required by bench/run_callgrind.sh (Callgrind Ir/op instruction
#              cost tool, BENCH_SPEC).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    unzip \
    gnupg \
    jq \
    valgrind \
    && rm -rf /var/lib/apt/lists/*

# Dart SDK (pinned; also used by CI)
ARG DART_VERSION=3.12.2
RUN case "$(uname -m)" in \
      x86_64) DART_ARCH=x64 ;; \
      aarch64) DART_ARCH=arm64 ;; \
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;; \
    esac \
    && curl -fsSL "https://storage.googleapis.com/dart-archive/channels/stable/release/${DART_VERSION}/sdk/dartsdk-linux-${DART_ARCH}-release.zip" -o /tmp/dartsdk.zip \
    && unzip -q /tmp/dartsdk.zip -d /opt \
    && mv /opt/dart-sdk /opt/dart \
    && rm /tmp/dartsdk.zip \
    && dart --version

# Node.js (LTS) for Claude Code
RUN curl -fsSL https://deb.nodesource.com/setup_lts.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Claude Code
RUN npm install -g @anthropic-ai/claude-code

# GitHub CLI (gh) — installed from GitHub's official apt repository
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
       -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
       > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

CMD ["/bin/bash"]
