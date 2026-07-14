#!/usr/bin/env bash
# Innigkeit cloud-environment Setup script (and local bootstrap).
#
# WHY THIS EXISTS, AND WHY IT IS NOT JUST the SessionStart hook:
# On Claude Code on the web a fresh container starts UNTRUSTED, and everything
# that lives in the repo (e.g., SessionStart hooks AND project-scope plugins under
# .claude/skills) is gated behind workspace trust. So the in-repo provisioning
# hook never runs and the zig-lsp plugin never loads until a human accepts the
# trust dialog. The two surfaces that run OUTSIDE the trust gate are the cloud
# environment's *Setup script* (cached in the filesystem snapshot, runs before
# Claude launches) and *environment variables*. User-scope plugins
# (~/.claude/skills/<name>) also load without project trust.
#
# Point the environment's "Setup script" field at this file:
#     bash <repo-clone-path>/scripts/cloud-setup.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

log() { printf '[cloud-setup] %s\n' "$*"; }

# 1. Provision the toolchain (Zig, ZLS, QEMU+AAVMF, Zig package cache, codesign
#    keypair, Rust target, zls PATH/symlink). The SessionStart hook is the
#    single source of truth for that logic; invoke it with the env it expects.
log "provisioning toolchain via session-start hook"
CLAUDE_CODE_REMOTE=true CLAUDE_PROJECT_DIR="$REPO" bash .claude/hooks/session-start.sh

# 2. Load the ZLS code-intelligence plugin at USER scope. The identical plugin
#    lives in-repo at .claude/skills/zig-lsp, but project-scope plugins are
#    trust-gated; ~/.claude/skills/<name> is not. Copying it here makes the
#    native LSP tool (goToDefinition / findReferences / hover / documentSymbol /
#    call-hierarchy) available in every session without the trust dialog.
log "installing zig-lsp plugin at user scope"
mkdir -p "$HOME/.claude/skills"
rm -rf "$HOME/.claude/skills/zig-lsp"
cp -r "$REPO/.claude/skills/zig-lsp" "$HOME/.claude/skills/zig-lsp"

# 3. Put the toolchain on PATH for every session shell. Written to
#    /etc/profile.d so it survives in the cached snapshot and is picked up by
#    login shells. (ZLS itself also resolves via the /usr/local/bin/zls symlink
#    the hook creates, so the LSP server works regardless of this.)
log "adding toolchain to PATH via /etc/profile.d"
cat > /etc/profile.d/innigkeit-zig.sh <<EOF
export PATH="$REPO/.tools/zig-0.16.0:$REPO/.tools/zls:\$PATH"
EOF

log "ready: zig/zls on PATH, zig-lsp loaded at user scope, gate tools provisioned"
