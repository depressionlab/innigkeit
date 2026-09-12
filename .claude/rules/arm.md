---
paths:
  - "src/architecture/arm/**"
  - "docs/aarch64-port.md"
---

# AArch64-specific constraints

- `zig build check` does NOT validate inline assembly (`-fno-emit-bin`). Always run a real kernel build after touching arm `asm`. Use the raw S-register encoding (`s3_3_c2_c4_0`) + runtime ID-register gates for instructions not supported by the assembler (RNDR pattern).
- **Data-abort → `onPageFault` routing IS implemented and verified** (`arm/vectors.zig`'s `handleDataAbort`; see the "EL0 synchronous exceptions" section below for the sibling SVC-dispatch work in the same file). This stale bullet used to claim otherwise — it was wrong: the routing was already live (every `zero_fill` mapping demand-pages through it, so it's been exercised by every successful arm boot), and `memory.safe.memcpy`/`memory.safe.atomicLoadU32`'s fault-fixup fast path (`arm/PageTable.zig`'s `safeMemcpyImpl`/`safeAtomicLoad32Impl`) was fully wired too — only its two direct unit tests were left artificially gated to x64-only. Un-gated and confirmed passing for real via `zig build test_arm`. See `docs/DESIGN.md` Part 3 for the full writeup.
- `testCpus()` returns 1 for aarch64 (M1/M2 are single-core). AP startup is M3 and not started.
- `mapDeviceMmio` in `PageTable.zig` is idempotent (guarded by `device_mmio_mapped`). GIC at `0x0800_0000`, PL011 at `0x0900_0000`.
- bundled EDK2 (zig-pkg, 2026-03) is BROKEN — always use host `/usr/share/AAVMF/AAVMF_CODE.fd`.
- TCG aarch64 boot is slow (~60–120 s for firmware). Budget ≥ 180 s per boot attempt.
- ARM test harness: judge by serial verdict `ALL N TEST(S) PASSED`, never by QEMU exit status: `build/VerdictStep.zig` does this as a real build-graph dependency now, not a manual grep. `zig build verify -Darm=true` (or `zig build test_arm` directly) is the reliable path.
- AP startup is Limine-mediated (not PSCI from kernel). `stage1.bootNonBootstrapExecutors` calls `desc.boot` which writes `goto_address` into the Limine `MPInfo`. The kernel never issues PSCI itself.
- GICv2 SGI IAR detail: `GICC_IAR` for an SGI includes the source CPU in `[12:10]`. Mask `[9:0]` for dispatch but pass the full IAR value to `GICC_EOIR`. A raw comparison against `MAX_IRQS` will drop SGIs from CPU > 0.
- **Runtime process spawn on arm — FIXED.** Spawning a *second* process after boot (`Process.spawnFromInitfs` / the `spawn` syscall) used to trigger a recursive/looping "current-EL SP_EL1 synchronous" exception. Root cause: `task/Handle.zig`'s per-task switch was calling the generic `page_table.load()`, which on arm hit the boot-only TTBR1 kernel-root installer instead of TTBR0, so a freshly spawned process's user mappings were never actually active and the ELF-segment copy faulted against stale/absent TTBR0 state. Fixed via a dedicated `loadUserPageTable`/`PageTable.loadUser()` interface slot (`architecture/{Functions,paging}.zig`, `arm/interface.zig`, `task/Handle.zig`). Spawn and ELF load succeed on arm now — this bullet used to be the reason `testing/integration.test.zig`'s two spawn-based tests skipped on arm; they no longer do (see the section below, which closed the *actual* remaining blocker: no syscall dispatch).

## EL0 synchronous exceptions: SVC dispatch and fault isolation — IMPLEMENTED (was Phase 3 Stage 9)

Previously: `vectors.zig`'s `arm_handle_exception` dispatched purely on
`vector_idx`, never on `ESR_EL1`'s Exception Class field, so vector 8
("lower-EL AArch64 synchronous" — where the CPU sends *every* EL0
synchronous exception: SVC, data aborts, instruction aborts, undefined
instructions) always fell through to an unconditional `@panic()` for
anything that wasn't a recognized data abort.

