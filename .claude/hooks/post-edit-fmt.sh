#!/usr/bin/env bash
# PostToolUse (Edit|Write): keep edited .zig files `zig fmt`-clean so formatting
# never depends on the model remembering it. Never blocks; a parse error is
# reported back to Claude as feedback (stderr + exit 2 on PostToolUse = feedback).
. "$(dirname "$0")/_env.sh"
command -v jq >/dev/null || exit 0
f=$(jq -r '.tool_input.file_path // empty')
case "$f" in
    *.zig) ;;
    *) exit 0 ;;
esac
[ -f "$f" ] || exit 0
if ! out=$(zig fmt "$f" 2>&1); then
    echo "zig fmt failed on $f:" >&2
    echo "$out" >&2
    exit 2
fi
