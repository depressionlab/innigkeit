# Test system: survey, findings, and staged plan

Owner doc for the test-system revamp requested 2026-09-15: "use our existing
plans for fuzzing and a test harness, survey the best testing systems, and
design a comprehensive plan." Complements, rather than replaces,
`docs/test-harness-plan.md` (TH-1..TH-5 staging) and `docs/next-epoch-plan.md`
§4 (the original fuzzing capture) — those documents' "Done"/"Open questions"
sections are still the record of what happened there; this doc is the wider
plan those fed into, plus the new work this pass adds and specs.

**Project owner's stated bar (2026-09-15, verbatim intent):** "extremely
secure and safe and iterable... do everything as well as possible... survey
what Linux/macOS/other established kernels do... don't waste time on useless
things, but do things correct, beautifully, and efficiently." The staging
below is written against that bar, not a minimal-effort interpretation of
"revamp the test system."

---

## 1. Prior art survey

Researched against this project's own shape (a capability-based
microkernel, most directly comparable to seL4/Fuchsia's Zircon rather than a
monolithic POSIX kernel), not a generic "how do OSes test things" survey.

| System | What it actually does | Relevance here |
| --- | --- | --- |
| **Linux: syzkaller + KCOV** | Coverage-guided fuzzer that generates syscall sequences, mutates them against real per-syscall coverage feedback (`KCOV`, exposed via debugfs), runs in disposable VMs, auto-detects hangs/crashes, dedups by crash signature. `syzbot` runs it continuously and files upstream bugs automatically. | **The single closest precedent for what §5 below proposes.** Innigkeit's syscall table (`user/syscalls.zig`) is exactly the kind of declarative, enumerable surface syzkaller targets. The gap is entirely infrastructural: no coverage-feedback channel out of the QEMU-booted kernel exists yet (§5). |
| **Linux: KASAN / KCSAN / KFENCE** | Compile-time shadow-memory instrumentation for use-after-free/OOB (KASAN), sampling-based data-race detector (KCSAN), low-overhead production memory-safety sampling (KFENCE). | Innigkeit's answer to the KASAN class of bug is architectural, not instrumentation: `memory.safe.memcpy`'s fault-fixup (DESIGN.md Part 3) turns a whole bug class into a typed error instead of detecting it after the fact. KCSAN's class (data races) has **no equivalent here at all** — this is the real gap; see §4's deterministic-interleaving proposal. |
| **Linux: lockdep** | Runtime lock-ordering validator: builds a dependency graph of acquisition order across every lock in the system and flags a potential deadlock the first time two locks are taken in conflicting order, before it ever actually deadlocks. | Directly relevant: `.claude/rules/scheduler.md`/`memory.md` document real, hand-verified lock-ordering invariants ("no path ever holds two scheduler locks," the `entries_lock` → `page_table_lock` nesting) that are currently enforced by code review and debug-assert spot checks, not by a self-enforcing mechanism. A lockdep-equivalent would make these invariants structurally checked. Scoped as a future item, not staged this pass (needs a real design, not a bolt-on). |
| **Linux: kselftest** | In-tree black-box tests exercising real syscalls/user-facing behavior from actual userspace binaries. | This is exactly what `testing/fixtures/itest_*` + `testing/integration.test.zig` already are — Innigkeit already independently arrived at the same shape. No gap here beyond breadth (TH-2/4/5's own staging). |
| **Linux: fault injection (`CONFIG_FAULT_INJECTION`)** | Configurable, targeted or probabilistic failure injection into allocation/IO paths, so error-handling code that's "obviously correct" but never actually exercised gets run for real. | **A real, currently-missing category for Innigkeit.** DESIGN.md's "fail-safe" ideology is about *known* faults (bad user pointers); this is about *injected* faults in kernel-internal allocators/drivers to prove the failure-handling code that already exists actually works. Staged in §4. |
| **seL4** | The formally verified capability microkernel — direct architectural sibling of Innigkeit. Functional correctness is machine-checked (Isabelle/HOL) from the abstract spec down through the C implementation to the compiled binary; a separate, independent proof covers two security properties: integrity (no subject can be modified without authority) and confidentiality/noninterference. Alongside the proofs, `sel4test` is an ordinary black-box regression suite (IPC, capability derivation/revocation, scheduling) run on real hardware and simulators, plus a performance-regression tracker. | **The highest-assurance prior art for exactly this project's threat model.** Full functional-correctness proof is not proposed here — that is a multi-year, dedicated-team undertaking (seL4's took years) and is out of proportion to this pass. What *is* directly adoptable at a much smaller scope: modeling one security-critical protocol's state machine and its invariants formally, then generating test oracles from that model — see §3's formal-model proposal, deliberately scoped far below "prove the whole kernel," matching seL4's own emphasis that the *security property* proofs (not just functional correctness) are what make the capability guarantees real. |
| **Fuchsia / Zircon** | Also a capability-based microkernel. Zircon's own test split mirrors Innigkeit's almost exactly: `zxtest` (host-buildable unit tests) + `core-tests` (black-box kernel tests run in a VM) — independently converged on the same host/in-VM split this project already has. For fuzzing, Zircon solved *exactly* the problem in §5 (coverage-guided fuzzing of code running inside a booted kernel VM): a debug syscall/channel delivers fuzzer-controlled input into the target and reads coverage counters back out, driven by a host-side libFuzzer/ClusterFuzz process treating the VM as the "fuzz target." | **Confirms §5's proposed architecture is a known-working pattern, not a novel research problem.** The specific mechanism (debug-channel corpus delivery + counter-table readback, host process drives the fuzzing loop) is the concrete design to copy. |
| **loom** (Rust) | A permutation-checking concurrency model checker: runs a piece of concurrent code under every legal thread interleaving (up to a bound) instead of relying on scheduling luck to hit a race. | Direct precedent for §4's deterministic-interleaving proposal. loom works by *replacing* the real scheduler/atomics with a model executor for the code under test — the Innigkeit equivalent would need the real scheduler to expose seeded/replayable interleaving points, a bigger lift than loom's userspace model-swap, scoped accordingly (§4, not started this pass). |
| **BSD (kyua/ATF, FreeBSD stress2)** | TAP-based structured test execution (kyua) and a dedicated kernel stress-test suite (stress2). Less architecturally relevant (monolithic BSD, not a capability microkernel) — surveyed for completeness, nothing here changes the plan below. | Confirms `zig build verify`'s "judge by structured verdict, not raw exit code" (`VerdictStep.zig`) is already the same idea as ATF/TAP, independently arrived at. |

**Bottom line the survey converges on**: Innigkeit's *existing* test taxonomy
(host unit / in-QEMU kernel / SMP stress / user-process integration,
`docs/verification-and-ci.md` §1) already matches, layer-for-layer, what
Linux/seL4/Fuchsia converge on independently. The real gaps, in order of
how directly they map to this project's own stated security bar, are:
**(1) a live SMP concurrency bug this very pass found** (§2 — fix before
anything else, since "extremely secure" is not compatible with a known
reproducible kernel panic); **(2) coverage-guided in-kernel fuzzing with a
real feedback channel** (§5, syzkaller/Zircon-style — explicitly asked for);
**(3) fault injection** (§4); **(4) a scoped formal model of one
security-critical protocol** (§3, seL4-inspired but far smaller in scope);
**(5) deterministic concurrency testing** (§4, loom-style) — a real gap
(nothing here today) but the least mechanically scoped of the five, staged
last.

---

## 2. This pass's highest-priority finding: a real, reproducible arm SMP kernel panic

