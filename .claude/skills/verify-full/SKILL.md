---
description: Run the full Innigkeit verification gate (check + host tests + QEMU suites) and report results. Slow; invoke explicitly before handing over a patch or after kernel/arch changes.
disable-model-invocation: true
argument-hint: [-Darm=true] [-Dcpus=1] [-Dtpm=true] [-Dsecboot=true]
---

!`zig build verify ${ARGUMENTS:-} --summary all 2>&1 | tail -50`

Report each stage (PASS/FAIL). If anything failed:
1. Identify which stage and which specific test(s) failed.
2. Show the relevant failure lines from the output above.
3. If it's a QEMU environment issue (not a code regression), say so explicitly.

For a compile-only check (no boot), run `zig build check` instead.

Counts to compare against: `docs/test-baselines.md`.
