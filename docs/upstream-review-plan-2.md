# Upstream review, pass 2: findings and staged plan

Direct continuation of `docs/upstream-review-plan.md` (Phase 3.5-ish, not a
fresh naming scheme — kept as a separate file rather than appended to the
first one because that doc's own closing line already declares "all items
in this document's original scope are now done"; this is the next batch, not
a reopening). Same convention: grounded findings verified against
Innigkeit's *actual current* code, not commit-subject pattern-matching;
staged so a context reset or session boundary can resume from this file
alone. Read `docs/upstream-review-plan.md` first for the methodology and the
karpathy-guidelines recap — not re-copied here.

## Scope: which commits

The first pass covered `depressionlab/cascadeos`'s `1e8ac55b..main` (49
commits; `1e8ac55b` itself isn't fetchable in this shallow fork clone, but
its 49-commit count and the doc's own explicit discussion of `bd48de3a`
"reduce the size of the interrupt handlers" as the last commit read in that
pass line up exactly with position 49 of the fork's 78-commit total
history, confirmed by `git log --oneline --reverse | cat -n`). This pass
covers everything after that: `bd48de3..HEAD` — **29 commits**, dated
2026-07-11 through 2026-09-09 (the last being a no-op merge commit). `bd48de3`
itself was already read in full by the first pass ("read in full, genuinely
applicable, ready to implement... a good small standalone follow-up") but
never actually implemented — carried over into this pass's queue rather
than re-investigated.

The project owner recalled the boundary slightly differently ("around June,
a Limine bump") when this pass started. Checked: `c03edda` ("update limine
to v12.3.2", 2026-06-06) is the *oldest* commit in this fork's 78-commit
history, not a boundary in the middle — every commit the first pass
individually named (`5e62791b`, `ba278b09`, `0f58c366`, `22eae01f`, etc.)
falls between position 1 (`c03edda`) and position 49 (`bd48de3`), so the
first pass's actual range is positions 1-49, i.e. `1e8ac55b` (outside this
clone's depth) through `bd48de3`. The "Limine bump" association is likely
from `382ceeb`/`ed74640` (two more Limine bumps, both *inside* this pass's
new range, positions 53 and 55) — flagged here rather than silently
overridden, since the owner's memory and this doc's evidence disagree on
which Limine bump was the boundary, even though they agree on
"Limine bump" being a nearby landmark.

## Disposition tiers

**Tier 1 — confirmed real bugs, present in Innigkeit today, verified by
direct code comparison (not inferred from the commit subject alone).**
Implement + regression-test all of these.

**Tier 2 — mechanical, low-risk improvements, confirmed applicable.**
Implement + verify; lower ceremony than Tier 1 since nothing here is a
live correctness bug, just a real improvement matching a DESIGN.md Part 7
hot-path or Part 1 robustness rationale.

**Tier 3 — needs a real investigation before disposition.** Innigkeit's
code in this area already diverges structurally from CascadeOS's (often
because it's more advanced), so pattern-matching the commit subject against
"do we have this bug too" isn't sufficient — each gets its own read-in-full
before a verdict.

**Tier 4 — CascadeOS-specific housekeeping or narrow API additions.**
Checked properly (per the project owner's "seriously consider implementing
all tiers" direction — no tier gets skipped on subject-line inference
alone), but expected to mostly resolve to "no action" or "trivial, low-risk
port if a real call site exists."

**Design-decision items** — flagged for project-owner sign-off per
DESIGN.md Part 5 rather than resolved unilaterally, exactly like the first
pass's SYSRET-class finding and the `paging`→`mem` rename question.

---

## Tier 1 — confirmed bugs (implement + test)

### 1. `c2a1c8b` → `RwLock.tryWriteLock` TOCTOU race — CONFIRMED PRESENT

`src/innigkeit/sync/RwLock.zig::tryWriteLock` (pre-fix, current code):
```zig
if (self.mutex.tryLock()) {
    const state = @atomicLoad(usize, &self.state, .monotonic);
    if (state & READER_MASK == 0) {
        _ = @atomicRmw(usize, &self.state, .Or, IS_WRITING, .acquire);
        return true;
    }
    self.mutex.unlock();
}
```
`readLock()`'s fast path takes no mutex — a reader can `cmpxchgWeak` its way
onto `self.state` any time `IS_WRITING|WRITER_MASK == 0`. Between this
function's `@atomicLoad` (sees `READER_MASK == 0`) and its plain `.Or` RMW,
a reader can slot in and increment `READER_MASK` — the `.Or` then blindly
sets `IS_WRITING` on top of that, and `tryWriteLock` returns `true` while a
reader is concurrently, legitimately holding a read lock. **Real mutual-
exclusion violation**, not theoretical: `mutex.tryLock()` only excludes
other *writers* going through the slow path, not the always-lock-free
reader fast path. CascadeOS's fix replaces the blind `.Or` with a
`cmpxchgStrong` against the exact snapshotted `state`, retrying (falling
back to the mutex-unlock failure path) if it doesn't hold — closing the
window entirely.

**Action**: port the `cmpxchgStrong` fix verbatim (adjust to Innigkeit's
constant names, unchanged). Add a test exercising the race is now closed
in principle (can't reproduce true concurrency in a unit test, so the test
instead pins the fixed *shape*: tryWriteLock only succeeds via a verified
CAS against the snapshotted state — mirror the existing
`tryUpgradeLock`-doesn't-leak-WRITER-count test's style of asserting the
invariant algebraically). Status: **DONE** (see below).

### 2. `c584feb` → PCI `initializeECAM` leak/UB on allocation failure — CONFIRMED PRESENT

`src/innigkeit/pci/init.zig::initializeECAM`: `ecams.addOneAssumeCapacity()`
happens *before* the fallible `try innigkeit.memory.heap.allocateSpecial(...)`
inside the following struct-literal assignment. If `allocateSpecial` fails,
`ecams.items.len` was already bumped by `addOneAssumeCapacity`, but
`ecam.*` was never actually written (the struct-literal assignment throws
before completing) — the slot holds uninitialized memory. The function's
own `errdefer for (ecams.items) |ecam| innigkeit.memory.heap.deallocateSpecial(ecam.config_space);`
then iterates that garbage slot on the way out, calling `deallocateSpecial`
on an undefined `config_space` value — a crash or heap-corruption bug on
the (admittedly narrow, OOM-only) failure path. Identical shape to
CascadeOS's confirmed-fixed bug.

**Action**: reorder — allocate `config_space` into a local first, build the
full `ECAM` value, `errdefer deallocateSpecial` that one local allocation,
*then* `ecams.appendAssumeCapacity(ecam)`. Status: **DONE**.

### 3. `heap/c.zig::mallocWithNonSizedFree`/`nonSizedFree` — CONFIRMED WOULD NOT COMPILE IF CALLED

Not the same commit as CascadeOS's `512b136` (different Zig/API vintage —
CascadeOS's own bug was a `core.Size` vs `usize` signature mismatch caused
by a Zig std churn on their nightly tracking; Innigkeit's Zig is pinned at
0.16.0 stable), but the same underlying class of bug, confirmed
independently: `grep -rn "mallocWithNonSizedFree|nonSizedFree" src/` finds
**zero callers** anywhere in the tree — this is the exact "uncalled
function hides a compile error under Zig's lazy analysis" pattern already
documented three times in `.claude/rules/core.md` and once in
`.claude/rules/library.md` (`futex.zig`'s self-referential `innigkeit.innigkeit.Error`).
Concretely:
- `mallocWithNonSizedFree` passes `full_size` (type `core.Size`, an
  `extern struct { value: u64 }`) directly to
  `allocator.alignedAlloc(u8, standard_alignment, full_size)` — Zig 0.16's
  `Allocator.alignedAlloc` requires `n: usize`. `core.Size` has no implicit
  conversion to `usize`. This does not type-check.
- `nonSizedFree` passes a bare `[*]u8` to `getAllocationHeader`, which
  requires `[*]align(@alignOf(innigkeit.KernelVirtualRange)) u8` — missing
  an explicit `@alignCast`.

**Action**: fix both (`full_size.value`, `@alignCast(ptr)`), matching
CascadeOS's fix shape exactly. Per `.claude/rules/library.md`'s prescribed
remediation for this bug class, add a real round-trip test (alloc via
`mallocWithNonSizedFree`, free via `nonSizedFree`) rather than just a
`comptime { _ = &fn; }` forcing block — a real test also exercises the
runtime logic (the header write/read), not just the signature. Status:
**DONE**.

### 4. `1c102db` → `testing.expectSize` wrong argument to `Size.of` — CONFIRMED PRESENT

`library/core/testing.zig:13`:
```zig
"{s} has size {f} but is expected to have {f}!",
.{ @typeName(T), core.Size.of(size), size },
```
`Size.of(comptime T: type) Size` expects a *type*; `size` here is a
`core.Size` *value* (the function's own second parameter). This only
executes inside the `@compileError` branch — i.e. exactly when a real size
assertion has already failed — so it doesn't show up in a passing test
suite, but it means the diagnostic message for an actual failure is itself
broken (fails to compile with an unrelated, confusing error about passing
a value where `expectSize`'s `comptime T: type` parameter... — actually
`Size.of`'s own comptime type parameter — is expected). Identical bug,
identical fix (`core.Size.of(T)`), confirmed via direct read.

**Action**: one-line fix. Verify by temporarily constructing a call that
deliberately fails (e.g. `expectSize(u8, .from(99, .byte))` in a scratch
test) to confirm the *message* now renders correctly, then remove the
scratch check. Status: **DONE**.

---

## Tier 2 — mechanical improvements (implement + verify)

### 5. `86e9d87` → `Parker.park()` lock ordering

Current `park()`: takes the scheduler handle (`Task.Scheduler.Handle.get()`)
*before* `self.lock.lock()`. CascadeOS's fix takes the parker's own lock
first, narrowing the time the (global, contended) scheduler lock is held.
Traced Innigkeit's own call graph for a live AB-BA deadlock (the obvious
worry): `unpark()` releases `self.lock` *before* calling
`parked_task.wakeFromBlocked()`, so there's no path today that holds
`self.lock` while also needing the scheduler lock from the other direction
— no live deadlock found. Porting anyway: narrowing a global lock's hold
time is a real, zero-added-complexity win on a primitive every blocking
kernel wait ultimately goes through, matching Part 7's hot-path bias even
without a currently-reachable deadlock to justify it as a correctness fix.
Status: **DONE**.

### 6. `09f02de` → `TicketSpinLock` interrupt-disabled window

`lock()`/`tryLock()` currently call `current_task.incrementInterruptDisable()`
*before* computing the ticket / before the early bail-out check. CascadeOS
moves it later in both functions, shrinking the interrupts-disabled window.
Mechanical, safe, and this is about as hot a path as the kernel has (every
spinlock acquisition tree-wide uses this). Status: **DONE**.

### 7. `ba3e8de` → `SingleSpinLock` read-loop before `cmpxchg`

Classic test-and-test-and-set: read the atomic with a plain load in a spin
loop, only attempt the `cmpxchgWeak` once it looks free. Reduces cache-line
ping-pong under contention (a failed `cmpxchg` needs exclusive ownership of
the line; a plain load doesn't). Innigkeit's `lock()` currently retries
`cmpxchgWeak` directly in the loop body. Status: **DONE**.

### 8. `b6410a8` → `WaitQueue.pop()` replacing `firstTask()`+`wakeOne()`

`Mutex.unlock()` and `RwLock.readUnlock()` currently peek via
`wait_queue.firstTask()` then separately call `wait_queue.wakeOne(...)`,
which re-pops the queue itself — two traversals doing one job. Not
exploitably racy in either codebase (the same spinlock is held
continuously across both calls), but real, avoidable redundancy;
CascadeOS's own rationale ("`pop` is a superior api") is just as true
here. Collapse `WaitQueue` to one `pop()` that removes-and-returns, update
both call sites to call `.wakeFromBlocked()` directly on the popped task.
Status: **DONE**.

---

## Tier 3 — needs real investigation

### 9. FlushRequest cluster (`53e4e14`, `ae237e2`, `7e14f7f`)

CascadeOS's three-commit dance: add interrupt-context support to
`submitAndWait` (drop an assert that interrupts must be enabled, call
`processFlushRequests()` in the wait loop) → "fix multi-core regression"
(revert the wait loop back to a bare `spinLoopHint()`) → change the
`flush_request` interrupt's EOI timing from `.after` to `.before` ("prevent
missing flush requests").

Innigkeit's `memory/core/FlushRequest.zig::submitAndWait` **already**
branches on `current_task.task.interrupt_disable_count.load(.acquire) == 0`:
spins if interrupts are enabled (so the IPI-driven flush gets serviced
normally), calls `processFlushRequests()` directly if interrupts are
disabled (since the IPI can't be serviced while masked). This is
structurally different from — and looks more deliberate than — CascadeOS's
pre-fix code (which unconditionally spun, then unconditionally called
`processFlushRequests()`, then reverted). *Investigated in this pass*:

**Findings**: Innigkeit's `flush_request` interrupt handler was registered
with `.eoi = .after` (`architecture/x64/interrupts/init.zig`) — the exact
value CascadeOS's `7e14f7f` moved away from on their equivalent handler,
specifically to "prevent missing flush requests". Both codebases'
`processFlushRequests()` fully drain their per-executor queue in a `while`
loop (not pop-one), so the naive "a coalesced repeat IPI + a handler that
only pops one entry" failure mode doesn't literally apply to either side —
but CascadeOS found and fixed a real bug here on structurally similar
code, and x86 APIC ISR/IRR coalescing edge cases around when a same-vector
interrupt re-triggers are genuinely subtle (and not reliably
first-principles-derivable, let alone reproducible, in this sandbox's
single QEMU/TCG setup without real multi-socket hardware or a dedicated
stress harness). Given (1) a missed TLB flush after `unmap()` returns is a
real stale-mapping/use-after-free-class correctness gap, not a
performance nit, (2) `.before` EOI has no correctness downside identified
(interrupts stay hardware-masked for the rest of `interruptDispatch`
regardless of EOI timing; EOI'ing first only shrinks the window during
which this vector's LAPIC priority class is held busy), and (3) the fix
is one field, zero added complexity: **ported** — `flush_request`'s `eoi`
changed from `.after` to `.before`, plus its stale in-code comment.

The rest of the 53e4e14/ae237e2 dance (dropping an
interrupts-must-be-enabled debug assert, then a "call
`processFlushRequests()` in the wait loop" change that got reverted for a
multi-core regression) does **not** apply: Innigkeit's `submitAndWait`
never had that assert (it already branches on `interrupt_disable_count`
to decide spin-vs-serve, a design CascadeOS's pre-fix code didn't have),
and it only calls `processFlushRequests()` from the wait loop when
interrupts are *already disabled* — the exact condition CascadeOS's
regression came from *not* checking (their post-53e4e14 code called it
unconditionally, including while interrupts were enabled, risking the
interrupt handler and the wait loop both draining the same executor's
queue concurrently). Innigkeit's design structurally avoids that
reentrancy already; nothing to change in `memory/core/FlushRequest.zig`
itself.

Status: **DONE** (the EOI-timing fix; the rest confirmed not applicable).

### 10. `e845a14` — kernel/userspace page-size agreement assert — INVESTIGATED, partial action

Found the userspace side hardcoded 4096 independently in three places
(`library/innigkeit/interop/root.zig`'s `std_options.page_size_{min,max}`,
`memory.zig`'s mmap page-rounding — one of them still carrying a stale
`// TODO: make sure this is correct`). Checked whether CascadeOS's actual
fix (a comptime assert *inside the kernel build* tying
`architecture.paging.standard_page_size` to the userspace lib's constant)
transfers: it doesn't wire up cleanly here — `library/innigkeit` and the
kernel's `src/architecture` are separate build-graph modules with no
shared import today (confirmed via `build/App.zig`/`build/Kernel.zig`:
both declare a module named `"innigkeit"`, but they're two different
modules, one per side of the kernel/userspace boundary), and every arch
this project targets (x64, arm, riscv) already agrees on 4 KiB, so adding
new cross-module plumbing for a check with no live disagreement to catch
isn't earning its keep yet. **Action taken**: consolidated the userspace
side's three independent 4096s into one documented `innigkeit.page_size`
constant (`library/innigkeit/root.zig`) — removes the real duplication
this investigation found, leaves a clearly-named single place to extend
into a real cross-module check later if a future arch's page size ever
differs. Status: **DONE**.

### 11. `bcdb4d2` — `std_override.zig` comparison — INVESTIGATED, no action

Compared CascadeOS's `lib/cascade/std_override.zig` (new, mostly-`TODO`-
stub `std.Io`/`std_options`/`panic`/`debug` skeleton — every function body
is `_ = arg; // TODO` or an outright `@panic("SEGFAULT")` placeholder)
against Innigkeit's `library/innigkeit/interop/debug_io.zig` +
`interop/root.zig`. Confirmed: Innigkeit's version is a **working**
`std.Io` VTable — real syscall-backed `futexWait`/`futexWaitUncancelable`/
`futexWake`, `sleep`, `ioNow` (clock), and `lockStderr`/`tryLockStderr`/
`unlockStderr` backed by an actual `std.Io.File.Writer`, not stubs. The
specific pieces CascadeOS's skeleton names but leaves as `TODO`
(`FilePermissions`, `cwd`, `debugInfoSearchPaths`, `debug.SelfInfo`,
`debug.handleSegfault`) have no counterpart anywhere in
`library/innigkeit` — checked, and that's a deliberate, working choice,
not a gap: `interop/root.zig`'s own doc comment states `std.fs` is
unsupported for `.os = .other` by design (initfs/future VFS capability
cover that instead), and Innigkeit ships its own complete `panic` handler
(`interop/root.zig`) rather than relying on `std.debug`'s default crash/
symbolication path that `debugInfoSearchPaths`/`SelfInfo`/
`handleSegfault` exist to support — so nothing here ever needs those
declarations. On this specific comparison, Innigkeit is ahead of
CascadeOS's current state, not behind it, confirming the initial read.
No code change. Status: **DONE (no action needed)**.

### 12. `a2d360f` — `TypeErasedCall` extern-union rewrite — INVESTIGATED, no action

Read Innigkeit's own `library/core/containers/TypeErasedCall.zig` in full
(both `usizeFromArg`/`argFromUsize`, the per-arity `typeErasedFn`
dispatch, and the existing signed-enum regression test). It already
handles every argument category symmetrically (bool, int, float, pointer,
array, struct/packed/extern struct, optional, enum, union/packed/extern
union) with an explicit `@sizeOf(ArgT) > @sizeOf(usize)` compile-time
reject, correct signed-width handling on both the pack (`usizeFromArg`)
and unpack (`argFromUsize`) sides, and a regression test for the exact bug
class (`.claude/rules/core.md`) found here before. CascadeOS's 649-line
extern-union rewrite is a different *implementation* of the same
contract, not a different (or more correct) *contract* — no bug or
concrete robustness gap found in Innigkeit's current version that the
union approach would close. Per DESIGN.md Part 5 (simplicity first; a
"more efficient/elegant" pattern needs to point at what it's actually
saving), rewriting a working, tested 466-line file into a structurally
different design for aesthetic reasons alone isn't justified — and a
hand-rolled reimplementation of this exact kind of bit-packing code is
exactly where a *new* bug would most plausibly get introduced. Not
ported. Status: **DONE (no action needed)**.

### Carried over — `bd48de3` interrupt-handler stub dedup — ALREADY DONE

Checked `src/architecture/x64/asm/interruptHandlers.S` before touching it:
this fix has already been implemented (by some session since the first
review pass wrote its "not done in this pass... a good small standalone
follow-up" note — that note is now stale). The file already has exactly
the target shape: one `_common_interrupt_handler` shared body (swapgs
check, 15 pushes, dispatcher call, 15 pops, swapgs check, `iretq`) and a
`INTERRUPT_HANDLER` macro emitting a 2-4 instruction per-vector trampoline
(`push` error-code-placeholder-if-needed, `push` vector number, `jmp
_common_interrupt_handler`) for all 256 vectors, with the exact same
code-size rationale comment the first pass's analysis predicted. No
further work needed here. Status: **DONE (found already implemented)**.

---

## Tier 4 — housekeeping (checked properly, per the owner's "seriously consider all tiers")

- `2539abf` `Duration.whole()` — **DONE**. Real call-site need found, not
  speculative: `time/init.zig::getUptimeMs()` already did
  `dur.value / @intFromEnum(Duration.Unit.millisecond)` by hand. Added
  `Duration.whole(unit)`, updated that call site to use it.
- `3f9b6eb` config: move debug info allocator size into config — **DONE**.
  `debug/SelfInfo.zig` hardcoded `core.Size.from(16, .mib)` inline; moved
  to `config.debug.size_of_debug_info_allocator` alongside the sibling
  `max_log_scope_len` tunable, same value, same still-open sizing TODO.
- `3879ec6` cfi directives in both `eh_frame`+`debug_frame` — **DONE, and
  more relevant here than upstream**: 17 sites across x64/arm/riscv
  (`scheduling.zig`'s task-switch trampolines, `user/root.zig`/`user.zig`'s
  syscall entry/exit, the x64 interrupt handler stubs, the arch interface
  files) only emitted CFI into `.debug_frame`. Innigkeit's `debug/
  SelfInfo.zig` implements a **real, working** self-unwinder that reads
  unwind info at runtime from the loaded `.eh_frame` section — CascadeOS's
  own equivalent is still all-`TODO`/`@panic`, so this bug's practical
  impact (a backtrace through any of these trampolines finding zero
  unwind info) is more real for Innigkeit than for its source. Added
  `.eh_frame` to every `.cfi_sections` directive.
- `13b8c49` build: use debug image builder — **DONE**. `build/Tool.zig`
  had `normal_exe`/`release_safe_exe` only (matching CascadeOS's pre-fix
  state exactly); added `debug_exe`, switched `image_builder` (rebuilt on
  every `core`/`filesystem` touch) from ReleaseSafe to Debug in
  `build/ImageStep.zig`, kept `limine_install` on ReleaseSafe (rebuilds
  rarely). Pure build-time DX, matches `docs/verification-and-ci.md` §6's
  already-tracked "developer experience, partially addressed" gap.
- `46cee6d`/`ed74640`/`382ceeb` — uacpi 6.0.0, Limine v12.4.2/v12.5.1
  bumps. **Not done, deliberately**: version-bump housekeeping with its
  own regression risk (the Limine bump alone touched boot/limine
  interface code upstream) — a separate maintenance task from a
  code-correctness review, not bundled in blind. Flagged as a follow-up
  task if the project owner wants it done.

All verified: `zig build check`/`build_all` clean, `zig build verify
-Darm=true` → x64 158/158, arm 112/112 (14 skipped) — unchanged baseline.

---

## Design-decision item (flagged, not resolved unilaterally)

### Enum-conversion family (`7b3ab6a` Size, `dc15540` Bitfield, `018fba2`
PageCount, `c43ca22` addresses, `3c6d66b` PageTable.Entry.Raw, `8427b15`
Duration)

CascadeOS converted its `extern struct { value: T }` newtypes to
`enum(T) { _ }` wrappers, repo-wide. Same philosophical move as DESIGN.md
Part 1 ("make illegal states unrepresentable") but a wide-blast-radius
mechanical refactor (every file touching `Size`/`Duration`/addresses),
not a bugfix. Per the project owner's direction: **prototyped on
`core.Size` only**, not repo-wide.

### Prototype result — DONE, clean, but bigger than "just size.zig"

`library/core/size.zig`/`testing.zig` converted mechanically (same shape
as CascadeOS's `7b3ab6a`: `.value`/`.{ .value = ... }` become
`@intFromEnum`/`@enumFromInt`). The real work was everywhere else: **45
files** touched a `Size` value's `.value` field directly instead of going
through a method, spanning address ranges/mixins, both x64 and arm
`PageTable.zig`'s entry-array alignment, memory arena/cache/heap/page,
PCI ECAM, ELF header/program-header parsing (security-sensitive bounds
checks, read and converted carefully rather than blindly), the debug
self-unwinder, ACPI, the GPU buffer capability, the disk-image-builder
tool, and both kernel root files' `std.Options` page-size wiring.

Two things worth recording about *how* it went, not just the size of the
diff:
- **The compiler's lazy analysis made this a multi-round process, not a
  one-shot sed.** `zig build check` alone missed several sites that only
  `test_x64`/`test_arm`/`build_all` reached (a test block's own
  `page.multiplyScalar(3).value`, a `RawCache.zig` arithmetic path only
  hit by the large-item-cache branch, a couple of ELF offset fields) —
  the exact "uncalled/unreached code hides a compile error" gotcha
  `.claude/rules/core.md` already documented for hand-written logic bugs
  applies just as much to a mechanical type swap. Each round found a
  strictly smaller set; the full `zig build verify -Darm=true` pass was
  what finally confirmed zero were left, not `check` alone.
- **No behavioral bugs found or introduced** — every fix was a pure
  `.value` → `@intFromEnum(...)` / `.{ .value = x }` → `@enumFromInt(x)`
  mechanical substitution, verified line-by-line against the actual
  declared type at each site (not blind regex — a few sites share a field
  name like `.offset`/`.size` with unrelated non-`Size` types, e.g.
  `KernelVirtualAddress.value`, `std.atomic.Value(u64)`'s own `.value`,
  and those were left untouched).

Verified clean: `zig build check` (all 5 targets, Debug and ReleaseSafe),
`zig build build_all` (real link builds x64/arm/riscv), `zig build
test_native`, `zig build verify -Darm=true` → x64 **158/158**, arm
**112/112 (14 skipped)** — identical to the pre-conversion baseline.

**Tradeoff for extending this to Duration/Bitfield/PageCount/addresses/
`PageTable.Entry.Raw` (not done, still the project owner's call):**
- *For*: consistent with DESIGN.md Part 1's "make illegal states
  unrepresentable" — an `enum(T){_}` wrapper is exactly as strong a
  newtype as the `extern struct{value: T}` it replaces (still blocks
  accidental raw-integer arithmetic without going through a method), and
  CascadeOS's own motivation (avoiding a struct literal `.{ .value = x }`
  at construction sites, which reads less like "this is a distinct unit"
  than `.from(x, .unit)` does) is a real, if modest, clarity gain.
  Extending the *pattern* consistently across every newtype (rather than
  leaving `Size` alone as an enum while `Duration`/addresses stay extern
  structs) also removes an inconsistency this prototype would otherwise
  introduce permanently.
  - *Against*: this prototype alone touched 45 files for one type;
  `Duration`/addresses/`PageTable.Entry.Raw` are each independently
  pervasive (addresses arguably more so than `Size`, given every
  pointer-adjacent computation in the kernel touches one), so extending
  fully would be several times this diff's size, for a benefit that is
  static-analysis-only (an `extern struct{value: T}` already prevents the
  raw-integer-confusion class of bug at the type level; the enum wrapper
  doesn't close a gap the struct left open, it just makes the "this is a
  distinct unit, not an int" signal slightly harder to defeat
  accidentally). Real regression risk during the transition itself (this
  prototype needed 7 rounds of `zig build check`/`test_x64`/`test_arm` to
  reach zero errors) scales with the number of files touched.
  - **Recommendation if asked to decide**: extend one more type
  (`Duration` is the next-most-mechanical, per CascadeOS's own `8427b15`)
  as a second data point on how the multi-round-compile pattern holds up
  before committing to all five remaining types in one pass — but this is
  exactly the kind of call DESIGN.md Part 5 says to flag rather than
  resolve unilaterally, so left for the project owner rather than done
  here.

---

## Session log

**2026-09-09 — Stage A.** Environment orientation: `qemu-system-x86_64`
was missing from the container (only `qemu-system-arm`/common/data/gui
packages were present, not `qemu-system-x86`) — installed via
`apt-get install qemu-system-x86` (pulls in `ovmf`/`seabios` too).
`zig build check` confirmed clean (exit 0) after. Full triage of all 29
new commits + the carried-over `bd48de3` against Innigkeit's actual code
(not just commit subjects) done before writing this plan; findings above.
Project owner approved proceeding on all tiers, this tracking-doc
convention, and prototyping the `Size` enum conversion (not repo-wide).

**2026-09-09 — Stages B-G, all done.** All tiers executed and verified,
9 commits on `claude/stoic-cori-fr20cc` (not pushed, per this repo's
convention):

1. **Tier 1** (4 confirmed real bugs): `RwLock.tryWriteLock` TOCTOU race,
   PCI `initializeECAM` leak/UB on OOM, `heap/c.zig`'s uncalled
   `mallocWithNonSizedFree`/`nonSizedFree` (found *two* real bugs once a
   round-trip test finally forced analysis: the known `.value`/`usize`
   mismatch, plus a previously-undiscovered wrong comptime-assert
   comparison operator), `testing.expectSize`'s wrong argument to
   `Size.of`.
2. **Tier 2** (4 mechanical improvements): `Parker` lock ordering,
   `TicketSpinLock` interrupt-disabled window, `SingleSpinLock` TTAS,
   `WaitQueue.pop()` replacing `firstTask()`+`wakeOne()`.
3. **Tier 3** (investigated in full, not pattern-matched): FlushRequest
   cluster (ported the one applicable piece, the `flush_request` EOI
   timing fix; confirmed the rest doesn't apply to Innigkeit's already
   more defensive design), page-size consolidation (3 hardcoded 4096s →
   1 named constant), `std_override`/`TypeErasedCall` comparisons (both
   confirmed Innigkeit already ahead, no action).
4. **Carried-over item** (interrupt-handler stub dedup from the first
   review pass): found already implemented by a prior session — the old
   "not done yet" note was stale.
5. **Size-enum prototype**: `core.Size` converted from
   `extern struct{value: u64}` to `enum(u64){_}`, propagated through 45
   call sites tree-wide. Tradeoff writeup for extending to the other four
   types (`Duration`/`Bitfield`/`PageCount`/addresses/
   `PageTable.Entry.Raw`) left for the project owner, per direction.
6. **Tier 4** (checked properly per "seriously consider all tiers", not
   skipped): `Duration.whole()` (real duplicated call site found),
   config-izing the debug-info allocator size, `.eh_frame` CFI (a real,
   more-relevant-here-than-upstream fix given Innigkeit's working
   self-unwinder), and a debug-mode `image_builder` tool build (DX only).
   Dependency bumps (uacpi/Limine) deliberately left as a separate,
   not-bundled follow-up task.

**Verification**: every commit individually validated with `zig build
check` + `zig build test_x64`/`test_arm`, and the whole pass closed out
with `zig build verify -Darm=true -Dtpm=true`: x64 **175/175 (2 skipped)**,
arm **129/129 (31 skipped)**, `build_all` (real link builds, validates the
inline-asm CFI changes) clean, `test_native` clean, `ReleaseSafe` `check`
clean. Zero regressions from the pre-pass baseline at every step.

**Not done, explicitly**: the enum-conversion extension beyond `Size`
(owner's call), the uacpi/Limine version bumps (separate maintenance
task). Both recorded above with reasoning, not silently dropped.

---

## Extension pass: all four remaining enum conversions + both dependency bumps

Project owner's follow-up direction: "commit to all four, do the dependency
bumps, combine all the patches, and then tell me which commits you think
you can do better or didn't implement." Executed in full — 7 more commits
on `claude/stoic-cori-fr20cc` (18 total on the branch now, still not
pushed):

1. **`bitjuggle.Bitfield`** → `enum(FieldType){_}`. Zero external call
   sites touched `.dummy` — smallest of the five conversions.
2. **`memory.PhysicalPage.Index`... no, `PageCount`** → `enum(u32){zero,_}`.
   One external call site (`Entry.zig`) plus internal asserts/prints.
3. **`core.Duration`** → `enum(u64){_}`, keeping the earlier-added
   `whole()`. 11 files touched. Two (`testing/integration.test.zig`,
   `testing/smp.test.zig`) were only caught by the real `test_x64`/
   `test_arm` QEMU build, not `check`/`build_all` — the exact
   `.claude/rules/build.md` test-block-discovery gap, hit here for the
   first time this pass.
4. **x64 `PageTable.Entry.Raw`** → `enum(u64){zero,_}`, plus the six
   `getAddress*`/`setAddress*` `PhysicalAddress` helpers in the same file
   and `Cr3.zig`'s `writeAddress`.
5. **Addresses** (`KernelVirtualAddress`/`UserVirtualAddress`/
   `PhysicalAddress`) → `enum(usize){_}` each; `VirtualAddress` itself
   stays the `extern union` it already was (it has to be reinterpretable
   as either a kernel or user address without copying, which an enum
   can't express). `AddressMixin`/`RangeMixin` gained a `toValue`/
   `fromValue` polymorphic switch so the shared mixin code serves both the
   union and the three enums. This was the largest of the five (33 files)
   and needed **six separate rounds** of `zig build check` before it went
   clean, then a further round caught by `zig build verify -Darm=true
   -Dtpm=true` alone (two more `test`-block sites, in
   `capabilities/types/GpuBuffer.zig` and
   `memory/page/BuddyAllocator.zig` — same discovery gap as Duration,
   twice in one pass now). One near-miss: a blind `sed` across
   `x64/instructions.zig`'s PCI I/O functions correctly converted six
   `KernelVirtualAddress` sites but also matched `invlpg`'s
   identically-shaped `[address] "r" (address.value)` line, whose
   parameter is the *union* `VirtualAddress` — caught by rereading the
   function signature immediately after, reverted that one line. No
   version of this landed in a commit; still worth naming as a live risk
   pattern for this codebase (converted-enum and not-yet-converted-union
   address types share identical field-access syntax in several places).
6. **uacpi 5.0.0 → 6.0.0**. Diffed upstream's real headers directly
   (5.0.0..6.0.0 tags) rather than assuming CascadeOS's own `46cee6d`
   (which bumps from *4.0.0*, a different starting point, and is a
   ~375-line wrapper rewrite) applies verbatim — it doesn't; the actual
   5.0.0→6.0.0 delta is three header-hygiene changes and a version macro.
   One break: `uacpi.zig`'s trailing `@sizeOf(acpi.Address) ==
   @sizeOf(c.acpi_gas)` assert stopped compiling once `io.h` forward-
   declared `acpi_gas` instead of fully defining it. Removed the assert
   (matching CascadeOS's own `46cee6d` resolution) rather than adding
   `acpi.h` back to route around a change uACPI's authors made
   deliberately.
7. **Limine `limine_bin` v12.3.3 → v12.5.1**. `ed74640` (→v12.5.1) is a
   pure version bump; `382ceeb` (→v12.4.2) has the real delta: `MP.Flags`
   split arch-specific (x2apic only exists on x86-64 upstream now) and
   `InternalModule._string`/`File._string` went from `?[*:0]const u8` to a
   non-optional `[*:0]const u8` (empty string is the new "no string"
   sentinel). Ported both; carried forward four doc-comment wording
   updates from the same protocol commit. `File.zig`'s `tftp_ipv4: [4]u8`
   (the *other* half of the v12.4.2 protocol change) was already in this
   shape before this pass touched the file — confirmed by `root.zig`'s
   own protocol-commit doc comment already citing v12.4.2's exact
   upstream hash, so some earlier work had partially anticipated this
   bump without finishing it.

**Verified after each commit individually and again at the end**: `zig
build check`/`build_all` clean on x64/arm/riscv, `zig build verify
-Darm=true -Dtpm=true` → x64 **175/175 (2 skipped)**, arm **129/129 (31
skipped)** — exact pre-extension baseline, zero regressions across all 7
commits. Also ran `zig build verify -Dsecboot=true`: the suite itself
gracefully skips in this sandbox (no `sbsigntool` on `PATH`, a pre-existing
environment gap, not caused by this work) but the base x64 suite it runs
first passed 158/158, confirming the new Limine binaries still produce a
bootable, working UEFI System Table.

All 18 commits from this pass (the original 11 plus these 7) combined into
one `git am`-able patch series, verified to reproduce a byte-identical
tree against the branch from a clean checkout of the pre-pass commit.

### Self-critique — what I'd flag as weaker points or open follow-ups

Asked for directly by the project owner; recorded here rather than only
spoken, per this doc's own "resume from this file alone" convention.

- ~~**FlushRequest EOI-timing fix (item 9, tier 3) is verified only by
  general test stability, not a targeted regression.**~~ **FIXED**
  (follow-up pass, on direct request). Added
  `testing/FlushRequest.test.zig`, pinning the `flush_request` vector's
  registered EOI timing via a new generic introspection hook
  (`architecture.interrupts.eoiTimingForVectorForTesting`, following the
  existing `eoiType` optional-function pattern). Verified the test
  actually catches the regression by deliberately flipping `.eoi` back to
  `.after` and rerunning `zig build test_x64`: this **crashed the kernel
  outright** (an invalid kernel-mode read partway through the test suite),
  not just failed the assertion — under this project's default `-smp 4`,
  plain QEMU/TCG, no special hardware. This contradicts the assessment
  directly above (and the original tracking-doc claim): the bug's
  reachability was underestimated — it turns out at least one symptom of
  reverting this fix reproduces with nothing more than the project's own
  default test invocation, not real multi-socket hardware or a dedicated
  stress harness. The exact fault mechanism (why a delayed EOI on this one
  vector corrupts kernel state badly enough to fault, rather than more
  narrowly dropping/delaying a flush) wasn't root-caused beyond
  reproducing it — flagged as a genuine follow-up in the test file's own
  comment.
- **The addresses conversion took six rounds of `check` before I reached
  for the full verify gate.** This project's own docs
  (`.claude/rules/build.md`, `.claude/rules/arm.md`) already document the
  test-block-discovery gap in detail, and I'd *already* hit it once this
  same session (Duration, two files) before hitting it *again* on
  addresses (two more files) — I should have started running `zig build
  verify -Darm=true -Dtpm=true` earlier in each conversion's cycle instead
  of treating a clean `check` as a stopping point I had to be surprised
  out of a second time. The outcome was fine (all sites found, zero
  regressions), but the process cost more round trips than it needed to.
- ~~**uacpi 6.0.0: the removed `acpi_gas` size assert isn't replaced with an
  equivalent check.**~~ **FIXED** (follow-up pass, on direct request).
  Investigated where the equivalent guarantee actually lives rather than
  adding a redundant hardcoded assert: uACPI's own `acpi.h` already
  carries `UACPI_EXPECT_SIZEOF(struct acpi_gas, 12)`, a real C
  `_Static_assert` that fires on every real build (confirmed every `.c`
  file `custom.zig` compiles that includes `acpi.h` does so
  unconditionally, not behind a flag), and `acpi.Address`'s own comptime
  block already independently asserts the same 12-byte figure. Both
  checks land on 12 by construction; documented the connection in both
  files (`acpi/uacpi.zig`'s trailing comptime block, `acpi/Address.zig`'s
  own) instead of leaving a future reader to wonder why the old
  cross-struct assert disappeared with nothing replacing it.
- **The original tradeoff writeup's own recommendation ("extend one more
  type as a data point before committing to all five") was more
  conservative than what actually got asked for and executed.** The
  predicted cost (multi-round compile churn scaling with files touched)
  did materialize — roughly 20+ individual call-site fixes across the
  four extended types, concentrated in the addresses conversion — but it
  resolved cleanly with zero regressions at every step. Worth naming
  plainly: the caution in that writeup was reasonable given what was known
  then, and the actual outcome ended up fine, but I didn't push back or
  re-flag the risk when told to do all four at once — I just executed,
  which was the right call once the owner had the tradeoff in front of
  them and decided.
- **Limine bump: the arm side of the `MP.Flags` split isn't exercised by
  anything meaningfully different from before.** ARM is single-core in
  this project today (SMP is M3, not yet implemented), so the new
  all-reserved `Flags{}` on arm/riscv compiles and boots but was never
  going to exercise different behavior than the old shared struct did
  (arm never read or set the `x2apic` bit). The x86-64 side did get real
  coverage: `zig build verify` runs with `-smp 4` by default, so the
  `x2apic = true` path bootstrapped 4 cores successfully. Not a gap I
  introduced, just worth being precise about what "verified" actually
  covered here.

### Items from the original 29-commit list still not implemented — full explanations

Expanded on direct request into complete explanations (not just the
one-line summary this section used to carry), each grounded in the
actual CascadeOS diff re-read from a restored local clone, not
paraphrased from memory.

#### `bcdb4d2` — "lib/cascade: override as much of std as possible"

What the commit actually does: adds `lib/cascade/std_override.zig`, a
62-line new file providing `std_options`/`debug`/`heap`/`os`/`panic`
overrides for CascadeOS's userspace `std` integration. Reading the file
in full: almost every function body is either a bare `// TODO` comment
next to a `_ = arg;` discard, or an explicit crash placeholder —
`debug.handleSegfault` unconditionally `@panic("SEGFAULT")` after
discarding all three of its parameters; `std_options.debug_io: std.Io =
undefined`; `os.heap.page_allocator: std.mem.Allocator = undefined`;
`panic` discards both its arguments and calls a bare `@trap()`. The one
real piece of logic is `heap.page_size_min`/`page_size_max`, wired to a
real `cascade.page_size` constant.

Innigkeit's equivalent (`library/innigkeit/interop/root.zig` +
`interop/debug_io.zig`) is not a comparably-staged skeleton: `pub const
panic` writes a `"PANIC: <msg>\n"` line to stderr via the real write
syscall and then calls `exit_process` — no `undefined`, no bare `@trap()`.
`std_options.logFn` formats and routes real `std.log` calls to stderr
through the same path, including a level/scope prefix and level filtering
via an optional `root.log_level` override. `debug_io.zig`'s `std.Io`
value is a genuinely working VTable (not `undefined`): real syscall-backed
`futexWait`/`futexWaitUncancelable`/`futexWake`, `crashHandler` (exits the
process instead of trapping), cancellation-protection state, and a real
`std.Io.File.Writer`-backed stderr drain — confirmed by reading the file's
full ~260 lines, not just its exports. The specific pieces CascadeOS's
skeleton names but leaves as `TODO` (`FilePermissions`, `cwd`,
`debugInfoSearchPaths`, `debug.SelfInfo`, `debug.handleSegfault`) have no
counterpart anywhere in `library/innigkeit`, and that absence is itself
deliberate rather than an oversight: `interop/root.zig`'s own doc comment
states `std.fs` is unsupported for `.os = .other` by design (initfs and a
future VFS capability cover file access instead), and Innigkeit ships its
own complete panic handler rather than depending on `std.debug`'s default
crash/symbolication machinery that `debugInfoSearchPaths`/`SelfInfo`/
`handleSegfault` exist to support.

**Why not ported**: there is nothing to port. This is a genuine
"Innigkeit is ahead of what CascadeOS had at this specific commit"
finding, not a missed improvement — porting a `TODO`-stub skeleton over a
working implementation would be a regression, not an upgrade. If
CascadeOS's own `std_override.zig` has since matured well past this
commit, that later state was not checked (out of scope for a review pass
anchored to this specific commit range) and would be worth a fresh look
on its own terms, not by re-reading `bcdb4d2` again.

#### `a2d360f` — "core/TypeErasedCall: use an extern union to reduce casting"

What the commit actually does: a 649-line rewrite of
`lib/core/TypeErasedCall.zig` (plus ~40 lines of call-site churn in
`kernel/arch/`, `kernel/cascade/task/`, `kernel/cascade/user/`). The
representational change: `args: [supported_number_of_args]usize` becomes
`args: [supported_number_of_args]Arg`, where `Arg` is a new `extern
union` covering every supported argument category directly (rather than
`usize`-bit-casting every argument in and out via helper functions).
Alongside this, the commit **drops** the old `ReturnType` enum
(`void`/`noreturn`/`void_error_union`/`noreturn_error_union`) and its
`isNoReturn()` helper entirely — `TypeErasedCall`'s doc comment no longer
describes support for a function returning `!void`/`!noreturn`, only
plain `void`/`noreturn`. In exchange, the type-support table grows
(`void`, `null`, `undefined`, vectors, and error unions as argument types,
not just as the function's own parameters) and the "never supported" list
becomes explicit (slices, `type`, `noreturn` as a parameter, comptime
types, `fn`, `opaque`, `anyframe`, `enum_literal`).

Innigkeit's current `library/core/containers/TypeErasedCall.zig` still has
the pre-rewrite shape confirmed by direct comparison: `args:
[supported_number_of_args]usize`, `ReturnType`/`isNoReturn()` both
present, `typeErasedFn` still returns `struct { TypeErasedFn, ReturnType
}` and still handles a function returning an error union (panicking on
"unhandled error" per its own doc comment, matching CascadeOS's pre-fix
behavior exactly). Read in full (both `usizeFromArg`/`argFromUsize`
directions, the per-arity dispatch, the existing signed-enum regression
test) — the implementation is internally consistent, handles every
argument category the doc comment claims, and has a passing regression
test for the exact "bug class" (`.claude/rules/core.md`) this general
area of the codebase has been bitten by before.

**Why not ported**: this is a different *implementation* of the same
*contract* CascadeOS's rewrite chose (an extern union stored directly vs.
usize-bit-cast helpers), not a bug fix — no concrete correctness gap in
Innigkeit's version was found that the union approach would close, and
the rewrite actively *removes* a capability (error-union-returning
functions via `ReturnType`) that Innigkeit's version still supports and
that at least one real call site could plausibly still need (not checked
exhaustively, since the port itself wasn't undertaken — but the removal
alone is a reason to treat this as a design trade, not a strict upgrade).
DESIGN.md Part 5's "simplicity first, don't add generality current call
sites don't need" reads the same way in reverse here: rewriting a
working, tested 466-line file into a structurally different design for a
"reduces casting" aesthetic win, with no reproducible bug driving it,
is exactly the kind of change where a hand-rolled reimplementation of
bit-packing/type-erasure code is most likely to introduce a *new* subtle
bug rather than fix an old one. If a concrete need for the union
representation's extra argument-type support (vectors, error unions as
*arguments* rather than as the templated function's return) ever
surfaces at a real Innigkeit call site, that would be the trigger to
revisit this — not the mere existence of CascadeOS's rewrite.

#### The FlushRequest three-commit history — full corrected chronology

The original tracking-doc entry described this as a "three-commit dance"
(`53e4e14`, `ae237e2`, `7e14f7f`) without fully working out their actual
causal order. Re-derived properly from `git log --oneline -- kernel/cascade/mem/FlushRequest.zig`
plus reading `submitAndWait`'s exact body at each commit (not just each
commit's own diff in isolation, which is misleading here since the
subject lines don't sort chronologically the way they read):

1. **`22624e5`** ("require interrupt enabled during flush", the actual
   start of this sequence) rewrites `submitAndWait` from an older design
   (branch on `interrupt_disable_count`: spin if enabled, call
   `processFlushRequests()` directly if disabled — structurally
   *identical* to Innigkeit's current design) to a new one: assert
   (debug-only) that interrupts are always enabled on entry, then
   **unconditionally** call `processFlushRequests()` in the wait loop
   regardless of interrupt state. Rationale given in the commit message:
   "This allows us to replace the spinloop with blocking eventually." This
   introduces a real reentrancy hazard: if the `flush_request` IPI fires
   on this same executor while the wait loop is mid-`processFlushRequests()`
   drain of `executor.flush_requests` (a bare `std.SinglyLinkedList`), the
   interrupt handler's own drain and the wait loop's drain can observe and
   mutate the same list concurrently on the same core.
2. **`6560278`** ("restructure the entire API") — a pure rename pass
   through this function (`arch.interrupts.sendFlushIPI` →
   `executor.arch_specific.flushRequestNotify()`, an unrelated
   IPI-dispatch mechanism rename); the reentrancy-hazard shape from
   `22624e5` carries through unchanged.
3. **`ae237e2`** ("fix multi-core regression") is the actual fix for that
   hazard: reverts the wait loop's `processFlushRequests()` call back to
   a bare `arch.Executor.current.spinLoopHint()`, closing the reentrancy
   window by never draining the queue from two places on one core again
   — at the cost of losing forward progress if the caller happens to have
   interrupts disabled (the case `22624e5`'s assert was there to rule
   out, but which the assert alone doesn't *prevent*, only diagnoses in
   debug builds).
4. **`53e4e14`** ("support flush in interrupt context") drops the
   interrupt-enabled assert entirely and puts `processFlushRequests()`
   back in the wait loop — deliberately re-doing what `ae237e2` had just
   reverted, but this time with the actual root cause fixed alongside it:
   `processFlushRequests()` itself now wraps its whole body in
   `current_task.incrementInterruptDisable()`/`decrementInterruptDisable()`,
   so draining the queue from the wait loop structurally cannot race the
   real interrupt handler's own drain on the same core anymore — the
   reentrancy hazard `22624e5` introduced and `ae237e2` had to work around
   is closed at its source instead.

Innigkeit's `memory/core/FlushRequest.zig` (read again in full for this
explanation, not just re-cited from the earlier summary) never went
through any of this: `submitAndWait` still has the `22624e5`-*predates*
shape — branch on `current_task.task.interrupt_disable_count.load(.acquire)
== 0`, spin-only when enabled (relying entirely on the real IPI handler to
drain the queue), call `processFlushRequests()` directly only when
already disabled on entry. Because the interrupts-enabled path here
*never* calls `processFlushRequests()`, and the interrupt-disabled path is
only ever entered with interrupts already off for the whole wait (nothing
toggles them mid-loop), the same-core reentrancy hazard `22624e5`
introduced has no foothold: exactly one of "spin and let the IPI handler
drain" or "interrupts are off, drain directly" is active for the entire
wait, chosen once at entry, never both. Innigkeit's `processFlushRequests()`
itself does not additionally wrap its body in an interrupt-disable pair
the way CascadeOS's `53e4e14` version does — but it doesn't need to, since
every call site into it already guarantees interrupts are off before
calling. This is arguably a cleaner resting state than CascadeOS's
`53e4e14` end state (which unconditionally calls `processFlushRequests()`
from the wait loop and relies on a fresh interrupt-disable/enable pair
*every iteration* for safety, rather than picking one safe strategy for
the whole wait) — not merely "not affected by the same bug," but a
design that was never going to need `22624e5`'s rewrite in the first
place.

**Why not ported**: nothing to port. `22624e5`'s rewrite (the thing
`ae237e2`+`53e4e14` exist to fix the fallout of) never happened to
Innigkeit's `FlushRequest.zig`, so there is no regression here to chase.
The EOI-timing fix (`7e14f7f`'s equivalent, tracked separately above) is
the one genuinely independent finding in this cluster and was ported.

#### The three longer-term goals mentioned earlier this session — still untouched, by design

Separate from the CascadeOS-commit comparison above: earlier in this same
session, before the "commit to all four, do the dependency bumps" request,
three longer-range work areas were named in an overview as things nobody
had asked to start yet: `.claude/`-and-docs future-proofing (keeping the
rules/skills/tracking-doc conventions this whole review pass leaned on
healthy and current as the codebase grows), Raspberry Pi bring-up + SSH
access (a real hardware target beyond QEMU, plus a way to reach it
remotely), and general "polishing" (no more specific scope was ever
attached to that word than the label itself). None of these are CascadeOS
commits to diff against — they were never investigated in enough depth to
have a concrete plan, just named as directions. They remain untouched
because nothing in this session (including the current request) asked for
them to start, matching this project's explicit "only pursue what's been
explicitly asked" instruction — not because they were considered and
rejected. Any of the three would need its own scoping pass before real
work could start (especially Raspberry Pi bring-up, which is a
new-hardware-target effort comparable in size to the existing arm/riscv
ports, not a small addition).