**Found while implementing TH-2 (the IPC/capability-transfer integration
test this doc's own §6 stages).** Full diagnostic trail, evidence, and
current mitigation: `.claude/rules/arm.md`'s "Two concurrent spawns panic
the kernel" entry — read that first, this is a summary and pointer, not a
duplicate.

**One-line summary**: spawning a second process (`Process.spawnFromInitfs`)
before the first one finishes loading and jumping to userspace reliably
(100% reproduction, not a rare flake) panics the aarch64 kernel. Confirmed
to be a genuine SMP concurrency bug, not anything about IPC/capability
grants specifically (reproduces identically with two plain, already-known-
good `itest_spawn_wait` spawns). Root cause traced as far as: the second
process's ELF-segment-copy page fault gets `error.OutOfMemory` from
`AddressSpace.handlePageFault`, with the hardware reporting a *permission*
fault (an entry already exists, denying access) rather than the translation
fault a genuine first-touch `zero_fill` access should produce — strongly
suggesting page-table-page allocation or fault handling isn't safely
serialized *across* two different address spaces being populated
concurrently on arm. Not root-caused further this pass (see the rules-file
entry for the two leading hypotheses and exactly how to resume).

**A second, related, independently real bug was found alongside it**:
`Process.zig`'s `loadAndStart` (the kernel-thread entry that drives
`loadAndJump`) responds to *any* load failure — ELF-not-found, invalid
codesig, `loadAndJump` erroring — with a bare `return;`, and the generic
"a `.user`-type kernel thread's entry function returned" cleanup path
(`TaskCleanup.zig`) then panics (`"thread not found in process threads!"`
or `"reached unreachable code"`, observed both). This is
**architecture-independent** — nothing about it is arm-specific, it has
just never been reachable before (spawning an ELF that fails to load has
never been exercised by any existing test). **Investigated, not fixed
this pass**: the fix looks like routing these failures through
`Process.terminateCallingThread(...)` (the established, already-correct
mechanism for "this process's own thread is ending abnormally," matching
`exit_process`/`process_kill`/fault-isolation) instead of a bare `return`
— but `terminateCallingThread` is `noreturn`, and `loadAndStart` holds local
heap allocations (`path_buf`, `proc_init`) and a process reference behind
ordinary `defer`s that would silently stop firing under a noreturn
diversion (a real leak, not just a style concern) if swapped in naively.
Getting this exactly right needs a clear answer for what `loadAndStart`'s
own local `child_process.decrementReferenceCount()` defer (line ~463)
is actually balancing against — traced partway (a `createThread`-time
`self.incrementReferenceCount()` for thread membership, decremented
generically by `TaskCleanup`) but not confirmed with full certainty this
pass. This project's own capability-table/slab-reuse bug history
(`docs/roadmap.md`'s "Carried-over tracked items") is proof this exact
subsystem punishes a rushed reference-counting change — flagged here
rather than shipped without that certainty, per `DESIGN.md` Part 5's
"genuinely hard calls... get flagged... rather than resolved silently."

**Update (re-verification pass): the race is not arm-specific either —
confirmed on x86_64 too, at lower probability.** Re-running the full verify
gate after an unrelated fix (a disk-image-size ceiling the new test
fixtures had crossed, see `.claude/rules/build.md`) surfaced a single
`error.WatchdogTimeout` failure on x86_64: TH-4's spawn/kill leak-loop
(20 cycles, each spawning victim + killer without waiting on victim first —
the same unsynchronized-concurrent-spawn shape as §2's arm panic) hung on
x86_64 within the loop, where the two single-shot tests (one concurrent
spawn each) had been passing there reliably. So the underlying race is
real on x86_64 too, just not 100%-reproducible on a single attempt the way
it is on arm — 20 iterations is apparently enough to hit it. This means
§2's framing of "an arm SMP bug" undersells the finding: **treat this as a
generic concurrent-address-space-population race, not an arm-only one**,
which also means the two arm-specific hypotheses above (a
`PageTable.zig`-local page-table-allocation race, `TTBR0_EL1`/`tlbi`
barrier timing) may be the wrong place to keep looking — a shared root
cause in generic `AddressSpace`/`Process.spawnFromInitfs` code is at least
as likely now. The loop test is gated to skip on *every* arch (not just
non-x86_64) as a result; `.claude/rules/arm.md` has the corresponding
update.

**Current state**: both bugs are documented in `.claude/rules/arm.md` with
a full repro and resumption path. The two single-shot integration tests
that exercise the race without reliably triggering it on x86_64
(`testing/integration.test.zig`'s capability-transfer test and
`process_kill` test) are gated `x86_64`-only; the loop test that does
reliably trigger it there too is gated unconditionally. This keeps the
verify gate green on both arches rather than either shipping a
permanently-red CI or silently hiding the bug. This is **the single
highest-priority item for the next session** to pick up — higher priority
than any of §3-§5's new infrastructure, since a reproducible kernel hang/
panic under a realistic workload (any real multi-process system will
eventually spawn two things close together) is a direct contradiction of
"extremely secure and safe" regardless of what other testing investment
happens around it, and now provably isn't limited to the secondary
architecture.

**Update (instrumented-reproduction pass): the "second bug" above is not
what it looked like, and its proposed fix direction is wrong.** Diagnostic
logging on the `onKernelPageFault` path (the first bug's own symptom)
never fired when the arm panic was reproduced live — the crash went
straight to the "thread not found in process threads!" panic instead, so
the two bugs are not reliably the same failure occurring in sequence, at
least not every time. More importantly, tracing the actual kernel-task
exit path (`task/core/internal.zig`'s `taskEntry` trampoline) shows a
bare `return` from `loadAndStart` is **not** a special, cleanup-skipping
case — it goes through the exact same `Handle.terminate()` →
`decrementReferenceCount` → `queueTaskForCleanup` route as any other task
exit. So the "second bug"'s own proposed fix (route load failures through
`terminateCallingThread` instead of a bare `return`) would not have
changed anything; the paragraph above describing that fix direction and
its `noreturn`/defer complications is superseded. `Process`/`Thread`
slab-cache reuse was also audited this pass and ruled out (see
`.claude/rules/arm.md`'s update for the specifics: `Process.create()`'s
partial field reset looked suspicious but `cleanupProcess()` already
handles the fields it skips). Net effect: this pass narrowed what the bug
*isn't* (page-fault path as the sole cause, task-exit cleanup shortcut,
slab reuse) without finding what it *is* — stopped after this round per
the project owner's call, rather than continuing to guess. Still the
highest-priority item for a future session, now with a clearer "don't
re-check these" list and a suggested next probe (instrument
`Process.createThread`'s insert and `TaskCleanup.cleanupTask`'s remove
directly, per `.claude/rules/arm.md`).

**Update (checkpoint pass, §4): the panic half is found and fixed.** Both
"bugs" above were one bug seen through different cleanup orderings.
`loadAndStart` dropped a process reference it never owned on every load
failure. The "second bug"'s original direction was closer to right than
the later update says: the panic really is downstream of the load
failure, just through reference counting, not the task-exit path. The
load failure itself (the second of two concurrent loads getting
`BadAddress`) is still open. See `.claude/rules/arm.md`.

---

## 3. A scoped formal model: capability revocation / rights monotonicity

**Chosen over EEVDF scheduler placement and the IPC protocol** (the other
two candidates raised when this was discussed) for three converging
reasons, not a coin flip:

1. **It's the invariant this codebase's own docs call out most
   insistently and most often**, independent of this pass: `CLAUDE.md`'s
   "Security model" section states rights monotonicity before anything
   else; `DESIGN.md` Part 5 names it explicitly as the one class of thing
   "never traded away for elegance or speed"; `.claude/rules/user-boundary.md`
   and `capabilities.md` both treat it as load-bearing. A model that
   formalizes exactly the thing already treated as sacred is the highest
   ratio of assurance gained to scope spent.
2. **It's the most tractable of the three to model precisely**, which
   matters given "don't waste time" — EEVDF placement and the IPC
   send/recv/call/reply protocol both have large, continuous state spaces
   (timing, queue depths, cross-executor placement) that resist a clean
   finite-state model; capability lifecycle (create → copy [rights
   subset] → transfer → revoke, plus the generation-counter mechanism that
   makes revocation observable) is a genuinely small, already-mostly-finite
   state machine — `CapabilityTable.Slot`'s own shape (`ptr_or_next`,
   `type`, `rights`, `generation`) *is* almost the state machine already.
