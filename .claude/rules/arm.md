---
paths:
  - "src/architecture/arm/**"
  - "docs/aarch64-port.md"
---

# AArch64-specific constraints

## A task resumed with a garbage saved context: kernel `ret`s into the kernel heap — OPEN, pre-existing, exposed by giving the arm test guest 512 MiB

**Symptom**: `PANIC - arm64: exception: current-EL SP_EL1 synchronous`,
almost always inside `integration: repeated spawn/wait cycles do not
leak`, the 20-iteration *sequential* spawn/wait loop. The one exception was
at 256 MiB, in the `process_kill` test of a boot with the concurrent-spawn
tests un-gated and two processes already wedged. The semihosting dump (in the
build output, not the serial log) always shows the same shape:

- `ESR=0x8600000f`: EC 0x21, an instruction abort from EL1 with a level-3
  permission fault.
- `ELR == FAR`, in every one of 9 hits `0xffff0080_0004_8xxx`–`_9xxx`, and
  `0xffff0080000499b0` in 7 of them. That is `kernel_heap` base +
  ~0x49000, an early, long-lived heap allocation (layout read via
  `memory.kernelRegions()`).
- One hit with a temporarily extended dump showed `X30 == ELR`, `X29 =
  0x20`, `X8 = 0xaaaaaaaaaaaaaaaa` (Zig's Debug `undefined` fill), and `X0`
  a kernel `.text` address. That is a `ret` through a garbage link
  register with a garbage frame pointer: the signature of `switchTask`
  resuming a task whose saved callee-saved area (`PerTask`) is not a real
  saved context. It points to a freed or reused `Task` being resumed, or a
  context read before it was written. Not confirmed.

**Pre-existing, and the trigger is guest RAM.** The **base commit
`78012ec`, with only `QEMU.zig`'s test-boot `-m 256` raised to 512**,
panics in 2 of 6 arm boots with the identical signature and address. At
256 MiB the base commit was clean in 18 of 18 boots (plain, plus two
extra-churn variants). This was found because the checkpoint pass raised
test-boot RAM to 512 MiB for x64's sake (`.claude/rules/build.md`). **Why
more RAM matters is not known**: higher physical frames, a different
heap/slab layout, or a different allocation order are all candidates. For
a while this looked like the pass's two new integration tests were the
trigger. That was a confound: every early failure was at 512 MiB, and
every base run was at 256. A flag-on run with both tests skipped still
hit it at 512.

**Mitigation**: arm test boots stay at 256 MiB (`QEMU.zig`'s
per-arch switch). Only x64 gets 512. **To reproduce**: set arm's value to
512 and run `zig build test_arm` about 3–6 times. Extending
`vectors.zig`'s `dumpAndPanic` to also print `x29`/`x30`/`x0` is how the
register evidence above was captured. Earlier sessions recorded a one-off
"SP_EL1 synchronous" flake in a single-spawn test (test-system-plan.md
§4), which may be the same bug hitting rarely at 256 MiB.

## Two concurrent spawns break the kernel — cross-arch, not arm-specific; the panic half FOUND AND FIXED, the load-failure half still open

**Update (checkpoint pass, docs/test-system-plan.md §4): this entry was
two bugs, and the one that crashed the kernel is fixed.** Read this block
first. The history below is kept, but its item 3 and the "item 3's own
explanation does not hold up" update are both superseded by it.

- **FOUND AND FIXED: `Process.loadAndStart` dropped a process reference it
  never owned.** Reference accounting: `create()` +1, `createThread()` +1
  (thread membership), `spawnFromInitfs`'s own `defer` −1, `TaskCleanup`
  −1 when the thread is destroyed. That is balanced on success, where
  `loadAndJump` never returns. But `loadAndStart` also had `defer
  child_process.decrementReferenceCount()`, which runs on **every load
  failure** (missing path, bad codesig, `loadAndJump` erroring). The
  process was then queued for teardown while its loader thread still
  awaited cleanup. The earlier trace was right that a bare `return` goes
  through the normal exit path. What it missed is that the normal exit
  path's decrement was the *second* one. Which symptom follows depends
  only on the order the two cleanup services run in. All three below are
  symptoms this entry had recorded:
  - process cleanup first: `"thread not found in process threads!"`
    (`TaskCleanup` then reads the freed process);
  - thread cleanup first: the refcount wraps to `0xffff_ffff_ffff_ffff`,
    `cleanupProcess` sees "still has references" and returns, and the
    process leaks with its exit notify never signalled (a test sees
    `error.WatchdogTimeout`, the x64 loop-test symptom);
  - interleaved: `cleanupProcess` passes its refcount check, `TaskCleanup`
    wraps the count, and the slot is freed carrying `maxInt`. The next
    `Process.create` on that slot trips its `reference_count == 0` assert
    (`"reached unreachable code"`).

  **Deterministic and single-spawn**: one `spawnFromInitfs` of a path
  missing from initfs panicked the kernel on every run, on both arches.
  **Reachable from userspace**: any process can do it through the `spawn`
  syscall, whose entitlement is on by default. Found by counting the
  increments and decrements, then confirmed empirically. With
  `-Dcheckpoint_test=true` checkpoints holding `TaskCleanup` and
  `ProcessCleanup`, the release order alone produced the first two
  symptoms on demand, on x64 **and** arm. The third came from an unforced
  run. Fixed by deleting the `defer`. Regression test (default suite, both
  arches): `integration: a spawn whose ELF fails to load ends cleanly and
  leaves its process slot reusable`. The checkpoint-driven test
  (`testing/checkpoint.test.zig`) asserts the lifetime invariant directly.
- **FOUND AND FIXED alongside it: `Process.exit_status` was not reset on
  slab reuse.** A process that ends without `terminateCallingThread` (a
  load failure) reported the slot's previous occupant's status, observed
  as 42 and 77 from earlier fixtures. It is now reset in `create()`. Load
  failures now report 0, which is not a deliberate "failed to load" code.
  That choice is flagged in docs/test-system-plan.md §4, not made here.
- **Still open: the load failure itself.** With the panic mechanism gone,
  un-gating the concurrent-spawn tests on arm shows the original
  symptom 1 plainly, on every attempt (2/2 boots): `spawn: loadAndJump
  failed: BadAddress` for the *second* of two back-to-back spawns
  (`itest_cap_receiver`). The two IPC tests then fail cleanly on their
  watchdogs, since the receiver never runs. In the same polluted boot, the
  `process_kill` test then hit a kernel-mode `current-EL SP_EL1
  synchronous` panic that was not investigated. On x64 the same un-gated
  set passed 2/2 (185/185, 0 skipped), including the 20-cycle loop. So
  what hit x64 before was most likely this same refcount bug, triggered by
  a rarer x64 load failure. **The gates are unchanged**: the first cause
  is demonstrably live on arm, and x64's 2/2 is too little evidence to
  call it absent there. Un-gating x64 is a judgment call left to the
  project owner (docs/test-system-plan.md §4). The best next lead for the
  first cause: both processes load the *same* ELF at the *same* user
  virtual addresses, and the fault is a *permission* fault on a
  first-touch `zero_fill` page. That fits the second loader running
  against a stale translation (TLB or page-table root) left by the first
  process's already-`changeProtection`'d r-x text mapping. It is a
  hypothesis, untested. A checkpoint between `loadAndJump`'s copy and
  protect steps is the natural way to test it.
- **FOUND AND FIXED: arm's `handleUserFault` panicked on any exception
  class without a name.** It logged `esr.ec` with `{t}`, and for a
  non-exhaustive enum an unnamed value makes that formatter panic
  (`"invalid enum value"`). So any EL0 synchronous exception
  `EsrEl1.ExceptionClass` doesn't name (instruction abort `0x20`,
  alignment, ...) panicked the kernel from inside the isolation path meant
  to contain it. That is user-triggerable. Surfaced by the un-gated run
  above, where `itest_cap_sender` took such an exception. Fixed by logging
  `std.enums.tagName(...) orelse "unnamed"` plus the raw hex. Regression
  test: `integration: a user fault with an exception class the kernel does
  not name is still isolated` (new fixture `itest_instruction_abort`,
  which jumps to `0x10`). Confirmed to panic arm before the fix, and to
  isolate as sigsegv after it (`ec=unnamed (0x20)`). Adding that fixture
  tripped two unrelated ~64 MiB test-kernel ceilings, both fixed: see
  `.claude/rules/build.md`.

