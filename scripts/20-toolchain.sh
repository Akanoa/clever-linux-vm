#!/usr/bin/env bash
# Install the coding agents, herdr and the forge CLIs into ~/.local/bin.
#
# There is no root and no package manager on the Clever Cloud linux
# runtime (Exherbo, user `bas`), so everything is user-space. The image
# already ships git, node, bun, rust, python3, tmux, jq, rg, fd and s3cmd.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

mkdir -p "$HOME/.local/bin"
export PATH="$HOME/.local/bin:$HOME/.opencode/bin:$PATH"
# The image's npm prefix (/usr/x86_64-pc-linux-gnu) is not writable.
export npm_config_prefix="$HOME/.local"

install_herdr() {
  have herdr && { log "herdr already present ($(herdr --version))"; return 0; }
  curl -fsSL https://herdr.dev/install.sh | sh
}

install_claude() {
  have claude && { log "claude already present"; return 0; }
  curl -fsSL https://claude.ai/install.sh | bash
}

install_opencode() {
  have opencode && { log "opencode already present"; return 0; }
  curl -fsSL https://opencode.ai/install | bash
}

install_codex() {
  have codex && { log "codex already present"; return 0; }
  npm install -g @openai/codex
}

install_gh() {
  have gh && { log "gh already present"; return 0; }
  local ver tmp
  ver=$(curl -fsSL https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | sed 's/^v//')
  [ -n "$ver" ] && [ "$ver" != "null" ] || { log "could not resolve gh version"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL "https://github.com/cli/cli/releases/download/v${ver}/gh_${ver}_linux_amd64.tar.gz" \
    | tar xz -C "$tmp" || return 1
  install -m 755 "$tmp/gh_${ver}_linux_amd64/bin/gh" "$HOME/.local/bin/gh"
  rm -rf "$tmp"
}

install_glab() {
  have glab && { log "glab already present"; return 0; }
  local ver tmp
  ver=$(curl -fsSL https://gitlab.com/api/v4/projects/gitlab-org%2Fcli/releases/permalink/latest | jq -r .tag_name | sed 's/^v//')
  [ -n "$ver" ] && [ "$ver" != "null" ] || { log "could not resolve glab version"; return 1; }
  tmp=$(mktemp -d)
  curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${ver}/downloads/glab_${ver}_linux_amd64.tar.gz" \
    | tar xz -C "$tmp" || return 1
  install -m 755 "$tmp/bin/glab" "$HOME/.local/bin/glab"
  rm -rf "$tmp"
}

install_helpers() {
  install -m 755 "$APP_HOME/tools/cellar" "$HOME/.local/bin/cellar"
  install -m 755 "$APP_HOME/tools/fleet"  "$HOME/.local/bin/fleet"
}

# Downloads are independent; run them concurrently to keep boot short.
pids=()
for fn in install_herdr install_claude install_opencode install_codex install_gh install_glab; do
  ( step "$fn" "$fn" ) & pids+=($!)
done
for pid in "${pids[@]}"; do wait "$pid"; done

step install_helpers install_helpers || true

log "installed:"
for c in herdr claude opencode codex gh glab cellar fleet; do
  printf '[vm-agent]   %-10s %s\n' "$c" "$(command -v "$c" 2>/dev/null || echo 'MISSING')"
done