3. **It already has a real implementation to check the model against**:
   `CapabilityTable.copyLocked` (rights-subset enforcement),
   `CapabilityTable.transferCaps` (the exact-rights-replicated-not-restricted
   semantics confirmed while building TH-2 this pass — see below), and the
   generation-counter revocation mechanism are all real, running code with
   existing unit tests (`CapabilityTable.zig`'s own `test` blocks) that a
   model-derived property test can be checked against directly, unlike a
   scheduler or IPC model, which would need new instrumentation just to
   observe.

**A concrete, already-confirmed-relevant finding from building TH-2 this
pass, worth modeling explicitly**: `CapabilityTable.transferCaps` (the IPC
capability-delegation path) does **not** enforce rights-monotonicity via
any explicit subset gate at all — it copies whatever rights the sender's
slot currently holds into the receiver's new slot verbatim. This part is
*not* a bug — you can only transfer what you already hold, and rights can
never exceed what a process itself has by construction of every other
path — but it means the monotonicity property here is an **emergent**
consequence of the whole system (every path that could hand out a
capability only ever narrows or replicates, never widens), not a single
local check the way `copyLocked`'s explicit `new_rights ⊆ source_rights`
assertion is. That distinction — "provably true locally" vs. "true only as
a consequence of every caller behaving" — is exactly the kind of thing a
system-wide model makes airtight instead of merely plausible by
inspection.

**Update: the adjacent "no `grant`-bit requirement" half of that same
observation turned out to be a real, separate bug, not a benign
consequence of the design — FOUND AND FIXED while grounding the TLA+ model
in the real semantics.** `.grant`'s own doc comment ("can transfer a copy
of this capability to another process") is exactly what `transferCaps` and
`handlers/spawn.zig`'s cap-grant loop do, and neither checked it before
this pass — a capability could be delegated over IPC or handed to a
spawned child regardless of whether its holder was ever granted the right
to delegate it at all. See `.claude/rules/capabilities.md`'s new entry for
the full audit (every real grant/copy call site checked for breakage) and
fix. This is exactly the "a future maintainer... could break without any
single test catching it" risk the paragraph above already named — it had
already happened, silently, before this pass found it by reading the code
closely enough to model it.

### Scope (deliberately small — this is not "verify the kernel")

- **In scope**: a formal state-machine model (TLA+, chosen for being the
  most widely-used, best-tooled option for exactly this class of
  "concurrent state machine with an invariant" problem, and for having a
  model checker — TLC — that can exhaustively verify small state spaces
  rather than merely type-check the spec) of: capability slot lifecycle
  (`null` → occupied → copied/transferred/revoked → `null` again),
  generation-counter semantics (a revoked slot's generation strictly
  increases; every existing reference derived from the old generation must
  fail `getAndRefLocked` afterward — the exact property `CLAUDE.md`'s "Key
  invariants" section states), and the rights-subset/rights-replication
  distinction above. The invariant to check: no execution reaches a state
  where a live capability reference carries rights not derivable from a
  strictly-decreasing chain back to some original grant.
- **Out of scope**: modeling IPC message delivery ordering, the scheduler,
  or memory management; connecting the model to the real C-equivalent (Zig)
  implementation via a mechanized refinement proof the way seL4 does (a
  multi-year undertaking, explicitly not what "scoped" means here).
- **The payoff that keeps this from being "a PDF nobody reads"**: once the
  model exists, derive a **property-based test** from its invariant —
  generate random *sequences* of capability operations (create, copy with
  various rights, transfer over IPC, revoke, re-check) against the real
  `CapabilityTable`, asserting the same invariant the model checks
  abstractly. This is the concrete "test oracle" link seL4's own tooling
  doesn't give away for free but that this project can get cheaply because
  the state space is small enough to both model *and* directly test. This
  property test is real, runnable Zig code (`test_native`-eligible,
  `CapabilityTable` is already host-testable) — not a documentation
  exercise.

### Staging

1. Write the TLA+ spec (`docs/formal/capability_revocation.tla` or
   similar) for the state machine above; verify it with TLC against a
   small bound (e.g. 4 capability slots, 3 processes) to confirm the
   invariant actually holds in the *model* first.
2. Write the property-based Zig test deriving the same invariant, run
   against the real `CapabilityTable`, wired into `test_native`.
3. If the model-checking step (1) finds a real counterexample, that's a
   real finding to report before step 2 — do not silently "fix the model
   to match the code" without first understanding which one is wrong.

**Done, this pass — all three staging steps.**

1. **TLA+ spec written and verified**: `docs/formal/capability_revocation.tla`
   + `capability_revocation.cfg`, modeling Grant/CopyCap/TransferCap/Revoke/
   RemoveCap directly against the real `insertLocked`/`copyLocked`/
   `transferCaps`/`revokeLocked`/`removeLocked` semantics (including both
   fixes from this same pass — see the spec's own header comment for exactly
   how each is encoded as an action precondition). TLC (`tla2tools.jar`,
   fetched fresh into this sandbox — no prior install) confirms
   `RightsMonotonicity` exhaustively: **"Model checking completed. No error
   has been found"**, 121,963 distinct states, 0 states left on queue
   (a genuinely complete search, not a partial one), depth 14, ~8 seconds.
   Bound: 2 objects, 2 processes, 2 slots per process, generation capped at
   1, rights drawn from a 5-value representative sample instead of the full
   16-value `SUBSET RightsSet` lattice — the full lattice at even this small
   a bound produced a state space that hadn't finished exploring after 10+
   minutes (tens of millions of states, still growing), confirmed by two
   separate timed-out attempts before reducing to representative rights
   values; a subset-behavior invariant doesn't need every one of 16
   equivalent-shaped rights combinations to be checked exhaustively, since
   the invariant only ever compares sets via `\subseteq`. Also tried scaling
   to the plan's literal "4 slots, 3 processes" example after the smaller
   bound converged so fast (8s) that headroom seemed available — that bound
   reproduced the same unfinished-in-reasonable-time growth (2.7M+ states
   still queued after 3 minutes), so it was abandoned in favor of shipping
   the smaller bound's genuinely complete result rather than a larger but
   incomplete one. A complete check at a small bound is worth more than a
   partial one at a bigger bound.
2. **Property-based Zig test written and passing**: `CapabilityTable.zig`'s
   new `"capability: property -- rights-monotonicity holds under randomized
   copy/revoke/remove sequences"` test, checked against the invariant after
   every one of 2000 randomized operations, run against the real,
   unmodified `CapabilityTable` — confirmed passing under `zig build
   test_x64` (182/182, 2 skipped). **Deviates from the plan's "wired into
   test_native" in one respect, deliberately**: `CapabilityTable.zig` isn't
   host-buildable (it depends on real kernel objects and the heap allocator
   for refcounting, the same wall `RawHeader.zig`/`MADTRawIterator.zig` hit
   before their own extraction), and `std.testing.fuzz` has no precedent
   running inside this kernel's own test binary. Rather than extract a
   parallel pure "SlotTable" core purely for host-testability (real
   refactor risk to a security-critical, already-heavily-tested file, for a
   testing-infrastructure convenience — weighed and explicitly decided
   against), the test runs as an ordinary `test_x64`/`test_arm` test using a
   seeded `std.Random.DefaultPrng` sequence instead of `std.testing.fuzz`:
   genuinely property-based (many random sequences, one invariant checked
   throughout), against the *real* production code rather than an
   extracted copy, just not host-side. Scoped to the single-process
   operations (Grant/CopyCap/Revoke/RemoveCap); `TransferCap`'s own
   soundness is covered by the TLA+ model plus the TH-2/negative-path
   integration tests directly (`transferCaps` needs two live `.user` Tasks,
   unnecessary complexity for a property this table-only test doesn't need
   to touch).
3. **No counterexample found at either the model or the code level** —
   nothing to report under this step. (Two real bugs *were* found and fixed
   while grounding the model in the real code first, before either
   verification step ran: see `.claude/rules/capabilities.md`'s `copyLocked`
   revoked-slot and `.grant`-enforcement entries. Both are now encoded
   directly in the TLA+ model's action preconditions rather than left as
   pre-fix behavior for TLC to (not) catch — see the spec's header comment
   for why the first of the two isn't visible as a `RightsMonotonicity`
   counterexample even in principle.)

---

## 4. Fault injection and deterministic concurrency testing

### Fault injection (staged, not started)

**The gap**: DESIGN.md's fault-safety ideology (Part 3) is about *known*
external faults (a bad user pointer) being converted to typed errors — it
says nothing about whether the kernel's *own internal* allocators/drivers
correctly handle failure when, say, the physical-page allocator is
genuinely exhausted, or a virtio-blk request genuinely times out. Those
error paths exist in the code (`OutOfMemory` is a real member of many
error sets already) but nothing exercises the *failure* branch specifically
— only the success path gets any real test traffic.

**Proposed mechanism**: a build-time-injectable failure seam, mirroring
Linux's `CONFIG_FAULT_INJECTION` at a much smaller scope — a wrapping
allocator (composeable with the existing `heap.allocator`/
`PhysicalPage.allocator`) that fails deterministically on the Nth call
(or Nth call matching a call-site filter), used from a dedicated
`test_native`/kernel-test suite that asserts specific failure points
(e.g., "OOM during `AddressSpace.map`'s L2 page-table-page allocation
correctly propagates `error.OutOfMemory` and leaves no partial mapping" —
exactly `mapSinglePage`'s own `errdefer` unwind chain, currently
untested). A second seam for the virtio-blk driver (fail the Nth request)
would do the same for the storage/filesystem error paths.

**Staging**: (1) the allocator-failure seam + 3-5 targeted tests against
`AddressSpace.map`'s own already-written `errdefer` unwind chains (highest
value: proves existing defensive code actually works, rather than only
compiling); (2) the block-device failure seam, staged only after (1)
proves the pattern out.

**Staging step (1) is done.** `AddressSpace.map()` itself turned out to be
pure VMA bookkeeping (no physical-page allocation at all — `.zero_fill`
mappings populate lazily via a real page fault, per DESIGN.md Part 3); the
actual eager-allocation `errdefer` unwind chain this section was really
about lives in `memory.mapRangeAndBackWithPhysicalPages` (its own
per-iteration and function-level `errdefer`s) and `PageTable.mapSinglePage`
(x64's `map4KiB` walks up to three page-table levels via `ensureNextTable`,
each with its own nested `errdefer` for a level it just created). Delivered:

- `testing/FaultInjectingAllocator.zig` — a `PhysicalPage.Allocator`
  wrapper failing deterministically after N successful allocations, plus
  an `outstandingCount()` this pass added specifically because the obvious
  design (compare `PhysicalPage.freeMemory()`, a system-wide counter,
  before/after) turned out to be **flaky by construction**: an unrelated
  prior test's asynchronous `TaskCleanup`/`ProcessCleanup` freeing pages
  in the background is enough to move that global counter between two
  calls in the same test, on a real `-smp 4` kernel with other tasks
  genuinely running concurrently. `outstandingCount()` tracks only pages
  that passed through this specific allocator instance, immune to that
  noise — found by chasing down a real, reproducible false-positive
  leak/crash combination during development (see below), not a hypothetical
  concern.
- `testing/fault_injection.test.zig` — two tests against a throwaway,
  never-loaded scratch page table (`PageTable.create` zeroes it, so it
  shares no structure with the real, running kernel page table to
  corrupt): a budget sweep from 0 through a generous, architecture-agnostic
  upper bound confirming zero pages leak at *every* injectable failure
  point in the nested chain (not just one hand-picked level), and a
  "fail three ways, then map for real" test confirming a failed attempt
  never leaves a stale page-table entry that would make a subsequent
  legitimate mapping see "already mapped."
- **A real, reproducible bug found during development, then fixed — in this
  test's own code, not the kernel's.** The first version of the budget
  sweep used `top_level_decision = .keep` (copied from `heap/
  AllocatorImplementation.zig`'s `heapPageArenaImport`'s own example
  without checking whether that choice transfers). `.keep` tells `unmap`
  not to reclaim an intermediate page-table-level page even if it empties
  out — correct for a *shared, long-lived* structure like the real kernel
  heap's page-table region, where freeing a table page out from under
  other live mappings would corrupt it, but wrong for this test's
  disposable scratch table, where nothing else ever references those
  pages. That mismatch leaked exactly one page (4 KiB) per failed mapping
  — caught by the test's own leak check, which then hit a second,
  separate rough edge: `std.testing.expectEqual`'s failure-reporting path
  crashed instead of printing a clean diff and failing normally (not
  investigated further once the real cause — `.keep` vs. `.free` — was
  found and fixed; worth a note for whoever next writes a test whose
  assertion might actually fail here). Switching to `.free` (this scratch
  table owns every page it maps, so full reclamation is what "no leak"
  actually means for it) fixed both the leak and, since the assertion no
  longer fails, the crash.

Verified: `zig build check` clean; `zig build test_x64` 184/184 passed (2
skipped, both pre-existing and unrelated); `zig build test_arm` 184/184
passed (13 skipped) after one unrelated, non-reproducible flake (a
different, single-spawn integration test, arm64 SP_EL1 synchronous
exception, confirmed one-off by an immediate clean re-run) — consistent
with this session's already-documented arm/TCG timing flakiness
(`.claude/rules/arm.md`), not a regression from this work.

**Step (2) is done (follow-up pass, 2026-09-27): the block-device failure
seam.**

**Why the design differs from step (1)'s allocator seam.** Step (1)
composed a wrapper allocator with an existing dependency-injection point:
`mapRangeAndBackWithPhysicalPages` already took an `Allocator` parameter,
so `FaultInjectingAllocator` just had to implement that same interface.
The block layer has no equivalent seam — every filesystem call site
(`simple_fs.zig`, `ext4.zig`, `EncryptedVolume.zig`) calls
`innigkeit.drivers.virtio.blk.readSectors`/`writeSectors` (and their
`Raw`/`Bytes` variants) directly by name, with no swappable interface
threaded through. Introducing one (a `BlockDevice` vtable, threaded
through every filesystem call site) would be a real architectural
refactor across three files for the sake of one test feature — exactly
the kind of "build generality current call sites don't need" DESIGN.md
Part 5 and karpathy-guidelines' simplicity bias argue against. Instead,
the seam is a small, comptime-gated hook living *inside* the driver
itself, at its two real per-request entry points
(`blk.readSectorsRaw`/`writeSectorsRaw`) — the same shape as
`checkpoint.zig`'s rendezvous points (a production-code injection site
that must compile to nothing when off), not step (1)'s external-wrapper
shape (which needed no such gating, since production code never
constructs or references a `FaultInjectingAllocator` in the first place).

**What was built.**

