---
description: Run the full Innigkeit verification gate and report results. Use when asked to verify, check, test, or validate the tree.
argument-hint: [-Darm=true] [-Dcpus=1] [-Dtpm=true] [-Dsecboot=true]
---

!`zig build verify ${ARGUMENTS:-} --summary all 2>&1 | tail -50`

Report each stage (PASS/FAIL). If anything failed:
1. Identify which stage and which specific test(s) failed.
2. Show the relevant failure lines from the output above.
3. If it's a QEMU environment issue (not a code regression), say so explicitly.

For a compile-only check (no boot), run `zig build check` instead.

Baseline to compare against: x64 138/138, arm 98 (+13 skipped), host test_native 63.