**Now**: `arm_handle_exception`'s `4, 8` case decodes `ESR_EL1.EC`
(`EsrEl1.ExceptionClass` gained `svc_aarch64 = 0x15` and
`unknown_reason = 0x00` alongside the existing two data-abort tags) and
routes:
- `.svc_aarch64` from vector 8 → `handleSvc`: builds an `arm.SyscallFrame`
  from the already-saved `InterruptFrame`'s GPRs, calls the generic
  `innigkeit.user.onSyscall` (the same entry point x64's `syscallDispatch`
  uses), writes the result back. Deliberately does **not** call
  `onInterruptEntry`/`onInterruptExit` the way the IRQ/data-abort branches
  do — `onSyscall` asserts `interrupt_disable_count == 0` on entry, which
  `onInterruptEntry`'s bump would violate; this mirrors how x64's own
  `syscall` path bypasses its IDT/interrupt machinery entirely.
- Anything else from vector 8 (illegal instruction, alignment fault, an
  undecoded EC) → `handleUserFault`: isolates to the calling process via
  `process.terminateCallingThread(...)` instead of panicking, using a
  local `exceptionDisposition(ec) u8` mapping (`.unknown_reason` → sigill,
  everything else → the safe default sigsegv — non-exhaustive, so an EC
  nobody named explicitly still isolates rather than panics or hits
  `unreachable`, matching x64's `exceptionDisposition()` *philosophy*,
  not its shared type — arm's stays local to `vectors.zig`).
- The same exceptions from vector 4 (kernel-mode) still always panic —
  no isolation without a calling user process. An SVC from vector 4 (the
  kernel itself executing `svc`) is treated as a bug, not dispatched.

Both `testing/integration.test.zig` tests (`itest_spawn_wait`,
`itest_illegal_instruction`) now run on aarch64 (still `SkipZigTest`-gated
on riscv64, which has no syscall dispatch of its own yet). Verified via a
real `zig build verify -Darm=true -Dtpm=true` run, not just a clean
compile — the illegal-instruction test's log line confirms the isolate
path actually fires: `unhandled user-mode exception ec=unknown_reason,
killing process (exit status 132)`.

**What's still approximate**: only `unknown_reason` maps to a specific
signal; every other undecoded `ESR.EC` (alignment faults, instruction
aborts, etc.) isolates via the generic `sigsegv` default rather than a
precisely name-matched one. Add more named `ExceptionClass` tags (and
`exceptionDisposition` arms) as something actually exercises them —
this was a deliberate "don't preemptively name ECs nothing tests yet"
call, not an oversight.

**Also fixed in the same pass, unrelated but blocking**: `drivers/virtio/gpu.zig` had
three bare `asm volatile ("mfence" ...)` and one `asm volatile ("sfence" ...)`
calls with no arch guard at all — a pre-existing x86-64-only bug, invisible
until arm's syscall dispatch (now real) made `syscalls.dispatch()`'s
generated table actually reach this driver's code for the first time on an
arm build. Fixed with a `deviceBarrier()` helper mirroring
`drivers/tpm/crb.zig`'s existing per-arch pattern (`mfence` / `dsb sy` /
plain compiler barrier). Same "Zig's lazy analysis hides bugs in
never-reached code" lesson this project has hit repeatedly, this time for
inline asm specifically — caught by `build_all`, not `check` (which never
validates asm).

## `test` blocks written directly inside `src/architecture/{x64,arm}/*.zig` never run (Phase 3 Stage 9)

Confirmed by direct experiment: a `test` block added to `arm/timer.zig`
never appeared in the `test_arm` serial log, and a pre-existing `test` block
in `x64/registers/Cr4.zig` (`"cr4: SMEP is enforced..."`/`"cr4: SMAP is
enforced..."`) never appeared in the `test_x64` log either — both silently
dead. Root cause (documented at the top of `testing/syscall_frame.test.zig`,
which already works around it): the kernel test binary's root module is
`innigkeit`, and `architecture` is a *separate* Zig module `innigkeit`
imports — Zig's test-block collection only walks the root module's own file
graph, never a dependency module's. The `Cr4.zig` tests were fully redundant
with already-passing tests in `testing/security.test.zig` anyway, so they
were deleted rather than moved. **The fix for any future arch-specific
test**: put it under `src/innigkeit/testing/*.test.zig` (referenced from
`testing/root.zig`'s comptime import list) and reach the arch-specific
behavior through `architecture.current_decls`/`architecture.current_functions`
(the generic interface), exactly like `syscall_frame.test.zig` does — not as
an inline `test` block next to the arch code itself, no matter how natural
that placement looks.