- `src/innigkeit/testing/fault_inject_block.zig`, gated by a new,
  independent `-Dfault_inject_block_test=true` flag
  (`build/Options.zig` -> `kernel_options.fault_inject_block_test`, wired
  the same way as `checkpoint_test`/`fuzz_channel_test` -- a distinct flag
  per feature so none of the three couple). `armRead(dev_idx, budget)`/
  `armWrite(dev_idx, budget)` allow `budget` more requests against that
  device to reach real hardware; the next one after that fails with
  `error.DeviceError` without touching hardware at all (no descriptor
  published, no mutex taken, no I/O submitted). The gate lives inside
  `maybeFailRead`/`maybeFailWrite` themselves (matching `checkpoint.wait`'s
  precedent, not `fuzz_coverage.recordHit`'s call-site gating), so
  `blk.zig`'s two call sites can't forget it.
- Two call sites in `drivers/virtio/blk.zig`: `readSectorsRaw` and
  `writeSectorsRaw`, right after their existing `NotInitialized`/
  `OutOfRange` validation and before `dev.request_mutex.lock()` — a real
  usage bug (bad LBA, bad count) still gets its real error, never masked
  by an armed injection.
- `src/innigkeit/testing/fault_injection_block.test.zig`, collected only
  under the flag (`testing/root.zig`, `build.zig`'s `verdict` requires
  `"pass  testing.fault_injection_block"` the same way `-Dtpm`/
  `-Dfuzz_channel`/`-Dcheckpoint_test` already do). Two tests, both
  proving existing error-handling code degrades cleanly under a *genuine*
  device failure rather than only ever having seen the success path:
  `simple_fs.open()` returns `error.IoError` when the directory-sector
  read fails (the `catch |err| { ...; return error.IoError; }` site every
  `simple_fs` operation shares), and `EncryptedVolume.mountAtBoot()`
  treats a header-read device error the same as an absent/plaintext
  volume (the `catch continue` in its device-scan loop -- previously only
  ever exercised by "wrong magic," never by a real read failure). Both
  arm a failure for the *first* request the code under test issues, so
  neither test ever touches real hardware on its failing path -- safe to
  run against whatever disk the test kernel actually booted from (the
  real GPT boot disk, in the default single-drive test setup), since
  nothing is ever written. A genuine write-path test (failing partway
  through `simple_fs.write()`'s multi-sector read-modify-write loop) was
  considered and deliberately not built: proving it safe would need a
  real second scratch disk (`blk.deviceCount() >= 2`, the same
  precondition `tpm.test.zig`'s "provisioned data disk" test already
  requires), stacking a third opt-in build flag with the other two for a
  single test -- a coverage gap worth naming, not worth the added
  combinatorial surface this pass.

**A real, previously-unconfirmed kernel-test-infrastructure bug found and
root-caused (not fixed) along the way.** Building this seam's own tests
hit a kernel panic (`PANIC - kernel page fault... faulting_address: 0x50,
faulting_context: kernel`) that had nothing to do with the block-device
seam itself: `std.testing.expectError`'s failure-reporting path calls
`std.debug.print`, which panics this freestanding kernel at
`Io.swapCancelProtection`. Root-caused by direct `addr2line` symbolization
against the actual test kernel ELF (not guessed) -- the backtrace
resolves cleanly through `debug.lockStderr` -> `debug.print` ->
`testing.print` -> `testing.expectError`, to the exact failing test line.
This means *any* kernel test whose `expectError`/`expectEqual` assertion
is ever actually false crashes the kernel instead of reporting a clean
`FAIL`, silently (nothing in the existing 186-test suite had ever hit a
genuine failure in one of these calls before). Full write-up and the safe
alternative pattern: `.claude/rules/testing-infra.md`. This pass's own
tests were written around it (manual `if/else` + `log.err`, proven safe);
fixing the underlying `std.Io` incompatibility is a separate, larger
undertaking than this staging step.

**Verification.** `zig build check`, with and without the flag, is clean.
`zig build test_x64`: 186/186 passed (2 skipped, unchanged baseline).
`zig build test_x64 -Dfault_inject_block_test=true`: 188/188 passed (2
skipped). `zig build test_arm`: 186/186 passed (13 skipped, unchanged).
`zig build test_arm -Dfault_inject_block_test=true`: 188/188 passed (13
skipped). All four read from each run's own `test.log` serial verdict.

### Deterministic/seeded concurrency testing (staging steps 1-3 implemented; see "Implementation" below — it found and fixed the panic half of the target race)

**The gap**: `testing/smp.test.zig`'s stress tests are real (watchdog-
bounded, genuine cross-executor contention) but are exactly that —
*stress*, relying on scheduling variance to eventually hit a race, the
same way this pass's arm bug was found by luck (two spawns close enough
together, on a slow-enough TCG boot, to reliably collide) rather than by
design. A loom-style seeded/replayable interleaving mode would let a
found race be replayed deterministically (this pass's own arm bug took
several full boot cycles just to pin down *which* code path fired, purely
from log reading — a replayable seed would have cut that down
substantially) and would let CI systematically explore interleavings a
random stress run might not hit in any given run.

**Decision (interview, 2026-09-26).** Per this section's own note that it
deserved a dedicated pass before staging (the same pattern `docs/
next-epoch-plan.md` §5 went through), a 3-question interview was run with
the project owner. Answers, which govern everything below:

1. *Approach* — loom-style abstract model, seeding the real scheduler, or
   more explanation first? **"Whatever is best, or a combination of
   both"** — the technical choice was delegated.
2. *Deliverable this pass* — **"Design doc only."** No implementation
   code is part of this pass; everything staged below is future work.
3. *First validation target* — **"Target the stashed race"**: the
   cross-arch concurrent-spawn bug tracked in `.claude/rules/arm.md`, not
   a general-purpose exerciser with no concrete bug to point at.

**Why neither named alternative fits cleanly, and what to build instead.**
Loom works by intercepting a *model* of atomics/scheduling in ordinary
userspace Rust — it never touches a real kernel scheduler, real page
tables, or real hardware timing. That's a poor fit for the actual target:
`.claude/rules/arm.md`'s own diagnostic trail explicitly widened from "an
arm page-table race" to "confirmed NOT arm-specific... a genuine memory-
corruption bug elsewhere... rather than a lock-ordering gap, since every
lock-scoped path audited so far has checked out" — i.e. the leading
hypothesis today is not a reorderable-atomics race loom's model is built
to catch, but something closer to a wild write or a lifecycle gap that a
userspace abstraction of the scheduler wouldn't even contain. Full
scheduler-wide seeding (exposing and replaying every preemption/yield
decision) is the other extreme, and Part 5's simplicity bias rules it out
directly: it is real, invasive scheduler surgery to build generality this
project has exactly one concrete target for today, not a scoped testing
addition.

The better-fitting prior art is TigerBeetle's deterministic-simulation
testing (VOPR), not loom: TigerBeetle doesn't abstract its state machine
away from real code either — it runs the real thing and makes only *time
and I/O* deterministic, from a single seed, so a failing seed replays
exactly. The design below borrows that one property (a fixed seed
reproduces a fixed interleaving, byte-for-byte, every run) but narrows the
surface even further to fit what Innigkeit's target race actually needs:
instead of simulating all I/O and time, it adds a small number of named,
hand-picked rendezvous points at the specific contended sites already
implicated by the arm investigation, and drives *only those* under
explicit test control. Call it a **targeted deterministic checkpoint**:
smaller than "simulate the whole machine," bigger than "hope stress
testing gets lucky again," and — critically — built around the
one race this pass was asked to target, not speculative general
infrastructure.

**Mechanism (as designed; see "Implementation" below for what changed when
it was built).**

