# The vm-agent agent image: one coding agent, containerised.
#
# A fleet VM is a pet - it boots for ~60s installing its toolchain, keeps
# its workspace on an NFS bucket, and is worth reattaching to tomorrow. A
# pod is the opposite: the toolchain is baked in so it starts in seconds,
# nothing on its filesystem is meant to survive, and results leave through
# Cellar rather than through the box. Same agents, same credentials, same
# :8080 API - different lifetime.
#
# Built with the repository root as the context (like dockerd/Dockerfile),
# because it reuses scripts/ and tools/ verbatim: the credential wiring,
# the agent onboarding seeds and the status endpoint are the ones the VMs
# have been running, not a second copy that drifts.
#
#   ./cluster.sh image            build and push to the GitLab registry
#   docker build -f k8s/Dockerfile -t vm-agent-pod .
FROM node:24-bookworm-slim

# Everything the boot scripts assume is already on the linux runtime.
# python3 for the status server and the agent-config seeds, ssh-client for
# the commit key, s3cmd for Cellar, tmux because herdr needs a
# multiplexer, ripgrep/less/procps because agents reach for them.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq less libatomic1 openssh-client procps \
      python3 python3-venv ripgrep s3cmd tar tmux unzip xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*

# codex is the one agent that is an npm package rather than an installer
# writing into $HOME, so it goes in globally, as root, before the user
# switch below.
RUN npm install -g @openai/codex && npm cache clean --force

# gh and glab ship release tarballs; pinned, because an image is rebuilt
# rarely and "whatever was latest that afternoon" is not a version anyone
# can reason about afterwards. Bump them here, deliberately.
ARG GH_VERSION=2.63.2
ARG GLAB_VERSION=1.52.0
RUN set -eux; \
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
      | tar xz -C /tmp; \
    install -m 755 "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" /usr/local/bin/gh; \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_amd64.tar.gz" \
      | tar xz -C /tmp; \
    install -m 755 /tmp/bin/glab /usr/local/bin/glab; \
    rm -rf /tmp/gh_* /tmp/bin

# The boot scripts this image reuses. APP_HOME is what they resolve
# everything else against, exactly as boot.sh sets it on a VM.
ENV APP_HOME=/opt/vm-agent
COPY scripts/ ${APP_HOME}/scripts/
COPY tools/ ${APP_HOME}/tools/
COPY k8s/entrypoint.sh ${APP_HOME}/entrypoint.sh
RUN chmod +x ${APP_HOME}/entrypoint.sh ${APP_HOME}/tools/* \
    && install -m 755 ${APP_HOME}/tools/cellar /usr/local/bin/cellar \
    && install -m 755 ${APP_HOME}/tools/fleet  /usr/local/bin/fleet

# Non-root from here on. A pod has no business running as uid 0, and the
# three agent installers below all write into $HOME - running them as root
# would bake them into /root, where the runtime user cannot reach them.
# 10001 is what the manifests pin runAsUser to; keep the two in step.
RUN useradd --create-home --uid 10001 --shell /bin/bash agent
USER agent
ENV HOME=/home/agent
ENV PATH=/home/agent/.local/bin:/home/agent/.opencode/bin:$PATH
WORKDIR /home/agent

# herdr owns the terminals in pod mode; claude/opencode are the agents.
# Each installer puts its binary under $HOME, which is why this is the
# first layer that has to run as `agent` rather than root.
RUN curl -fsSL https://herdr.dev/install.sh | sh \
    && curl -fsSL https://claude.ai/install.sh | bash \
    && curl -fsSL https://opencode.ai/install | bash

# ripwire - a parsed symbol table and call graph, so an agent dropped into
# an unfamiliar repo has something better than a cold grep. The installer
# refuses to guess its own repo and confirms on /dev/tty, neither of which
# works in a build.
RUN RIPWIRE_REPO=redhat-et/ripwire RIPWIRE_INSTALL_YES=1 \
      bash -c "$(curl -fsSL https://raw.githubusercontent.com/redhat-et/ripwire/main/scripts/install.sh)" \
    || echo "ripwire install failed - continuing without it"

# Fail the build rather than ship an image whose agents are missing: a pod
# that starts and then cannot find `claude` looks like a cluster problem
# for a long time before anyone suspects the image.
RUN set -eux; for c in herdr claude opencode codex gh glab git python3 tmux; do \
      command -v "$c" >/dev/null || { echo "missing from image: $c" >&2; exit 1; }; \
    done

# 8080 is the same status/federation endpoint the VMs serve, so `swarm`
# speaks the protocol `fleet` already speaks. Nothing routes to it from
# outside the cluster - swarm reaches it through `kubectl exec`.
EXPOSE 8080
ENTRYPOINT ["/opt/vm-agent/entrypoint.sh"]