**High-severity, found during the test-system revamp's TH-2/TH-4
integration-test work. Confirmed NOT arm-specific**, despite this being
where it was first found and everything below being written from that
angle: spawning a *second* process (`Process.spawnFromInitfs`) before the
*first* one has finished loading and jumped to userspace **reliably**
(100% reproducible) panics the arm kernel, and the same underlying race
**also breaks x86_64** — just at lower probability: a single concurrent
spawn passes on x86_64 (`.claude/rules/build.md`'s disk-image-size fix
uncovered this while re-testing after that fix, not a dedicated x64
investigation), but looping it 20 times (`testing/integration.test.zig`'s
"repeated spawn/kill cycles do not leak" test) reliably hits
`error.WatchdogTimeout` there too. This is a real SMP correctness bug in
concurrent address-space population, not anything specific to IPC,
capability grants, or one architecture's page-table code — the
arm-specific diagnostic trail below (page-table allocation races,
`TTBR0_EL1`/`tlbi` barrier timing) may not even be the right place to keep
looking now that x86_64 hits it too; a genuinely shared root cause (e.g. in
generic `AddressSpace`/`Process.spawnFromInitfs` code, not either arch's
`PageTable.zig`) is now at least as likely as an arm-specific one.

**Repro (minimal, confirmed independently of any new test-harness code):**
spawn `itest_spawn_wait` twice in a row with no `waitForNotify` between the
two `spawnFromInitfs` calls (any two already-known-good fixtures reproduce
it identically — this was first found via TH-2's `itest_cap_sender`/
`itest_cap_receiver` pair, then confirmed to have nothing to do with
IPC/cap-grants by reproducing it with two plain `itest_spawn_wait` spawns
instead). 100% reproducible across every attempt (not a rare timing
window) on `zig build test_arm` (`-smp 4`, TCG).