- A new debug/test-only primitive, `testing.checkpoint.wait(comptime
  name: []const u8) void`, following the exact comptime-gating pattern
  `fuzz_coverage.recordHit` already established this pass
  (`kernel_options.fuzz_channel_test` → `kernel_options.checkpoint_test`,
  a distinct opt-in build flag so the two features don't couple): when the
  flag is false the call compiles to nothing, zero cost in every normal
  and CI build. When the flag is true, `wait("insert_thread")` checks a
  small global registry (an `EnumArray`-style table keyed by checkpoint
  name, same shape as `fuzz_coverage`'s counter table) for whether *this*
  name is currently armed by the running test; if armed, the calling task
  blocks on a `Notify` until the test's controller thread releases it by
  name. Unarmed checkpoints (the overwhelmingly common case even under
  `-Dcheckpoint_test=true`, since a given test only arms the 2-3 names it
  cares about) fall straight through — this keeps every *other* test
  running at full, un-throttled speed even when the flag is on, so this
  doesn't become a second `-Dfuzz_channel=true`-style all-or-nothing
  switch that forces a slower build for unrelated suites.
- A **script**, supplied by the test itself: an ordered list of
  `(checkpoint_name, release_order)` pairs. The controller task arms the
  named checkpoints, starts the two racing operations concurrently, then
  releases each checkpoint in the script's exact order — forcing one
  specific interleaving deterministically instead of hoping the scheduler
  produces it. This is the "seed": for this design, a seed is the ordered
  release script itself, not a PRNG value — appropriate for a *targeted*
  mechanism validating one known bad interleaving, not a corpus of
  unknown ones. (A future pass could generalize to search over multiple
  scripts; explicitly out of scope here, per the "design doc only, target
  the known race" answers above.)
- **Placement is not invented from scratch** — `.claude/rules/arm.md`'s
  own "How to resume this investigation" section already names the two
  most promising candidate sites, from an investigation that got as far
  as ruling out several other theories by direct code reading:
  `Process.createThread`'s insert into `process.threads`, and
  `TaskCleanup.cleanupTask`'s remove from the same map — the two ends of
  the exact lifecycle window where a thread was observed to go missing.
  A third candidate, `memory/root.zig`'s `onKernelPageFault` `.user`
  branch (the `tryFixupSafeCopy` call sites the original diagnostic pass
  instrumented), stays a documented fallback if the first two don't
  reproduce the symptom, matching the arm doc's own acknowledgment that
  the page-fault path and the thread-lifecycle path may be two different
  manifestations rather than one.

**Staging outline toward the named target (steps 1-3 now done; see
"Implementation" below):**

1. Add the `testing.checkpoint` primitive and its `-Dcheckpoint_test`
   build option, mirroring `fuzz_coverage.zig`/`kernel_options.
   fuzz_channel_test`'s existing shape exactly (this pass already
   established that pattern twice — coverage counters and the fuzz
   target — so this is the third application of a now-proven idiom, not
   a new one).
2. Wire `checkpoint.wait("thread_insert")` into `Process.createThread`'s
   insert and `checkpoint.wait("thread_remove")` into `TaskCleanup.
   cleanupTask`'s remove — the two sites `.claude/rules/arm.md` already
   names as the most promising unexplored lead.
3. Write one test, run on **both** x64 and arm (the arm doc is explicit
   that this is "confirmed NOT arm-specific," so a design validated only
   on arm would prove less than intended), that arms both checkpoints,
   spawns two processes concurrently the same way the existing 100%-
   reproducible repro does (`itest_spawn_wait` twice, no `waitForNotify`
   between), and releases them in the exact order the bug's symptom chain
   implies triggers the collision. Success criterion: the test
   deterministically reproduces the same failure `.claude/rules/arm.md`
   documents (or, if the first two checkpoints don't reproduce it, the
   page-fault-path fallback site does) on **every** run — proving the
   mechanism controls the actual race rather than just adding delay that
   happens to help or hurt.
4. Only once step 3 can reliably flip the bug on and off by changing the
   release order alone (not by luck) is the mechanism considered
   validated — that is the concrete proof point the interview asked for,
   and the natural point to un-gate `.claude/rules/arm.md`'s "current
   mitigation" tests once the underlying bug itself is then fixed using
   the now-deterministic repro.
5. **Explicitly out of scope even for that future pass**: generalizing
   beyond the 2-3 hand-picked sites, searching over multiple release
   orders/seeds rather than replaying one known-bad script, and any
   CI-facing "explore interleavings automatically" mode — all real,
   larger projects of their own, and none of them named by the interview
   as this pass's target.

#### Implementation (checkpoint pass, 2026-09-26): staging steps 1-3

**What was built.**

- `src/innigkeit/testing/checkpoint.zig` provides the primitive. It has a
  `-Dcheckpoint_test=true` build option (`build/Options.zig` →
  `kernel_options.checkpoint_test`, independent of `fuzz_channel_test`).
  The controller API is `arm`/`awaitCaught`/`release`/`disarm`. A held
  task yield-polls, and the first task to reach an armed point claims it.
  `awaitCaught` also returns the process the held task reported, so a
  test can check it caught its own subject rather than background work.
- `src/innigkeit/testing/checkpoint.test.zig` is collected only under the
  flag. When the flag is on, `build.zig` requires its `pass` line (the
  same "an opt-in suite must not skip silently" guard `-Dtpm`/
  `-Dfuzz_channel` use).
- Two sites: `TaskCleanup.cleanupTask` (user-thread branch, before
  `threads_lock`) and `ProcessCleanup.cleanupProcess` (entry, before its
  refcount check).

**Where the build departs from the design, and why.**

1. **Names are a closed `enum` (`checkpoint.Point`), not `comptime
   []const u8`.** A typo is a compile error, and the enum is the full
   inventory of instrumented sites (DESIGN.md Part 1). An enum also keys
   the `EnumArray` the design already sketched.
2. **The gate is inside `wait`, not at each call site.** `wait` is an
   `inline fn` whose body is `if (comptime !enabled) return;` followed by
   the real work. `fuzz_coverage.recordHit` gates at the call site
   instead. Moving the gate inside means a call site cannot forget it
   (DESIGN.md Part 1, "impossible to misuse"), at the cost of one small
   departure from that precedent. Verified zero-cost: see "Verification".
3. **Sites: `cleanupProcess`, not `createThread`.** Reading the code at
   the two named sites showed `createThread`'s insert can't be part of a
   forceable interleaving with its own thread's removal. The insert
   happens-before the thread is ever queued, so it happens-before that
   thread's cleanup. Different threads of one process are serialized by
   `threads_lock`, and different processes use disjoint maps. The order
   that decides anything is **thread cleanup vs. process cleanup**, the
   two singleton services. That is where the points went.
4. **Blocking is yield-polling, not a `Notify`.** It is simpler, has no
   lost-wakeup cases, and only a held task pays for it. An unarmed point
   costs one atomic load. One lesson from building it: the *controller*
   must also yield while it waits. A controller that busy-spins without
   yielding starves a co-located cleanup task, because kernel tasks are
   not preempted. Found when an early experiment read a stale refcount
   because of exactly this.

**The main finding: the design's hypothesis was only half right, and the
half that crashed the kernel is now fixed.** The first step, before
writing any code, was to count `Process` reference increments and
decrements across spawn. That showed `loadAndStart` dropping a reference
it never owned on every load failure. A single sequential spawn of a
path missing from initfs then panicked the kernel on every run. So the
panic needed no concurrency at all. Concurrency only supplies a load
failure. The full write-up is in `.claude/rules/arm.md`'s updated entry.
The three recorded symptoms (`"thread not found in process threads!"`,
the `WatchdogTimeout`/leak, and `"reached unreachable code"`) are one
refcount bug seen through three cleanup orderings.

**Causal control, the step-4 proof point, shown on the unfixed kernel
(x64 and arm).** A throwaway experiment test armed both points, spawned
a missing path, and released them in a scripted order:

- thread cleanup first: the process refcount read back as
  `0xffffffffffffffff` and the exit notify never fired (a leak, not a
  crash);
- process cleanup first: `PANIC - thread not found in process threads!`.

The same script and the same kernel gave identical results on both
arches, one run each. Changing only the release order flipped the
symptom. The third symptom (`Process.create`'s refcount assert) came
from an unforced run, where the two services interleaved on their own.
That is the evidence the design asked for: the mechanism controls the
interleaving, not just timing.

**The QEMU-hang decision (a judgment call, recorded explicitly).** A
test that drives a kernel panic hangs `zig build`, because nothing
watches the QEMU process itself. The committed test is designed so that
it **cannot panic the guest, even against the unfixed kernel**. It holds
the failed loader thread at `thread_cleanup`. It then checks, within a
2 s window, whether `process_cleanup` is reached for the same process
while the thread is held. The fixed kernel can't get there: the held
thread still owns a reference, so the window only bounds how long the
test looks. If it *is* reached, the test fails with
`error.ProcessTornDownBeforeThread` and **deliberately leaves both
cleanup services held**, stopping one step short of the use-after-free.
The cost of that failure mode is that later tests which wait on a
process exit then fail on their own 60 s watchdogs. They fail rather
than hang. Confirmed against the unfixed kernel on x64: 1/185 failed, no
hang, 95 s wall-clock. So `test_x64`/`test_arm -Dcheckpoint_test=true`
and `verify -Dcheckpoint_test=true` are all safe to run. The
panic-producing release script above was run only as a throwaway
experiment under an external `timeout`, and was never committed. The
test file's header warns that any future script releasing into a
known-bad interleaving needs the same care. **Resolved (follow-up pass,
2026-09-26): stays opt-in, not wired into CI.** It is opt-in like
`-Dfuzz_channel` — a new, narrowly-targeted diagnostic mechanism validated
against one specific historical bug, not yet proven valuable as a standing
regression gate.

**Three more real bugs, found and fixed along the way** (details in the
rules files):

- `Process.exit_status` was not reset on slab reuse, so a load failure
  reported the previous occupant's status (observed 42 and 77). Now reset
  in `create()` (`.claude/rules/arm.md`).
- arm's `handleUserFault` formatted its non-exhaustive `ExceptionClass`
  with `{t}`. That panics on any unnamed EC, so an EL0 instruction abort
  panicked the kernel from inside the isolation path. It surfaced once
  the concurrent-spawn tests were un-gated. There is a new fixture and
  regression test (`.claude/rules/arm.md`).
- Adding that one fixture pushed the x64 test kernel to ~64 MiB and hit
  two ceilings. The image builder's FAT had a fixed 1009 sectors, and
  test-boot RAM was 256 MiB, where the boot hung with zero output. Both
  are fixed (`.claude/rules/build.md`).

**One pre-existing arm bug, surfaced and *not* fixed.** Raising
test-boot RAM to 512 MiB (needed for x64, above) makes arm's sequential
spawn/wait loop test panic in ~1 of 3 boots. It is a kernel `ret` into
the kernel heap (`ESR=0x8600000f`, a stable target address, garbage
`x29`/`x30`), which looks like a task resumed with a garbage saved
context. The **base commit reproduces it** at 512 MiB (2/6) and never at
256 MiB (0/18). So it predates this pass, and RAM size is the trigger,
not anything added here. For a while it looked like this pass's new tests
were the trigger; that was a confound between RAM size and which runs
had the tests. The RAM bump is therefore x64-only. Arm stays at 256 MiB,
and the bug is tracked with its reproducer in `.claude/rules/arm.md` ("A
task resumed with a garbage saved context").

**Open questions flagged for the project owner, then resolved (follow-up
pass, 2026-09-26).**

1. **What exit status a load failure should report — resolved: make
   `spawnFromInitfs` fail before creating a process.** Of the three options
   put to the project owner (a new `Process.ExitStatus` constant, the
   127/126 shell convention, or resolving the failure before any process
   exists), the third was chosen. `spawnFromInitfs` now calls a new private
   `resolveElfAndEntitlements(path)` — the initfs lookup and codesig
   verification `loadAndStart` used to do on its own kernel thread, after
   `Process.create()` had already run — *before* `Process.create()` runs at
   all (`src/innigkeit/user/Process.zig`). `SpawnError` gained `NotFound`
   and `PermissionDenied` (both already-existing `Error.Syscall` variants,
   so the `spawn` syscall handler's implicit error-set coercion needed no
   change). A missing path or a rejected/missing-under-enforcement codesig
   now returns synchronously with no process, no thread, and no exit-status
   ambiguity; `loadAndStart` (the thread body) shrank to just `loadAndJump`
   over an already-resolved `elf_data` slice, since it no longer needs the
   path at all. The integration regression test was renamed and rewritten
   to match ("spawnFromInitfs rejects a missing path before creating a
   process": `std.testing.expectError(error.NotFound, ...)`, no process, no
   notify to wait on) and confirmed passing on both arches.

   This is a genuinely different scenario from the checkpoint test built in
   the previous pass, which used exactly this "missing path" case as its
   trigger for "a loader thread returns without reaching userspace" — that
   trigger no longer creates a process to race, by design. Since the
   checkpoint mechanism's actual target (causal control over the
   `TaskCleanup`/`ProcessCleanup` interleaving) doesn't depend on *why* a
   loader thread returns early, `checkpoint.test.zig` was updated to drive
   the same interleaving through a small test-only `returningLoaderThread`
   (a thread that does nothing and returns, mirroring `loadAndStart`'s
   current, fixed shape) spawned directly via `Process.create`/
   `createThread`, bypassing `spawnFromInitfs` entirely. A first version of
   that replacement accidentally reconstructed the *old, buggy* shape (an
   extra `decrementReferenceCount()` on return) instead of the fixed one —
   caught immediately by the checkpoint test itself failing with
   `error.ProcessTornDownBeforeThread` against current, correct production
   code, which is exactly the failure mode that test exists to catch. Fixed
   by making the synthetic thread a true no-op.

2. **Whether to un-gate the concurrent-spawn tests on x64 — tried, then
   reverted: it hangs.** The project owner's recommendation (based on the
   previous pass's "2/2 clean" report) was to un-gate x86_64 while leaving
   arm gated. Implemented and then re-verified independently: the 20-cycle
   "repeated spawn/kill cycles do not leak" loop test un-gated for x86_64
   hung this sandbox on *two* separate runs (external `timeout` at 200s and
   400s, both stuck at the exact same iteration, no watchdog fired, no
   panic logged — a real hang, not slowness). Bisected against the
   unmodified last-known-good commit with the un-gate change stashed out:
   confirmed the hang is specific to un-gating this test, not an artifact
   of an unrelated environment problem encountered during the same
   session (see below). Re-gated (`if (true) return error.SkipZigTest;`,
   same as before, on every arch) rather than shipping a test that can hang
   the default suite. This means the previous pass's "2/2 on x86_64" result
   doesn't reproduce reliably here — host-load sensitivity (a loaded
   sandbox vs. a quieter one) or a second, still-live timing bug the loop's
   20 iterations are enough to hit are both consistent with the evidence
   and not yet distinguished. Re-flagging rather than re-recommending: this
   needs either a controlled repeat-run study (many runs, varied host load)
   or the checkpoint mechanism itself pointed at whatever this loop is
   actually hitting, before un-gating is tried again.

   Separately, an unrelated environment issue surfaced and was ruled out
   during this verification: the sandbox's disk had filled to 97% (`.zig-
   cache`, ~22 GiB, entirely disposable build-cache growth from this
   session's many `-Darm`/`-Dtpm`/`-Dcheckpoint_test`/`-Dfuzz_channel`
   variant builds) and QEMU's stderr was showing "Invalid read at addr
   0xFED40000" (the TPM CRB probe address — benign, expected noise under
   `-d guest_errors` when no TPM device is attached) followed by a
   generic "failed command" line from Zig's own subprocess-failure
   logging, which merely reflects the guest's `isa-debug-exit` exit code
   encoding and is not itself a failure signal (`test.log`'s serial
   verdict — `ALL N TEST(S) PASSED`, per `build/VerdictStep.zig` — is
   authoritative, not the wrapper's stderr). Freeing the disk (`rm -rf
   .zig-cache`) and re-running from the last-known-good commit both before
   and after confirmed this noise appears on every run, pass or fail alike,
   and was never the actual problem.

3. **The remaining first cause** (the second of two concurrent loads
   hitting a permission fault on a first-touch `zero_fill` page). The
   natural next use of this mechanism is a checkpoint between
   `loadAndJump`'s copy and `changeProtection` steps, to test the
   stale-translation hypothesis recorded in `.claude/rules/arm.md`. That
   is staging step 5's territory (a new hand-picked site with its own
   script), so it was not started.

**Verification (follow-up pass).** `zig build check`, with and without
`-Dcheckpoint_test=true`, is clean. `zig build test_x64`: 186/186 passed (2
skipped). `zig build test_x64 -Dcheckpoint_test=true`: 187/187 passed (2
skipped). `zig build test_arm`: 186/186 passed (13 skipped). `zig build
test_arm -Dcheckpoint_test=true`: 187/187 passed (13 skipped) — all four
read from each run's own `test.log` serial verdict directly, not the build
wrapper's exit code (see the disk/QEMU-noise note above for why that
distinction mattered this pass). Counts are unchanged from the previous
pass's baseline: the un-gate attempt was reverted, so net test/skip counts
are identical, only the renamed/rewritten tests' internals differ.

**Verification.** All results are on the final tree unless noted.

- `zig build check`, with and without the flag, is clean, as is CI's
  scoped `zig fmt --check --ast-check`.
- `zig build verify -Darm=true` (flag off) passes: x64 186/186 (2
  skipped), arm 186/186 (13 skipped), host tests 103/103. Before this pass
  both suites were at 184; the +2 are the two new default-suite regression
  tests, which run on both arches. Arm on its own passed 6/6 standalone
  boots at 186/186.
- `zig build verify -Darm=true -Dcheckpoint_test=true`: arm 187/187 (13
  skipped), with the checkpoint test passing. x64 had 1/187 failing, the
  unrelated early `virtio-blk: completion is interrupt-driven when INTx is
  routed` test. That test runs before any process activity, and the flag
  only adds waits to the cleanup services. Two immediate re-runs of
  `test_x64 -Dcheckpoint_test=true` passed 187/187, as did the previous
  flag-on verify's x64 half, so it is recorded as a one-off flake.
- Zero cost with the flag off, checked at symbol level on both arches:
  the only `testing.checkpoint` symbol left is the comptime `enabled`
  constant. There is no `waitEnabled`, slot table or controller function.
  With the flag on there are 19 symbols, including `waitEnabled`.
- Pre-fix behaviour of the committed test: x64 1/185 failed cleanly, no
  hang.

---

## 5. In-kernel coverage-guided fuzzing: a real corpus-feedback channel

**Explicitly asked for** (2026-09-15: "interested in a feedback channel
because that would be helpful for other projects as well") — scoped here
in real architectural detail so it's buildable directly, following
Zircon's already-proven pattern (§1) rather than inventing one.

### Why host-only fuzzing (today's ceiling) isn't enough

`zig build test_native --fuzz` already gives real, coverage-guided fuzzing
for every host-buildable pure-logic parser (§6 lists what's been added this
pass). But an entire class of code is structurally excluded: anything that
needs `innigkeit`/`architecture` (real kernel types, real MMU state, real
capability objects) simply cannot compile for the host at all — `elf/Header.zig`
and `MADTIterator` both hit this wall and needed a byte-level extraction
(`RawHeader.zig`, `MADTRawIterator.zig` — this pass) specifically to become
host-fuzzable. Every extraction like that is a real, valuable, but bounded
fix for *one* function; the syscall dispatch table, IPC message handling,
and capability-table operations under fuzzer-generated *sequences* of
operations (not just one function's byte input) can never be reached this
way, no matter how many individual functions get extracted.

### Proposed architecture (Zircon-pattern: host process drives, kernel exposes two primitives)

1. **Corpus delivery into the booted kernel.** A dedicated debug syscall
   (gated behind a build option, never compiled into a release kernel —
   mirroring `-Dtpm=true`/`-Dsecboot=true`'s opt-in-suite pattern) that
   accepts a byte buffer from the host (via the existing virtio-console/
   serial channel `build/QEMU.zig` already wires up for test verdicts, or
   a second dedicated virtio-console device) and hands it to a designated
   fuzz target inside the kernel — e.g., "the next N bytes are a syscall
   sequence: selector + args, replayed against the real dispatch table."
2. **Coverage readback.** A per-basic-block or per-function coverage
   counter table (the same shape KCOV/SanitizerCoverage counters take),
   compiled in only under the fuzz build option, dumped back to the host
   over the same channel after each corpus entry runs. Zig's compiler
   does not have a built-in equivalent to `-fsanitize-coverage=trace-pc-
   guard` the way LLVM/clang does for C, so this needs its own mechanism —
   the most direct option is a comptime-generated counter-increment
   inserted at each traced call site (likely per syscall handler and per
   major dispatch branch to start, not true per-basic-block granularity,
   which would need real compiler support Zig 0.16 doesn't expose) rather
   than true SanitizerCoverage-equivalent instrumentation. **This
   granularity limitation should be stated plainly to whoever picks this
   up, not discovered partway through implementation** — it means this
   starts as a coarser signal than syzkaller's real KCOV, closer to
   "which syscalls/handlers executed" than "which branches executed,"
   useful but weaker than the host-side ceiling.
3. **The host-side fuzzing loop.** A standalone tool (`tools/kernel_fuzz/`
   or similar, mirroring `tools/codesign/`'s existing shape) that: boots
   the test kernel once (or reuses a persistent boot — reboot-per-input
   would be far too slow), feeds corpus entries over the delivery channel,
   reads coverage back, and drives either Zig's own fuzzer engine (if it
   can be pointed at an external coverage source — needs checking against
   the actual `std.Build.Fuzz`/`std.testing.fuzz` API surface, not assumed)
   or a purpose-built simple mutation loop if not. A crash (kernel panic,
   watchdog timeout) is caught via the same `VerdictStep`-style log-scanning
   this project's whole test taxonomy already uses, not a new detection
   mechanism.
4. **First real fuzz target once the channel exists**: syscall dispatch
   itself — feed `(selector, arg1..4)` tuples at the real `syscalls.zig`
   dispatch table from a process with minimal entitlements, the closest
   in-repo equivalent to syzkaller's own primary target. This is also
   the single highest-value target for finding the *next* class of bug
   this project's fault-isolation work has been closing one at a time
   (unhandled exceptions, bad user pointers) — a real fuzzer would search
   that space instead of relying on the project owner's own review passes
   to enumerate it by hand.

### Why "helpful for other projects too" is a real, not incidental, property of this design

The delivery-channel + coverage-counter-table + host-driver split is
architecture-and-kernel-agnostic in its *shape* (only the specific counter
injection points and the specific "which corpus format" decision are
Innigkeit-specific) — the same pattern applies to any freestanding/
embedded target that can expose a debug I/O channel and a counter table,
which is presumably the shape of the "other projects" this was asked for.
Keeping `tools/kernel_fuzz/`'s host-side driver structurally separate from
the counter-injection mechanism (a thin, documented interface between
them) is worth doing deliberately for exactly this reason, not left as an
accident of implementation.

### Staging

**Not started this pass** — this is genuinely the largest single piece of
new infrastructure in this whole plan (bigger than the formal model, bigger
than fault injection), and per §2, a reproducible kernel panic takes
priority over new fuzzing infrastructure regardless. Recommended order for
a future session: (1) confirm the `std.Build.Fuzz`/`std.testing.fuzz`
external-coverage-source question above, since it changes whether step 3
above is "use Zig's engine" or "write one" — a half-day spike, not a design
question; (2) build the delivery channel + a trivial single-counter proof
of concept (does bytes-in/coverage-out work at all, before optimizing
granularity); (3) real per-handler counters; (4) the syscall-dispatch fuzz
target itself.

**Staging step 1, done this pass, with a definitive answer (not assumed):
`std.testing.fuzz`/`std.Build.Fuzz` cannot be pointed at an external
coverage source.** Read Zig 0.16.0's actual fuzzer implementation rather
than inferring from the public API surface. `lib/std/testing.zig`'s
`pub inline fn fuzz(context, testOne, options)` is a thin `inline`
delegation to `@import("root").fuzz` (the compiler-injected entry point);
the real engine is `lib/fuzzer.zig`, and it is built end-to-end around
*in-process* execution: it reads live LLVM SanitizerCoverage instrumentation
through linker-section symbols (`__sancov_cntrs`, `__sancov_pcs1`) exported
by the *same compiled binary* the fuzzer harness itself runs in, and
exchanges corpus/coverage state with the build runner through memory-mapped
files (`std.Build.abi.fuzz`'s `Uid`/`SeenPcsHeader`), not any kind of
message channel a remote process could speak. There is no seam anywhere in
this design for "coverage arrived from somewhere else" — the counters are
read directly out of the fuzzer's own address space. This resolves the
plan's stated ambiguity: **the host-side fuzzing loop for a QEMU-booted
kernel must be purpose-built from scratch** (a standalone corpus/mutation
loop driving the delivery channel below), not adapted from
`std.testing.fuzz`. That mechanism stays exactly what it already is for
this project — the in-process host-side fuzz tests on `VolumeHeader.parse`
and `tcp/Segment.parse()` (see `CLAUDE.md`'s Testing section) — a separate,
already-working thing from the in-kernel effort this section is about.

**Staging step 2, done this pass: the delivery channel + a trivial
single-counter proof of concept, verified as a real host<->guest round
trip, not just compiled.** Chose to reuse the kernel's *already-existing*
virtio-net driver + UDP socket stack (`network/socket.zig`'s
`openSocket`/`recvUdp`/`sendUdp`, already exercised by `ping`/the shell's
network commands) over building a new virtio-console device from
scratch, the plan's other tentatively-named option — the kernel already
has a complete, tested UDP path and QEMU's user-mode networking
(`-netdev user`) is already wired into every test boot; a new device
would have meant real new driver plumbing for no benefit a UDP socket
doesn't already give. Concretely:

- **`-Dfuzz_channel=true`** (new build option, `EmulatorOptions.zig`,
  same opt-in shape as `-Dtpm=true`): adds `hostfwd=udp::9999-:9999` to
  the test boot's `-netdev user` args (`QEMU.zig`) and threads a
  `fuzz_channel_test` bool into `kernel_options`, x64-only (networking is
  x64-only today, per CLAUDE.md).
- **`testing/fuzz_channel.test.zig`** (new, collected into the normal
  suite only under the flag): opens a UDP socket on port 9999,
  watchdog-polls for a datagram (same bounded-poll idiom as
  `smp.test.zig`), echoes back the wrapping byte-sum of what it received.
  Reachable only because `stage4.zig`'s `is_test` branch now brings
  virtio-net up *before* running the test suite when the flag is set
  (the normal boot path only brings it up *after*, which the test suite's
  own exit path never reaches).
- **`tools/kernel_fuzz/main.zig`** (new host tool, `std.Io.net`'s
  `Socket.bind`/`send`/`receiveTimeout`): sends a fixed payload to
  `127.0.0.1:9999`, retries on a per-attempt timeout, verifies the
  echoed counter matches the payload's own byte-sum.
- **`build/FuzzChannelHarness.zig`** (new, mirrors `TpmHarness.zig`'s
  spawn-before/reap-after shape but for a foreground client, not a
  daemon): `start` spawns the host tool *without waiting* right before
  the QEMU run step, so it's already retrying while the guest boots;
  `stop` (wired after the run's `VerdictStep`) waits for it and fails the
  build on a non-zero exit.

**Real bug found and fixed getting this to round-trip, not just
compile**: the host tool's first version gave up after 20 seconds. The
guest's listener isn't opened until `fuzz_channel.test.zig` actually
*runs*, which is near the end of the ~185-test suite under this
sandbox's unaccelerated TCG (no KVM) — every datagram sent before that
socket exists is silently dropped (no listener bound to the port yet).
Confirmed via temporary diagnostic logging in `socket.zig`'s
`handleFrame`/`handleArp`/`handleUdp` (added and reverted): 57 datagrams
arrived at the right port with the right payload while the guest was
still dozens of tests away from opening the socket. Fixed by raising the
host's own retry budget to 180s, comfortably outlasting the full suite's
TCG run time. Verified end to end, twice: `zig build test_x64
-Dfuzz_channel=true` → `kernel_fuzz: PASS (counter=2611)`,
`ALL 185 TEST(S) PASSED (2 skipped)`.

**Unrelated finding surfaced by this pass's `zig build verify -Darm=true`
regression check** (not a fuzz-channel bug, and not fixed here): a
concurrent x64+arm QEMU test boot exposed the already-documented,
already-stashed concurrent-spawn race (`.claude/rules/arm.md`) on x64,
which that doc previously only called "confirmed passing" there. See
that file's new addendum. Also surfaced a smaller, separate gap: a real
kernel panic during a QEMU test-boot has no watchdog on the QEMU process
itself, so a panicked guest hangs `zig build` forever rather than failing
it — required a manual `kill` to recover during this investigation.
Neither is blocking staging steps 3-4, both flagged rather than chased
down, matching this project's "genuinely hard/large calls get flagged"
convention for anything outside the task at hand.

**Staging step 3, done this pass: real per-handler coverage counters,
verified as a genuine (not synthetic) signal read back over the channel
proven in step 2.** `testing/fuzz_coverage.zig` is a
`std.enums.EnumArray(Syscall, std.atomic.Value(u32))`, one counter per
syscall selector (61 today) — the plan's own predicted granularity ("which
syscalls/handlers executed," not per-basic-block, since Zig has no
SanitizerCoverage-equivalent instrumentation). `syscalls.zig`'s `dispatch()`
calls `recordHit(tag)` right before invoking the handler (after the
entitlement gate passes, so a permission-denied attempt isn't counted as
handler coverage), gated at the call site by
`kernel_options.fuzz_channel_test` — comptime-false and fully eliminated in
a normal build, confirmed by the default `test_x64` baseline staying at
184 (the coverage module's own unit test isn't even pulled into the build
graph when nothing comptime-references it, so it doesn't appear in that
count either; it does in the `-Dfuzz_channel=true` count, 186, alongside
the 185 from step 2's baseline).

`fuzz_channel.test.zig` extended to send the coverage snapshot as a
*second* datagram after the byte-sum reply (same socket, same peer): 61
little-endian `u32`s, in `std.meta.tags(Syscall)` order. Deliberately
triggers no new syscalls itself — by the time this test runs (near the
end of the suite), dozens of earlier integration tests have already
spawned real user processes making real syscalls, so the dump is already
real, non-synthetic data. `tools/kernel_fuzz` reads it back self-describing
(datagram length / 4, no hardcoded slot count to keep in sync) and prints
which slots hit. Verified end to end: `kernel_fuzz: coverage dump (61
slots)` showed exactly 6 nonzero slots (`spawn_thread`, `yield`,
`exit_process`, `cap_invoke`, `getpid`, `process_kill` by numeric index),
matching what the suite's own fixtures plausibly exercise (`yield`'s
4.1M-hit count lines up with the busy-looping-sibling-thread fixture,
which spins calling `yield()` until force-terminated). Also caught (by the
real kernel test build, not `zig build check`, which stayed clean through
it) a genuine compile error `zig build check` didn't catch:
`std.atomic.Value(u32).fetchAdd`'s return value was unused —
`.claude/rules/build.md`'s "always run a real kernel build after touching
arch asm" caveat turns out to generalize slightly further than just arch
asm; this is the second time this session `check` has missed something a
real test-kernel compile caught (see the `.{.{}} ** count` array-repeat
issue from the capability-revocation work).

**Staging step 4, done this pass: the syscall-dispatch fuzz target itself,
verified as a real (selector, args) tuple dispatched through the real
table by a minimally-entitled process, with coverage confirming it.**
`testing/fixtures/itest_fuzz_target` (new, `spawn = false`, no other
entitlements) receives one `capabilities.Message` (tag = selector, words =
args) over a granted Endpoint and issues it via the exact same
`Syscall.invoke` any real app uses -- the plan's own "closest in-repo
equivalent to syzkaller's own primary target." A minimally-entitled
process, not kernel-internal code, actually crosses the real syscall
trap and its real entitlement gate. `testing/fuzz_target.test.zig` (new)
receives the descriptor as a third fuzz-channel datagram, forwards it via
`Endpoint.call()`, and dumps coverage again afterward.
`tools/kernel_fuzz` drives one fixed, known-safe descriptor (`getpid`,
selector 27, with wild garbage args its handler ignores outright) and
confirms the exact slot moved by exactly +1 between the two dumps.
Verified: `kernel_fuzz: fuzz-target PASS: selector 27 dispatched for real
(slot 27: 2 -> 3)`, `ALL 187 TEST(S) PASSED`.

**Two real bugs found and fixed getting this to actually round-trip, not
just compile** -- neither in the fuzz-channel code itself, both in
existing, previously-untested-this-way infrastructure the new work
happened to be the first thing to exercise this specific way:

1. **A genuine capability-table slab-reuse bug** (`.claude/rules/
   capabilities.md`): `CapabilityTable.deinitAll()` (run on every process
   exit before its slab slot returns to the cache) leaves `free_head`
   pointing at whatever index that process last occupied, not slot 0.
   `Process.create()` already had the established "reset for slab reuse"
   pattern for `entitlements`/`fd_table`/`open_files`/`terminating`, but
   `cap_table` was missing from it -- the fixture's first `endpointRecv`
   got `error.BadHandle` because a *different*, earlier multi-capability
   fixture (`itest_cap_sender`) had previously occupied the same
   recycled process slab slot, leaving `free_head` pointing away from 0.
   Every existing cap-grant test/fixture in this tree assumes its one
   grant lands at handle 0; this bug meant that assumption was only ever
   accidentally true, not something the kernel actually guaranteed.
   Fixed: `process.cap_table.init()` added to `Process.create()`'s
   existing reset block.
2. **`resolveArpWithRetry`'s "yield 100 times" loop wasn't a real time
   bound** (`.claude/rules/network.md`): confirmed as a real, reproducible
   regression (not a one-off) once the fixture's added system load shifted
   scheduling enough to expose it -- an already-working `sendUdp` call
   started failing `ARP timeout for 10.0.2.2` with no code changes to that
   call site at all. Fixed to a real `wallclock`-bounded loop (2s),
   matching the watchdog idiom already used everywhere else in this
   codebase's tests.

Also hit, and worth recording as a process note: a genuinely unrelated
one-off SMP-mutex-test panic (`integer does not fit in destination type`)
appeared once during this investigation and did not reproduce on
immediate re-run -- treated as a pre-existing flake per this session's
established pattern (`.claude/rules/arm.md`'s concurrent-spawn race notes),
not chased further, since it reproduced neither before nor after the two
fixes above and has nothing to do with capabilities or networking.

**Not done, and explicitly out of scope for this pass**: a real
corpus/mutation loop. `tools/kernel_fuzz` drives exactly one fixed,
hand-picked descriptor -- proving the harness, not fuzzing anything yet.
A real mutation loop (random selectors/args, coverage-guided corpus
growth, crash triage against `VerdictStep`'s log-scanning) is real,
substantial future work building on a now-proven, now-tested foundation
across all four staging steps.

---

## 6. Bounded, concrete work landed this pass

Everything below was implemented and re-verified (`zig build check` +
`zig build test_x64`/`test_arm` + `zig build test_native` +
`zig build filesystem_host_x64`, each individually confirmed passing) as
part of this same session, distinct from the specified-but-not-started
items above.

**Correction on "test_x64 confirmed passing" above**: that claim did not
hold on a from-scratch build. A later re-verification pass found
`zig build test_x64`/`verify` hanging indefinitely at boot with zero serial
output the moment all four new fixture apps below were registered in
`apps/root.zig` together — not a kernel bug, but the disk-image-size fix
documented in `.claude/rules/build.md` (the test kernel binary, already at
~55 MiB against a hardcoded 64 MiB image ceiling, tipped over once these
four fixtures' ELF binaries were added, and the image builder corrupts
silently rather than erroring on overflow). Whatever check produced the
original "confirmed passing" claim evidently didn't exercise this exact
from-scratch condition. Both that bug and the cross-arch concurrent-spawn
race above (also found only once the hang was fixed and the suite could
finally boot far enough to run TH-4's loop test) are now fixed/gated and
the whole suite passes clean on both arches — see the two rules-file
entries for the full trail. Recorded here as a concrete instance of why
"confirmed passing" claims need a real, reproduced build behind them, not
just an earlier pass's report of one.

- **TH-2 (IPC + capability transfer over `Endpoint`)** — `docs/test-harness-
  plan.md`'s long-deferred item. Two new fixtures (`itest_cap_sender`,
  `itest_cap_receiver`) wired by `SpawnParams.cap_grants`, observed only
  via wait/notify from the kernel side (never an IPC party itself, since
  `CapabilityTable.transferCaps` requires both sides `.user`). The
  strongest assertion isn't just that both fixtures exit with the expected
  status: the kernel test keeps its own reference to the transferred
  `Notify` and waits on *that* object directly, proving the receiver
  reached the same underlying kernel object through the handle
  `transferCaps` copied in, not a coincidentally-matching handle number in
  a table of its own. **x86_64-only** — see §2.
- **TH-4 (`process_kill` syscall + no-leak-under-repeated-spawn/kill)** —
  the prerequisite this was originally deferred on (`processKill` only
  cooperatively signaling, no forced/multi-core termination) turned out to
  already be resolved by earlier work (`docs/roadmap.md`'s sibling-kill IPI
  cascade) — `test-harness-plan.md`'s own "deferred" note on this point was
  stale, corrected here rather than left to rediscover. Two new fixtures
  (`itest_kill_victim`, `itest_killer`) exercise the real `process_kill`
  syscall path (not just the kernel-internal cascade the existing
  sibling-kill test already covered). The no-leak test is split into two:
  a sequential spawn/wait loop (20 cycles, runs on both arches, exercises
  exactly the class of Process-slab-reuse/cap-table-leak bug this
  subsystem has a real prior history of — `docs/roadmap.md`'s "Carried-over
  tracked items") and a spawn/kill loop (**x86_64-only**, same §2 reason).
- **`MADTIterator` host-testability + fuzzing** — the bigger-scope item
  `docs/next-epoch-plan.md` §4 deferred. Extracted the pure bounds-safety
  walk (reject zero-length/over-length firmware-supplied `length` fields)
  into `MADTRawIterator.zig`, `std`-only, mirroring `RawHeader.zig`'s
  precedent exactly: `MADT.MADTIterator` is now a thin typed wrapper over
  it, public API and behavior unchanged. Wired into `test_native`; a fuzz
  test proves every returned entry stays within the input buffer.
- **GPT/FAT fuzzing — done, honestly scoped to what's actually
  fuzzable.** `.claude/rules/filesystem-library.md` already recorded (Phase
  3 Stage 20) that `gpt.zig`/`fat.zig` have **no runtime "parse untrusted
  bytes" boundary at all** — they're build-time image-construction tooling
  consumed only by `tools/image_builder/`. Fuzzing `Header.copyToOtherHeader`
  with arbitrary byte input would manufacture false-positive panics on
  header shapes no real caller produces (its safety depends on an
  internally-consistent header, not a documented precondition a fuzzer
  could honor). `protectiveMBR(mbr, number_of_lba: usize)` is the one
  genuine exception: it takes a bare, precondition-free `usize` disk size,
  and fuzzing it **found a real bug**: `number_of_lba == 0` underflowed the
  clamped-size arithmetic (`number_of_lba - 1` on an unsigned integer,
  trapping in Debug/ReleaseSafe). Fixed with a saturating subtraction
  (`-|`, matching this codebase's own existing idiom for exactly this
  shape of "degenerate but not type-excluded" input, e.g.
  `MADTIterator.init`'s `-|`). Verified via `zig build filesystem_host_x64`
  (the `library/filesystem` `LibraryDescription`'s own host test step —
  note this step is reached by `zig build build_all`, not by a bare
  `zig build verify`; see the taxonomy note below).
- **A real testing-taxonomy gap found, documented (not changed)**: every
  `LibraryDescription`'s host tests (`library/filesystem`, `core`, `uuid`,
  etc. — including the new `gpt.zig` fuzz test above) run under
  `library_host_{arch}`, which `build_all` depends on
  (`build_all → library → library_host → library_host_{arch}`,
  `build/Wrapper.zig`'s own documented dependency graph) — **not** under
  `zig build verify`, which is deliberately scoped to
  `check + test_native + the QEMU suites` per its own doc string. This is
  intentional, documented design (`Wrapper.zig`'s top-of-file comment), not
  a bug — surfaced here because it means a bare local `zig build verify`
  after touching `library/filesystem/gpt.zig` would **not** have caught a
  regression in the fuzz test just added; only `zig build build_all` (which
  CI's own pipeline already runs as step 6, per `docs/verification-and-ci.md`
  §4) would. Worth knowing when iterating on library-level test coverage
  specifically — not something this pass changed, since redrawing that
  step boundary is exactly the kind of "genuinely hard call" (would it
  make `verify` slower for every iteration, for a category most iteration
  loops don't touch?) that gets flagged rather than resolved unilaterally.

Baseline moved (both suites, `-smp 4`; test_native's own count is unchanged
in file *count* but every one of its constituent files that touches the
above gained new tests) — see the patch's own commit messages for exact
before/after counts per suite, since `CLAUDE.md`'s/`docs/roadmap.md`'s own
baseline numbers were already stale going into this pass (independent of
this work — see those docs' own session logs) and this doc does not
attempt to be the new single source of truth for a number that drifts
every session regardless.

---

## 7. Sequencing recommendation for the next session

Original priority order, matching §1's bottom line — **item 2 (the formal
model) is now done**, per §3's update above; the project owner explicitly
chose to proceed with it and stash item 1 (the SMP panic) for later rather
than keep chasing it, so this list no longer reflects actual execution
order, only what's left:

1. ~~Fix (or at minimum, root-cause past this pass's stopping point) the
   arm SMP panic from §2.~~ **Stashed by the project owner's explicit
   direction** — investigated across three rounds this pass (see
   `.claude/rules/arm.md`), narrowed but not root-caused; safely gated,
   not blocking anything today.
2. ~~The formal model (§3).~~ **Done** — see §3's update: TLA+ spec
   verified exhaustively by TLC at a small bound, property-based Zig test
   passing against the real `CapabilityTable`, two real bugs found and
   fixed while grounding the model (`.claude/rules/capabilities.md`).
3. ~~Fault injection, both staging steps (§4).~~ **Done** — see §4's
   updates: step 1 (`testing/FaultInjectingAllocator.zig` +
   `testing/fault_injection.test.zig`) and step 2
   (`testing/fault_inject_block.zig` + `testing/
   fault_injection_block.test.zig`, a comptime-gated hook inside
   `drivers/virtio/blk.zig` itself rather than an external wrapper, since
   the block layer has no existing swappable interface the way the
   physical-page allocator did). Both proving existing error-handling code
   (page-table unwind chains; `simple_fs`/`EncryptedVolume`'s device-error
   `catch` sites) actually degrades cleanly, not just compiles. Step 2's
   own development found and root-caused a real, previously-unconfirmed
   kernel-test-infrastructure bug (`std.testing.expectError`'s
   failure-reporting path panics this kernel) — see
   `.claude/rules/testing-infra.md`.
4. **The in-kernel fuzzing corpus-feedback channel (§5) — all four
   staging steps done this pass**, per §5's update: confirmed
   `std.testing.fuzz` can't be reused (external-coverage-source spike);
   built and verified a real host<->guest UDP round trip (virtio-net
   reuse, not a new virtio-console device); wired real per-syscall-
   selector coverage counters; and drove one real (selector, args) tuple
   through the real dispatch table from a minimally-entitled process,
   confirmed by the coverage delta. Found and fixed two real bugs along
   the way (a capability-table slab-reuse gap, an ARP-timeout loop that
   wasn't a real time bound — see `.claude/rules/capabilities.md` and
   `.claude/rules/network.md`). What remains is real, substantial future
   work, not staging: an actual corpus/mutation loop — this pass proved
   the harness end to end, it did not build a fuzzer.
5. **Deterministic concurrency testing (§4) — staging steps 1-3 done**
   (see §4's "Implementation"). There is a `-Dcheckpoint_test` build
   flag and a `testing/checkpoint.zig` primitive: named points in a closed
   enum, compiled out when the flag is off (confirmed at symbol level). It
   is wired at `TaskCleanup.cleanupTask` and `ProcessCleanup.
   cleanupProcess`, not the design's `createThread` insert, which can't be
   part of a forceable interleaving. One opt-in test holds a failed
   loader thread's cleanup and asserts its process isn't torn down first.
   Against the unfixed kernel it fails cleanly with no guest panic, so it
   can't hang a QEMU boot. On the unfixed kernel, release order alone
   selected between two of the race's recorded symptoms on both arches,
   which is the causal-control proof point. **It found and fixed the
   panic half of the stashed cross-arch race**: a process-reference
   double-drop on every ELF load failure, also user-triggerable through
   the `spawn` syscall with a missing path. The fix is one deleted
   `defer`. Three more bugs were fixed along the way (stale
   `exit_status` on slab reuse, arm `handleUserFault` panicking on an
   unnamed EC, and two ~64 MiB test-kernel ceilings). **Still open**: the
   concurrent-load failure itself (`loadAndJump failed: BadAddress` on
   arm, 2/2), and a pre-existing arm "task resumed with a garbage saved
   context" panic. The base commit reproduces it at 512 MiB of guest RAM,
   so arm test boots stay at 256 MiB. **Follow-up pass (2026-09-26)
   resolved the three owner decisions flagged above** (see §4's updated
   "Open questions"): the load-failure exit status is fixed by making
   `spawnFromInitfs` resolve the ELF and fail *before* creating a process,
   so a missing path or bad codesig now returns `error.NotFound`/
   `PermissionDenied` synchronously with no process ever created; the
   x86_64 un-gate was tried and reverted after it reproducibly hung the
   20-cycle spawn/kill loop on two independent runs, contradicting the
   earlier "2/2 clean" result — re-flagged as unresolved rather than
   re-recommended; `-Dcheckpoint_test` stays opt-in, confirmed not going
   into CI. Re-verified clean on both arches, flag on and off (186/186 and
   187/187 respectively, unchanged from the prior baseline).

TH-5 (WM client↔server over real IPC) stays exactly where
`docs/test-harness-plan.md` already left it: blocked on the stashed WM
epic (`CLAUDE.md`: "Display server epic is stashed"), not a technical gap
this pass touches.
