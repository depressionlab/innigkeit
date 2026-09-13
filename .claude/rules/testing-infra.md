---
paths:
  - "src/innigkeit/testing/**"
---

# Kernel test-infrastructure invariants

Drafted while building the block-device fault-injection seam
(docs/test-system-plan.md §4, fault injection staging step 2), same
convention `.claude/rules/drivers.md`/`filesystem.md`/`network.md`/`arm.md`
established for their subsystems — this file is about the test *harness*
itself, not any one kernel subsystem.

## `std.testing.expectError`/`expectEqual`'s failure path panics this kernel — FOUND, not fixed

Both helpers, when the assertion actually fails, print a diagnostic
("expected X, found Y") via `std.debug.print` before returning the
failure error. In this freestanding kernel that print call panics: it
reaches `std.Io.swapCancelProtection`, which dereferences something this
environment never initializes (a real, hosted-OS assumption `std.Io`
carries that a freestanding kernel doesn't satisfy) — confirmed by
`addr2line` against the actual test kernel ELF, not guessed: the
backtrace resolves cleanly to `Io.swapCancelProtection` ->
`debug.lockStderr` -> `debug.print` -> `testing.print` ->
`testing.expectError`, called from the failing test's own line.

**Consequence: any kernel test whose `expectError`/`expectEqual`
assertion is ever actually false crashes the whole kernel instead of
reporting a clean `FAIL` line.** A bare `std.testing.expect(condition)`
does *not* have this problem — it has nothing to print, so it just
returns `error.TestUnexpectedResult` directly, which the kernel's own
test runner (`testing/runner.zig`) already reports safely (confirmed:
`FAIL testing.checkpoint.test...: error.ProcessTornDownBeforeThread` and
this file's own `FAIL ...: error.WrongErrorReturned` both printed cleanly
with no crash, since neither goes through `std.debug.print`).

This had already been glimpsed once before, in
`testing/fault_injection.test.zig`'s own development (`docs/test-system-
plan.md` §4: "`std.testing.expectEqual`'s failure-reporting path crashed
instead of printing a clean diff... not investigated further") but never
actually root-caused or written down anywhere a future test author would
find it before hitting it themselves. Root-caused for real this pass by
deliberately reproducing it (a probe test with a filename one byte over
`simple_fs`'s 15-char limit made `open()` return `error.InvalidArgument`
instead of the expected `error.IoError`, which should have been a clean,
boring `FAIL` — instead it panicked the guest with a page fault at
`0x50`, in kernel context, identical every time).

**Not fixed**: making `std.debug.print`/`std.Io`'s stdio-locking path
actually work in this freestanding environment is a real, separate
undertaking (implementing or stubbing enough of `std.Io`'s hosted-OS
assumptions), out of scope for the fault-injection work that found it.
**The rule until then**: never call `std.testing.expectError`/
`expectEqual`/`expectEqualSlices` (or `std.debug.print` directly) from
kernel test code where the assertion could genuinely fail at runtime.
Use `std.testing.expect(condition)` (safe, no diagnostic printing) or a
manual `if/else` that reports failure via the kernel's own `log.err` and
a plain returned error — both proven safe throughout this codebase. A
test whose assertion is *provably* always true at compile time (a
constant compared to itself, say) is fine either way, but that's rarely
what `expectError`/`expectEqual` are used for.

## Log scope names have a hard 14-character limit, enforced at compile time

`debug/log.zig`'s `scoped()` rejects any name longer than
`config.debug.max_log_scope_len` (14) with a `@compileError` naming the
offending scope — caught immediately by `zig build check`, not a runtime
surprise. Pick short scope names for new test files up front
(`fault_inj_blk`, not `fault_injection_block_test`) rather than
discovering the limit by trial and error.