**Symptom chain:**
1. The second process's `loadAndJump` (`user/elf/loader.zig`)'s ELF-segment
   copy step, writing into a just-mapped `zero_fill` region, hits `error.
   BadAddress` from `memory.safe.memcpy`.
2. Temporary diagnostic logging (added and reverted during this
   investigation — see below to reproduce it) traced this to
   `memory/root.zig`'s `onKernelPageFault`'s `.user` branch:
   `process.address_space.handlePageFault(page_fault_details)` itself
   returns `error.OutOfMemory`, for a `PageFaultDetails` with
   `fault_type: .protection` (a hardware *permission* fault — DFSC
   "permission fault", meaning a page-table entry already exists at that
   address but denies the access) rather than the `.invalid`/translation
   fault a genuine first-touch `zero_fill` access should produce. That
   mismatch is the strongest lead: something has already installed an
   entry at this address, with the wrong permissions, before this access —
   consistent with a race in physical-page-table-page allocation or in
   `AddressSpace`/`FaultInfo`'s fault handling when two *different*
   address spaces are populated concurrently on two different executors
   (each spawn's `loadAndJump` runs on its own freshly-created kernel
   thread, and with `-smp 4` and only two threads to place, they reliably
   land on different cores).
3. `Process.zig`'s `spawnFromInitfs`'s thread-entry wrapper only logs and
   `return`s on a `loadAndJump` failure (does not call `exit_process`/any
   cleanup) — the "thread not found in process threads!"/"reached
   unreachable code" panic that follows is a **second, independent bug**:
   a `loadAndJump` failure post-thread-creation leaves the task in a state
   the normal kernel-thread-return cleanup path doesn't expect, on *any*
   architecture, not just arm. It was never reached before this
   investigation because no test previously caused `loadAndJump` to fail
   after `Process.createThread` succeeded.

