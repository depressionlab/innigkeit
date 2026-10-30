---
description: Fast pre-commit check for Innigkeit (compile check, formatting, host tests). Use before committing code changes; for the full QEMU gate use verify-full.
---

!`zig fmt --check --ast-check apps build build.zig build.zig.zon library sdk src testing tools 2>&1 | tail -20; zig build check --summary all 2>&1 | tail -30; zig build test_native --summary all 2>&1 | tail -15`

Report PASS/FAIL for formatting, `check`, and `test_native`. If anything failed, show the first relevant error lines and fix them.

This does **not** boot QEMU and `check` does not validate inline assembly. After touching arch `asm`, kernel behaviour, or anything the x64/arm suites exercise, run `verify-full` (or `zig build build_all` for asm-only changes).
