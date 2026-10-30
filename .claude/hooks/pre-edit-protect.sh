#!/usr/bin/env bash
# PreToolUse (Edit|Write): files with zero legitimate hand-edits. Blocks (exit 2)
# instead of relying on a CLAUDE.md sentence.
#   keys/        codesign keypair; regenerate with `zig build codesign -- keygen`
#   zig-pkg/     vendored dependencies (the package cache)
#   zig-out/ .zig-cache/ .tools/   build outputs and provisioned toolchain
#   *.codesig    generated signatures
command -v jq >/dev/null || exit 0
f=$(jq -r '.tool_input.file_path // empty')
[ -n "$f" ] || exit 0
root="${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
rel="${f#"$root"/}"
case "$rel" in
    keys/* | zig-pkg/* | zig-out/* | .zig-cache/* | .tools/* | *.codesig)
        echo "Blocked: $rel is generated, vendored, or a secret and is never edited by hand. Regenerate it with the build instead (see CLAUDE.md > Setup)." >&2
        exit 2
        ;;
esac