**Update (instrumented-reproduction pass, same investigation, item 3
above turned out to be wrong):** added a temporary `log.err` at
`memory/root.zig`'s `onKernelPageFault`'s `.user`-branch
`tryFixupSafeCopy` call site (the one item 2 above points at) and
reproduced the arm panic under it. The diagnostic **never fired** — the
crash that actually occurred was item 3's panic
(`TaskCleanup.zig:126`, `"thread not found in process threads!"`), not
item 2's `OutOfMemory`/permission-fault path, at least in this run. So the
two symptoms are not reliably the same failure, or item 2 is a red herring
for at least some repros — unclear which without more data.

More importantly, **item 3's own explanation ("`loadAndJump` failure
leaves the task in a state the normal cleanup path doesn't expect") does
not hold up** once traced end to end: a kernel task's entry function
returning normally (which is what a `loadAndStart`/`loadAndJump` failure
does — logs and `return`s) goes through
`task/core/internal.zig`'s `taskEntry` trampoline exactly like any other
exit — `target_function(...)` returning is followed unconditionally by
`Handle.terminate()` → `decrementReferenceCount` →
`queueTaskForCleanup`, the same path a clean exit takes. There is no
special-cased shortcut for a function that "just returns" vs. one that
calls `exit_process`. So a load failure alone cannot explain a thread
being missing from `process.threads` at its own cleanup time — that
theory (originally written into this file as a confident diagnosis) was
wrong, not just incomplete.

Also audited and **ruled out** this pass, since the "thread not found in
process threads" panic pointed at process/thread lifecycle rather than
the page-fault path:
- `Process.create()`'s slab-reuse field reset. It explicitly resets
  `entitlements`/`fd_table`/`open_files`/`terminating` (each with its own
  "slab-reuse invariant" comment) but not `threads`/`queued_for_cleanup`/
  `cleanup_node`. Initially looked like a real gap, but `cleanupProcess()`
  (`Process.zig`'s `ProcessCleanup`, the process-level counterpart to
  `TaskCleanup`) already handles all three correctly before a process
  slot goes back to the cache: `queued_for_cleanup` is reset to `false`
  at cleanup entry, `process.threads.clearAndFree(...)` runs before
  `globals.cache.deallocate(process)`, and `cleanup_node` is implicitly
  reset by the intrusive list's own `popFirst()`. Not a bug.
- `Thread.internal.create()` — re-sets `.process`/`.task` fresh on every
  allocation via `Task.internal.init`, regardless of slab-slot reuse. Not
  a bug.
- `RawCache.allocateSlab()`'s lock-drop/reacquire dance (drops the
  cache's own spinlock before a potentially-blocking heap allocation,
  serializes concurrent slab builders through a separate
  `allocate_mutex`, re-checks `available_slabs` optimistically after
  acquiring it) — reads correctly under two concurrent callers; no
  double-allocation path found. Not exhaustively proven race-free, but no
  concrete bug found either.

**Not yet root-caused past this point.** The two arm-specific leads from
the original diagnostic pass (a) a race in `arm/PageTable.zig`'s
`ensureNextTable`/physical-page-table-page allocation across concurrently-
populated address spaces, (b) `loadUserPageTableImpl`'s `TTBR0_EL1`
write + `tlbi vmalle1is` racing a concurrent fault-handler PTE write
missing its own barrier — remain unconfirmed and now look less likely
given the x86_64 loop-test also reproduces a related failure and this
pass's repro didn't even go through that path. The real explanation is
most likely something broader in generic `Process`/task lifecycle under
concurrent spawn that hasn't been found yet — possibly a genuine memory-
corruption bug elsewhere (a wild write clobbering `thread.process` or the
`threads` map) rather than a lock-ordering gap, since every lock-scoped
path audited so far has checked out. Stopped here (not a third
speculative round) per the project owner's explicit instruction not to
keep guessing without a concrete new lead — the affected tests are safely
skipped/gated, so this isn't blocking anything today.

**How to resume this investigation**: the page-fault-path instrumentation
technique from the original pass is still valid if a future repro *does*
go through that path (`memory/root.zig`'s `onKernelPageFault` silently
swallows the underlying `err`/`PageFaultDetails` whenever
`tryFixupSafeCopy` succeeds — add a temporary `log.err` right before each
`if (tryFixupSafeCopy(interrupt_frame)) return;` in that function, five
call sites, revert before shipping). But this pass's repro shows the
crash doesn't reliably go through that path at all — the more promising
next step is probably instrumenting `Process.createThread`'s insert and
`TaskCleanup.cleanupTask`'s remove (log the `*Thread`/`*Process` pointers
and `process.threads.count()` at both ends) to catch the actual moment a
thread goes missing, rather than continuing to reason about the page-fault
handler.

