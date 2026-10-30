# Sourced by the other hooks: put the provisioned toolchain on PATH.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 0
export PATH="$PWD/.tools/zig-0.17.0:$PWD/.tools/zls:$PATH"
