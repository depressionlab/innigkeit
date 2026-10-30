#!/usr/bin/env bash
# Stop: if .zig files have uncommitted changes, `zig build check` must pass before
# the turn can end. Fast (compile-only); the QEMU suites stay in /verify-full.
# Exit 2 hands the compiler output back to Claude. Claude Code caps consecutive
# blocks, so a genuinely broken tree cannot loop forever.
. "$(dirname "$0")/_env.sh"
command -v zig >/dev/null || exit 0
if ! git status --porcelain -- '*.zig' 'build.zig.zon' | grep -q .; then
    exit 0
fi
if ! out=$(zig build check 2>&1); then
    echo "zig build check failed; fix before finishing:" >&2
    echo "$out" | tail -40 >&2
    exit 2
fi