**Current mitigation**: `testing/integration.test.zig`'s two single-shot
tests that spawn a second process before waiting on the first (the IPC
capability-transfer test and the `process_kill` syscall test) are gated
`x86_64`-only with a comment pointing here — confirmed passing there, still
panics arm. The spawn/kill half of the no-leak-under-repeated-spawn test
is gated unconditionally (skipped on *every* arch, unlike the other two):
looping the same pattern 20 times is enough to hit the race on x86_64 too,
so "x86_64-only" would be actively wrong for that one specifically. The
sequential-spawn half of the no-leak test (waits after every spawn) is
unaffected and still runs on both arches. Un-gate all three (the two
single-shot tests back to unconditional, the loop test to at least
x86_64) once this is fixed — matching the same "found, gated, fixed in a
later pass, un-gated" arc `docs/test-harness-plan.md` already went through
once for TH-1's original arm gap.

**New data point (test-system-plan.md §5 fuzz-channel pass): the
"passing on x64" half of this mitigation is probabilistic, not immune.**
`zig build verify -Darm=true` (x64 and arm test-boot QEMU processes
running concurrently, competing for host CPU on a KVM-less sandbox) hit a
kernel-context page fault at `0x0000000000000050` during the
`process_kill` syscall test specifically — one of the two tests this
section calls "confirmed passing" on x64. `killProcess failed` (the
test's own `@panic` wrapper around the syscall call) fired first, meaning
the syscall itself returned an error before the page fault, consistent
with the same concurrent-spawn race described above rather than a new
bug: `process_kill force-signals another process's exit status` spawns
its victim and killer without waiting on the victim first, same shape as
the other single-shot test already named here. Re-running `test_x64`
alone (no concurrent arm boot) immediately after passed cleanly
(184/184) — the race needs enough timing pressure to manifest on x64,
and heavy host contention from a second concurrent QEMU instance is
apparently enough, same as the loop test's 20 iterations. Not a new
investigation lead, not re-opened per the "stopped here" note above —
recorded because it's a concrete instance of "confirmed passing on x64"
being conditional on host load, worth knowing before assuming a green
x64-only run under `-Darm=true` load rules this out. Also exposes a
separate, smaller gap: a genuine kernel panic during a QEMU test-boot has
no watchdog on the QEMU process itself (unlike this project's in-kernel
watchdog-bounded waits) — the panicked guest just halts forever and
`zig build` hangs waiting for it, requiring a manual `kill` to recover.

**Root cause of the panic half found and FIXED (docs/test-system-plan.md
§4, checkpoint pass): a process-reference double-decrement, not a
concurrency bug at all.** `Process.zig`'s `loadAndStart` (item 3's "thread-
entry wrapper" above) ran an unconditional `defer
child_process.decrementReferenceCount()` on top of the ordinary thread-
membership reference `TaskCleanup` already drops on any thread exit — so
every `loadAndJump` failure (a path missing from initfs, most simply)
double-counted a decrement no code path actually owned. This reproduces
100% of the time with a *single, non-concurrent* spawn of a missing path,
via the always-allowed `spawn` syscall — no second spawn, no timing window
needed. The three symptoms recorded above (the item-3 panic, the
`0x50` page fault, and the leaked-refcount/`0xffffffffffffffff` case) are
one bug seen through three different cleanup-service orderings, confirmed
by forcing each ordering deterministically with a new checkpoint primitive
(`testing/checkpoint.zig`). Fixed by deleting the stray `defer`; see
`docs/test-system-plan.md` §4 for the full write-up and verification
numbers. The remaining, still-open half of this file's original bug is the
concurrent-load failure itself (`loadAndJump failed: BadAddress` on the
second of two back-to-back spawns on arm, reproduces 2/2) — the two are
separate bugs that happened to share symptoms.

**Follow-up (2026-09-26): un-gating the x86_64 loop test after the fix
reproducibly hangs, contradicting an earlier "2/2 clean" report.** With
the refcount fix in place, un-gating "repeated spawn/kill cycles do not
leak" (the 20-cycle loop this section's "Current mitigation" paragraph
names) for x86_64 was tried per the project owner's direction. It hung
this sandbox on two independent runs (external `timeout` at 200s and
400s, both stuck at the same iteration, no watchdog fired, no panic
logged), contradicting the checkpoint pass's own "2/2 on x86_64" result.
Bisected against the unmodified commit with the un-gate change stashed
out to confirm the hang tracks the change, not an unrelated environment
problem hit in the same session. Reverted (re-gated on every arch) rather
than shipping a hang-prone test. Not yet distinguished: host-load
sensitivity vs. a second, still-live timing bug the loop's 20 iterations
are enough to hit — see `docs/test-system-plan.md` §4 for the full note.

- `zig build check` does NOT validate inline assembly (`-fno-emit-bin`). Always run a real kernel build after touching arm `asm`. Use the raw S-register encoding (`s3_3_c2_c4_0`) + runtime ID-register gates for instructions not supported by the assembler (RNDR pattern).
- **Data-abort → `onPageFault` routing IS implemented and verified** (`arm/vectors.zig`'s `handleDataAbort`; see the "EL0 synchronous exceptions" section below for the sibling SVC-dispatch work in the same file). This stale bullet used to claim otherwise — it was wrong: the routing was already live (every `zero_fill` mapping demand-pages through it, so it's been exercised by every successful arm boot), and `memory.safe.memcpy`/`memory.safe.atomicLoadU32`'s fault-fixup fast path (`arm/PageTable.zig`'s `safeMemcpyImpl`/`safeAtomicLoad32Impl`) was fully wired too — only its two direct unit tests were left artificially gated to x64-only. Un-gated and confirmed passing for real via `zig build test_arm`. See `docs/DESIGN.md` Part 3 for the full writeup.
- `testCpus()` returns 4 for aarch64 — M3 SMP is DONE. AP startup works (Limine brings up all 4 requested CPUs and the M3.1/M3.2/M3.4/M3.5 GICv2 SGI/IPI infrastructure — `arm/ipi.zig` — is wired and correct). The M3.3 blocking bug (`Task.pending_kill`'s deferred-kill safe point firing while a sleeping `Mutex`/`RwLock` was held, abandoning it) is **FIXED**: the check moved from `Current.decrementInterruptDisable` to `Current.checkPendingKill`, called only from the syscall/interrupt return-to-user-mode path (`vectors.zig`'s vector-8 and vector-9/13 branches) — the same mechanism Linux (`TIF_SIGPENDING`/`exit_to_user_mode_loop`) and BSD (ASTs) use. Confirmed crash-free across ~10 `-smp 4` boots. The reschedule-IPI-latency test flake found while validating that fix is also **FIXED**: root-caused to ARM's `WFI` being an architectural *hint* (the ARM ARM explicitly permits a spurious wake, unlike x86 `HLT`), not a timer bug (ruled out via direct periodic-tick-interval measurement); the test now gates pass/fail on wake latency alone (what its name promises) and logs a non-fatal warning when it passes without observing `reschedule_ipi_count` move, instead of requiring both. See `docs/aarch64-port.md`'s M3 section for the full writeup. 8/8 clean `-smp 4` validation runs after the fix, latencies 95-176 μs.
- `mapDeviceMmio` in `PageTable.zig` is idempotent (guarded by `device_mmio_mapped`). GIC bases come from `arm.gic.distributorBase()`/`cpuInterfaceBase()` (QEMU `virt`'s `0x0800_0000`/`0x0801_0000` fallback, or MADT-discovered — see below); the fallback PL011 entry stays fixed at `0x0900_0000` (QEMU-`virt`-specific; the ACPI-SPCR/DBG2 serial path maps its own MMIO dynamically instead, see below).
- **GIC/UART addresses are runtime-discovered from ACPI, not hardcoded, as of the Pi 5 port's PM0 (`docs/rpi5-port-plan.md`).** `arm/init.zig`'s `captureSystemInformation(.early, ...)` parses the firmware's MADT for `gic_distributor`/`gic_cpu_interface` entries and calls `arm.gic.setBases()` before `initializeMemorySystem` maps device MMIO — this has to happen at `.early` specifically, since ACPI early-table access (`acpi.init.earlyInitialize()`) is up by then but the device-MMIO table gets built immediately after `captureSystemInformation` returns. No MADT, or a MADT missing either GIC entry, leaves the QEMU-`virt` fallback addresses in place (logged). Separately, `arm/interface.zig`'s `tryGetSerialOutput` now defers to the generic ACPI-SPCR/DBG2 serial-output path (`Output.zig`'s `tryGetSerialOutputFromGenericSources`, which already handled `ArmPL011` — this needed no new code, just `Pl011.getInitOutput`'s `preference` flipped from `.use` to `.prefer_generic`) rather than always winning with the hardcoded QEMU PL011. Verified transparent on QEMU `virt` (`zig build verify -Darm=true`, baseline 158 passed, no regression) but that can't distinguish real discovery from a silent fallback since QEMU's own MADT happens to report the same addresses the old hardcoded fallback used — real hardware (Pi 5 PM1) is what actually exercises this.
- bundled EDK2 (zig-pkg, 2026-03) is BROKEN — always use host `/usr/share/AAVMF/AAVMF_CODE.fd`.
- TCG aarch64 boot is slow (~60–120 s for firmware). Budget ≥ 180 s per boot attempt.
- ARM test harness: judge by serial verdict `ALL N TEST(S) PASSED`, never by QEMU exit status: `build/VerdictStep.zig` does this as a real build-graph dependency now, not a manual grep. `zig build verify -Darm=true` (or `zig build test_arm` directly) is the reliable path.
- AP startup is Limine-mediated (not PSCI from kernel). `stage1.bootNonBootstrapExecutors` calls `desc.boot` which writes `goto_address` into the Limine `MPInfo`. The kernel never issues PSCI itself.
- GICv2 SGI IAR detail: `GICC_IAR` for an SGI includes the source CPU in `[12:10]`. `gic.handleIrq` masks `iar & 0x3FF` for dispatch but passes the full `iar` to `GICC_EOIR` — fixed; a raw comparison against `MAX_IRQS` used to drop SGIs from CPU > 0. Four SGIs are wired (`arm/ipi.zig`): flush=0, reschedule=1, panic=2, kill=3.
- **New driver: `drivers/sdhci/brcmstb.zig` (Pi 5 port PM4, `docs/rpi5-port-plan.md`) — code exists, unwired, unverified.** Drives the on-die BCM2712 SDHCI controller (`0x10_00FFF000`) that turned out to be the *real* physical microSD slot — the port plan originally assumed SD lived behind RP1's PCIe link, which a real devicetree fetch this pass corrected (see the plan's §1). PIO-only, no DMA/UHS, ported from Linux's `sdhci-brcmstb.c`. **Deliberately not called from any boot path yet** — `filesystem/ext4.zig`/`EncryptedVolume.zig` still hardcode `innigkeit.drivers.virtio.blk`, and picking how a board selects its storage backend is a real decision better made once PM1's real hardware boot is in hand, not guessed now. Because nothing calls it, it needed its own `comptime { std.testing.refAllDecls(@This()); }` at *two* levels of the import chain (`drivers/root.zig` and `drivers/sdhci/root.zig`) just to be seen by `zig build check`/`test_arm` at all — see `.claude/rules/drivers.md`'s new entry for the full mechanism. Its one safe regression test (`setClock`'s divider math, run against a plain zeroed struct) passes; deeper tests against the same fake struct were tried and reverted after one triggered a real, unrelated arm gap — a failed `std.testing.expectError` assertion's own failure-reporting path hits `PANIC IN PANIC - arm does not implement fillContext` and hangs the suite instead of printing a clean `FAIL` line (root cause: write-1-to-clear register semantics can't be faithfully modeled with a bare zeroed struct, so the assertion genuinely fails, and arm's failure-path handling for that case is itself incomplete — worth its own fix, not this driver's).
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
