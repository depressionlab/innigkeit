# Upstream/inspiration review: findings and staged plan

This is the record of a comparison pass against four external projects, done
to feed a broader style/security/API/optimization review of Innigkeit. It is
a rewrite-in-progress companion to `docs/test-harness-plan.md` — same
convention: grounded findings, staged and sequenced, nothing here is
implemented yet unless explicitly marked done.

Sources: `CascadeOS/CascadeOS` ("our main upstream" — a Zig 0.16.0 hobby OS,
accessed via a `depressionlab/cascadeos` fork added to this session, full
clone, real `git diff`/`git log`, not summarized), `Khitiara/disk-image-step`
(zig-0.16.0 branch, now renamed "Dimmer"), `xor-bits/hiillos` (a capability
microkernel, closer in spirit to Innigkeit than CascadeOS is), and
`Khitiara/imaginarium` (a small NT-style hobby kernel, codeberg mirror
blocked at the network-proxy level, used the GitHub mirror instead).

---

## Karpathy guidelines (hard-coded here so a context compaction can't lose them)

**1. Think Before Coding** — Don't assume. Don't hide confusion. Surface
tradeoffs. State assumptions explicitly; if uncertain, ask. If multiple
interpretations exist, present them, don't pick silently. If a simpler
approach exists, say so — push back when warranted. If something is
unclear, stop, name what's confusing, ask.

**2. Simplicity First** — Minimum code that solves the problem, nothing
speculative. No features beyond what was asked. No abstractions for
single-use code. No "flexibility" that wasn't requested. No error handling
for impossible scenarios. If it could be a quarter of the size, rewrite it.
Ask: "would a senior engineer call this overcomplicated?"

**3. Surgical Changes** — Touch only what you must; clean up only your own
mess. Don't "improve" adjacent code, comments, or formatting. Don't refactor
things that aren't broken. Match existing style even if you'd do it
differently. Note unrelated dead code instead of deleting it. Remove only
imports/vars/functions your own change orphaned. Every changed line should
trace directly to the request.

**4. Goal-Driven Execution** — Define success criteria, loop until verified.
"Add validation" → "write tests for invalid inputs, then make them pass."
"Fix the bug" → "write a test that reproduces it, then make it pass." State
a brief plan with a verify step per stage.

**Explicit implication for this document**: nothing below is "adopt because
upstream did it." Every item states *why* it applies to Innigkeit
specifically, and several items below were investigated and explicitly
rejected or deferred because Innigkeit's own design turned out to be more
sophisticated, or the tradeoff didn't actually transfer. That is the
intended outcome of applying guideline #1 to an upstream-comparison task,
not a failure to find things to merge.

---

## CascadeOS: full triage of `1e8ac55b..main` (49 commits, 115 files, +5718/-4881)

Real numbers from a full clone (`depressionlab/cascadeos`), not a WebFetch
summary. Directory concentration: `kernel/arch/{x64,riscv,arm}` (43 files —
a multi-arch API restructuring), `kernel/cascade/mem` (8), `build` (7),
`kernel/cascade/sync` (5).

CascadeOS itself, for calibration: a general-purpose (not capability-based)
kernel, plain FIFO round-robin scheduler (no EEVDF), conventional
process/thread/ELF-loader machinery with no Endpoint/Notify-style IPC found,
and no code-signing/entitlements/Secure Boot/TPM anywhere. It diverges
sharply from Innigkeit's core differentiators (capabilities, EEVDF, codesigned
spawn, measured boot) — most of its value here is in low-level mechanics
(page faults, TLB shootdown, lock layout) that are architecture-philosophy
-independent, not in kernel-design prior art.

### CRITICAL — real, exploitable-class security gap on x64 (and arm)

- **`user_memory_range` does not exclude the top boundary page — the exact
  SYSRET non-canonical-RCX privilege-escalation class of bug (historically:
  CVE-2012-0217/CVE-2012-0056 and siblings, affecting Xen/*BSD/Windows/Linux
  circa 2012).** On x86-64, `sysret` restores `RIP` from `RCX`; if that value
  is non-canonical, the CPU raises `#GP` **before** the privilege level
  actually drops to CPL3 — i.e. the fault is taken while still effectively in
  a kernel-privileged transitional state, which is the classic primitive this
  bug class escalates from. CascadeOS's commit `61e4369b` ("exclude the last
  valid page from the user memory range") fixes exactly this: it changed
  `user_memory_range` (and, defensively, `kernel_memory_range`) on **every
  architecture** from `size_of_address_space_half = canonical_region_size -
  page_size` (leaving the range ending *exactly at* the canonical/non-
  canonical boundary, e.g. `2^47` on x64) to explicitly subtracting a second
  page so the range's top edge sits one page *below* that boundary. The
  commit's own rationale: "this prevents a nasty situation on x64 where the
  last bytes of the user range is a syscall instruction which causes a
  general protection fault in the kernel when executing sysret as the return
  address is non-canonical."

  **Checked against Innigkeit's actual code — we have the exact pre-fix
  formula, unchanged, on both x64 and arm:**
  `src/architecture/x64/interface.zig:176`:
  `size_of_address_space_half = Size.from(128, .tib).subtract(small_page_size)`,
  used for both `.kernel_memory_range` (line 189) and `.user_memory_range`
  (line 208) — the *same variable name* CascadeOS's pre-fix code used. This
  computation excludes only the null page at the bottom; `user_memory_range`
  extends all the way up to exactly `128 TiB` (`2^47`), the canonical
  boundary itself, with no page excluded at the top. `src/architecture/
  arm/interface.zig:230` has the identical single-subtract pattern (`256
  TiB` region there). Have not yet checked riscv's equivalent file, but
  given the pattern is copy-pasted per-arch, it should be assumed to have
  the same gap until checked.

  If a user process can place an executable mapping (or its stack/heap) at
  the very top of its address space and arrange a `syscall` instruction such
  that the saved post-syscall return address (used by the kernel's eventual
  `sysret`) lands at or past the boundary, the kernel's `sysret` back to
  userspace raises `#GP` in the transitional state described above. Nothing
  in the code reviewed so far prevents a user mapping from reaching the
  exact top edge of `user_memory_range` today.

  **This was not implemented in this pass** — it's a real change to a
  security-load-bearing constant on every supported architecture and
  deserves explicit sign-off and its own careful verification (confirm the
  exact canonical-boundary math per arch, confirm nothing currently depends
  on the range extending exactly to the boundary, re-run the full verify
  gate on x64 **and** arm since both are affected). Flagged here at the top,
  ahead of every other finding in this document, because of what it is.

### High priority — concrete, verified against our own code, ready to act on

- **`FlushRequest` uses `.monotonic` ordering on the shootdown counter — a
  real TLB-shootdown race.** CascadeOS's commit `22624e57` (and the
  surrounding cleanup in `2bb8f73b`) rewrote their `FlushRequest.zig` from a
  structure that is **near-identical to Innigkeit's own
  `src/innigkeit/memory/core/FlushRequest.zig`** (same field names, same
  `count`/`nodes`/`requestExecutor`/`flush` shape — strong evidence of shared
  lineage). The old (and Innigkeit's *current*) code does
  `self.count.fetchSub(1, .monotonic)` in the remote executor's `flush()` and
  `self.count.load(.monotonic)` in the local spin-wait — `.monotonic` gives
  no happens-before relationship between the remote executor's actual
  `architecture.paging.flushCache(range)` and the requester observing
  `count == 0`. On x86-64's TSO model this is likely benign in practice; on
  AArch64 (Innigkeit's secondary target, SMP work still pending per
  CLAUDE.md) it is a real correctness gap once arm SMP lands, and `unmap()`
  in `memory/root.zig` frees the physical page immediately after
  `request.submitAndWait()` returns — exactly the kind of use-after-flush
  bug this ordering bug would enable. **Action**: change the `fetchSub` in
  `flush()` to `.release` and the `load` in the wait loops to `.acquire`
  (both call sites in `memory/core/FlushRequest.zig`). Small, surgical,
  correctness-only change — does not require adopting CascadeOS's larger
  refactor (single `State` struct, blocking-instead-of-spinloop TODO, the
  new debug-assert that interrupts are enabled on entry). Those are real
  ideas too but are a separate, larger change; not bundled into this fix.

- **`sync/Parker.zig`'s `unpark_attempts` and `sync/RwLock.zig`'s `state`
  are missing cache-line isolation that `Mutex`/`SingleSpinLock`/
  `TicketSpinLock` already have.** CascadeOS's `dd62fe3d`/`06f9c360` pair
  added `align(std.atomic.cache_line)` to exactly these two fields in their
  own `Parker.zig`/`RwLock.zig` (after experimenting with, then reverting
  away from, a separate leading zero-sized marker field for the *other*
  three types). Innigkeit's `Mutex.zig`/`SingleSpinLock.zig`/
  `TicketSpinLock.zig` already use a **documented, deliberate** leading
  `_: void align(std.atomic.cache_line) = {}` marker ("so the lock's atomics
  never share a cache line with a preceding field when this struct is
  embedded in a larger one") — this is *not* the same pattern CascadeOS
  settled on, and given Zig's non-`extern` structs don't guarantee
  declaration-order layout, Innigkeit's leading-marker approach is plausibly
  **more robust** than directly aligning the hot field, not less. **Do not
  copy CascadeOS's exact pattern.** Instead extend Innigkeit's *own* already-
  proven pattern for consistency: add the same leading
  `_: void align(std.atomic.cache_line) = {}` marker to `Parker.zig` (before
  `lock`/`parked_task`/`unpark_attempts`) and `RwLock.zig` (before `state`).
  Low-risk, no semantic change, closes a real inconsistency.

- **Fault isolation (from hiillos, not CascadeOS) — directly resolves the
  deferred prerequisite in `docs/test-harness-plan.md`.** hiillos's x86-64
  `#PF`/`#GP` handlers (`src/kernel/arch/x86_64.zig`) gate on
  `trap.isUser()` + a live current thread; a genuine user-mode fault with a
  live thread calls into the address space's fault handler, and on
  unrecoverable error routes to `thread.unhandledPageFault()`
  (`src/kernel/caps/thread.zig`), which first tries an optional per-thread
  registered fault-handler signal, and **only if none exists** falls back to
  killing just that thread/process (`exitRemote()` → `.dead` →
  `deinitFull()`) — other processes are unaffected, the kernel never panics.
  This is exactly the axis Innigkeit's own `memory/root.zig::onPageFault`
  currently lacks: today `process.address_space.handlePageFault(...) catch
  |err| std.debug.panic(...)` takes down the whole kernel on any
  unrecoverable user-mode fault. **This is the real prerequisite
  `docs/test-harness-plan.md` already flagged as blocking a TH-3-equivalent
  test** ("a process faults, the kernel survives"). Recommend adapting
  hiillos's two-tier approach (optional signal-to-handler, else
  kill-process-not-kernel) — the "optional fault-handler" tier could layer
  on Innigkeit's existing `Notify` primitive rather than inventing new IPC.
  This is real kernel-hardening work, touching `memory/root.zig`'s
  `onPageFault` and `AddressSpace.handlePageFault`, and the process
  kill/cleanup path — scope and design it as its own staged task (see
  "Next steps" below), not a quick patch.

### `22eae01f all: remove all uses of `.?`` (CascadeOS-wide sweep) — DONE

All 98 occurrences across 36 files converted to `orelse unreachable`, each
individually verified against its actual surrounding invariant (not a blind
regex replace — `.?` and `orelse unreachable` are semantically identical in
Zig, so the only real risk was mis-judging *which* invariant justified each
site, not the mechanics of the rewrite itself). A few sites turned out to be
more subtle than a quick read suggested and got a short comment explaining
the actual dependency rather than a blanket "obviously fine": `FaultInfo.zig`'s
`promote_to_anonymous_map` unwrap only holds because the object-backed fault
path is still an unconditional `@panic("NOT IMPLEMENTED")` — revisit if that
path is ever built out. A handful of `drivers/virtio/{blk,net}.zig` sites
used the `if (X != null) &X.? else return` idiom, which isn't just a `.?`
rename — rewrote those as `&(X orelse return)`, the correct simpler form
(the null case there is a real, expected, handled path, not an invariant
violation, so `orelse unreachable` would have been wrong). **No hidden bug
found** — unlike CascadeOS's own motivating commit message ("I think `.?`
should be removed from zig"), this really is a pure style/hygiene
improvement here, not a correctness fix, confirming the earlier
spot-check's conclusion. Verified: `zig build check` clean; `zig build verify`
x64 137/137; `zig build verify -Darm=true` 97 total/12 skipped (same
85-passed baseline) — zero regressions across every touched subsystem
(scheduler, capability table, memory fault handling, network parsers,
drivers).

### Confirmed non-issues (checked, no action needed)

- **`kernel/mem/resource_arena`'s page-count-for-packed-cache bug
  (`26187214`) — checked, already fixed.** CascadeOS's pre-fix bug computed
  `pages_to_allocate = pageSize.amountToCover(Size.of(RawCache) * count)`
  — treating the page as holding one `RawCache` when several pack per page
  (`QUANTUM_CACHES_PER_PAGE`), silently under-allocating. Innigkeit's own
  `src/innigkeit/memory/arena/Arena.zig:110-151` already has the fixed
  shape in full: sizing off `[QUANTUM_CACHES_PER_PAGE]RawCache` (with an
  explicit comment stating exactly why, matching the reasoning above), the
  `outer:`-labeled loop with `break :outer` (not a bare `break`, which would
  only exit the inner per-page loop), and the final
  `std.debug.assert(caches_created == count)` postcondition. No matching
  bug here; nothing to change.

- **`1c2461da` "fix \`safeMemcpy\` clobbers"**: CascadeOS discovered that
  Zig's `"+{reg}"` inline-asm constraint (read-write) does **not** implicitly
  add that register to the explicit clobber list — omitting it risks a real
  miscompilation (the compiler may not realize the register's prior value is
  gone). Their `rep movsb`-based `safeMemcpy` originally clobbered only
  `rax`/`memory`, missing `rsi`/`rdi`/`rcx` despite using `+{rsi}`/`+{rdi}`/
  `+{rcx}`. **Checked `src/architecture/x64/paging/root.zig:17-35` — Innigkeit's
  `safeMemcpy` already lists `.rax = true, .rsi = true, .rdi = true, .rcx =
  true, .memory = true` explicitly.** Already correct; worth recording
  given CLAUDE.md's own warning that `zig build check` does not validate
  inline assembly, so this class of bug would only surface as a hard-to-
  reproduce miscompilation, not a compile error.

- **`5e62791b`'s removal of the `enable_access_to_user_memory_count != 0`
  debug-assert** from `UserVirtualAddress.ptr()`/`UserVirtualRange.byteSlice()`
  (downgraded to a doc-comment-only requirement upstream). **Do not follow
  this removal** — `src/innigkeit/address/UserVirtualAddress.zig:26` and
  `UserVirtualRange.zig:33` still have this exact runtime assert today, and
  it should stay: a case of current upstream being *less* defensive than
  Innigkeit, not more.

- **`fa79d5a1` "remove footgun from \`Handle.block\`"**: CascadeOS's old
  `Handle.block` returned a *new* `Handle` by value that callers had to
  remember to reassign — forgetting it meant unlocking the wrong
  per-executor scheduler lock after a migration. Checked Innigkeit's
  `src/innigkeit/task/Handle.zig:182` — `pub fn block(self: *Handle, ...)
  void` already takes a pointer and mutates in place, matching CascadeOS's
  *fixed* state, not the footgun. No action needed; noted only so this isn't
  re-investigated later.

- **`ba278b09`/`9d172465`/`251e3f5e` "track user-memory access as a bool
  instead of a count"**: tempting at first glance since Innigkeit's own
  `enable_access_to_user_memory_count` (`task/Task.zig:80`,
  `task/Current.zig`) looks like the same "count that's really just a
  boolean" pattern. **Checked in depth — do not port this.** Innigkeit's
  counter is doing more work than CascadeOS's: `Current.zig`'s interrupt
  entry/exit path (`onInterruptEntry`/exit-transition code around lines
  144–180) **swaps the count to 0 and restores the saved value across
  interrupt handling**, so an interrupt firing mid-`UserAccess`-window
  doesn't see stale "access enabled" state and correctly restores it on
  return. CascadeOS's equivalent commit touches a much smaller footprint
  (2-line change to `interrupts/handlers.zig` vs. Innigkeit's dedicated
  save/restore machinery), suggesting their design doesn't carry this same
  interrupt-reentrancy responsibility on the same field. A bool would still
  need equivalent save/restore semantics and doesn't obviously simplify
  anything once that's accounted for — this is exactly a case where the
  upstream commit message's premise ("nesting should never happen") doesn't
  transfer cleanly, because Innigkeit's counter isn't really tracking
  nesting, it's tracking interrupt-safe save/restore state. Filed as
  "investigated, rejected" rather than silently skipped.

### Read in full depth, not comparison-only: the arch restructuring

- **`65602780` "restructure the entire API"** (81 files, +4639/-4323, by far
  the largest single commit in the range) was read in full — the resulting
  `kernel/arch/arch.zig` (1539 lines post-restructure), not just the diff —
  because this is exactly the API/ABI-design question worth deep
  consideration rather than a skim. **Finding: Innigkeit already has this
  design, independently, and arguably better-organized.** CascadeOS's
  restructuring reorganizes a flat arch namespace into `Executor`/
  `Interrupt`/`PageTable`/`Thread`/`SyscallFrame`/`Task` struct namespaces,
  each wrapping an `arch_specific` field with methods that dispatch through
  an optional-function-pointer table (`Functions`) validated against a
  separate required-types-and-constants struct (`Decls`), with a `getFunction`
  helper that panics with the missing function's name if an arch hasn't
  implemented it. Compared directly against Innigkeit's `src/architecture/
  {root,Functions,Decls}.zig` plus `paging.zig`/`interrupts.zig`/
  `scheduling.zig`/`user.zig`/`io.zig`/`init.zig`: **the `getFunction` helper
  is near-line-for-line identical** (including the same "must be separate
  types to avoid dependency loops" comment and the same TODO about
  imprecise error paths), the `Functions`/`Decls` split is the same idea,
  and Innigkeit's `paging.zig::PageTable` already is the
  wrapper-struct-with-`arch_specific`-field-plus-methods pattern CascadeOS's
  commit was reaching for (e.g. `PageTable.create`/`.load`/
  `.copyTopLevelInto`). Strong evidence of shared lineage, and Innigkeit's
  side of it is already at (or past) the end state CascadeOS's giant commit
  arrives at. The one real structural difference: CascadeOS groups by
  "hardware object" (`Executor.current.X`, `Thread.current.X`) inside one
  1539-line file; Innigkeit groups by "subsystem" across separate files
  (`paging.zig`, `interrupts.zig`, etc.) with three orphan free functions
  (`spinLoopHint`, `halt`, `earlyDebugWrite`) at `architecture`'s top level
  that don't have an obvious subsystem home — CascadeOS would put these
  under `Executor.current`. This is a minor discoverability/consistency
  question, not a correctness or security one, and not urgent. **No
  restructuring needed; this was the reassuring result of taking the
  question seriously rather than an item to schedule.**
- **`kernel/user` syscall-dispatch commits** (`e255117a`, `5883ce09`,
  `e17d3865`, `f598693f`, `63c1e8ce`, `6df4b798`, `437e143e`): CascadeOS
  incrementally building toward what Innigkeit's `user/syscalls.zig`
  (declarative one-row-per-syscall, comptime jump table) already is. Nothing
  to adopt; Innigkeit's version is already more mature.
- **`0f58c366`/`cd9f1515`/`86001322`/`ff333ebb`/`5064d9e3`/`b7927d58`
  (safe.memcpy family)**: CascadeOS building the same "fault-tolerant
  memcpy that returns an error instead of panicking" mechanism Innigkeit
  already has (`memory/root.zig`'s `safe.memcpy`/`safe.atomicLoadU32`/
  `ResultSlot`/`tryFixupSafeCopy`). Confirms Innigkeit already solved this;
  no adoption needed, at most worth a skim of `ff333ebb`'s `onPageFault`
  simplification for comparison once the fault-isolation work above is
  underway (same function, adjacent concern).
- **Address/range ergonomics** (`5e62791b`, `34ed4471`, `6d335fb5`,
  `317f6894`), **build tooling** (`0fc31569`, `8fe43ef0`, dependency bumps),
  **namespacing/formatting cleanup** (`98732ae8`, `3a1876bf`, `1db8a209`,
  `ca90c1d1`, `6baa23f7`): CascadeOS-specific housekeeping or minor style
  parallels to things Innigkeit's own `innigkeit.VirtualAddress`/
  `VirtualRange` types already do. No action. `34ed4471`'s `Range.subslice(
  offset, size)` helper (replacing manual `slice[offset..][0..size]`-style
  math at call sites) is a small, genuine ergonomics idea worth considering
  for Innigkeit's own range types if that manual-slicing pattern shows up
  often enough to be worth a helper — not scoped as its own stage.
- **`812c4646` "use \`mem.safe.memcpy\` to load the hello world elf"**: CascadeOS
  wrapped their ELF-segment-copy loop's raw `@memcpy` in their fault-tolerant
  `safe.memcpy`, converting a hypothetical mapping-bug panic into a clean
  error. Innigkeit's `user/elf_loader.zig::loadAndJump` (Stage 1 of
  `docs/test-harness-plan.md`, landed this session) still uses a raw
  `@memcpy` for its segment-copy loop under a `UserAccess` window. The
  destination there is freshly-mapped, kernel-controlled memory in the
  about-to-run process's own address space, so a fault there would only
  occur via an actual kernel mapping bug, not attacker-controlled input —
  low urgency, but a cheap, easy defense-in-depth follow-up: swap that
  `@memcpy` for `innigkeit.memory.safe.memcpy` (which already exists) the
  next time `elf_loader.zig` is touched. Not scheduled as its own stage.
- **`bd48de3a` "reduce the size of the interrupt handlers" — read in full,
  genuinely applicable, ready to implement.** `src/architecture/x64/asm/
  interruptHandlers.S` is near-byte-identical to CascadeOS's pre-fix file:
  each of the 256 `INTERRUPT_HANDLER` macro invocations fully duplicates the
  entire common body (userspace `swapgs` check, 15 register pushes, call
  into the dispatcher, 15 pops, `swapgs` check, `iretq`) instead of pushing
  the vector number and jumping to one shared body. CascadeOS's fix: extract
  the shared body into one `commonInterruptHandler`, leave each per-vector
  stub as a 2-3 instruction trampoline (`push $0` if needed, `push $vector`,
  `jmp commonInterruptHandler`) — reported ~74 KiB smaller. Purely mechanical,
  no behavior change, same technique directly transplantable. Not done in
  this pass (only found near the end); a good small standalone follow-up.
- **`8e3c85c3` "prepare for unloading of init only code/data"**: adds a
  `.init_text` linker section (x64/arm/riscv linker scripts + a
  `cascade.config.init.code_section` constant) and starts tagging boot-only
  entry points with it — pure scaffolding, does not yet actually reclaim the
  memory. This is the well-known `__init`/`.init.text`-style technique
  (Linux and others free init-only code after boot). Innigkeit has no
  equivalent today. Legitimate future memory-efficiency idea, but low
  urgency for a research/hobby kernel where init code size is small relative
  to everything else — noted, not scheduled.

Both of the above are now read in full; every one of the 49 commits in the
range has real content behind its disposition in this document, not
subject-line inference.

---

## hiillos: additional ideas beyond fault isolation

- **`Sender` capability "stamp"** (`caps/ipc.zig`): a `u32` badge on a
  shared/cloned endpoint's `Sender` so a receiver can cheaply tell which
  client sent a message — functionally seL4's badge concept. Could be added
  to Innigkeit's `Endpoint` for cheap sender identification without
  per-client endpoints. No rights-attenuation-on-transfer was visible in
  hiillos's own capability-transfer code, i.e. Innigkeit's monotonically-
  decreasing-rights model is already more rigorous there — not something to
  copy, a useful contrast confirming Innigkeit is ahead. **Lower priority
  than fault isolation; worth a future IPC-focused pass, not now.**
- **IPI-based SMP preemption trigger**: a reasonable pattern regardless of
  scheduler algorithm; Innigkeit's own reschedule-IPI (x86-64 vector 253,
  per `.claude/rules/scheduler.md`) already does the equivalent. No action.
- **RedoxOS-style URI service addressing** (`fs://`, `tcp://`, `initfs://`):
  a userspace-namespace idea, independent of the kernel's capability
  mechanism. Interesting for a future userspace-service-discovery design
  conversation, not a kernel change. Not scoped further here.
- **Canned `.gdbinit`/`.lldbinit`**: a trivial, free convenience if
  Innigkeit doesn't already have matching debug-ergonomics files checked
  in — worth a two-minute check, not worth its own stage.

## imaginarium: one footnote, no action

Small NT-style hobby kernel (object-manager namespace with typed path
prefixes, IRQL-as-unified-priority concept), not capability-based, no
counterpart to Innigkeit's IPC/codesigning/scheduler design. The named-
object-namespace idea is philosophically in tension with pure capability
security and should not be adopted on the security-critical path; at most a
passing design-review footnote if Innigkeit ever wants a human-addressable
debug/introspection namespace layered *on top of* (never replacing) the
capability table. No action.

## Style pass, part 1: architecture-layer naming & module organization

Scoped per explicit direction: no further external OS references beyond
CascadeOS/hiillos/imaginarium (already sufficient), all four style axes
matter long-term but **naming and module organization first**. This is
the first installment, not the whole pass — documentation rigor, error-
handling idiom consistency, and code-size opportunities (the interrupt-
handler dedup above is one) are follow-on installments, not covered here.

- **`architecture/io.zig` uses two different styles for structurally
  identical operations, in the same file.** `readPci`/`writePci` (top of the
  file) are flat, verb-prefixed free functions taking a raw address. `Port`
  (further down, same file) is a wrapper struct — `Port.from(value)` /
  `.read(T)` / `.write(T, value)` — for what is mechanically the same shape
  of operation (read/write a sized value at an addressable location). One
  reads as "object with methods," the other as "verb baked into the
  function name." Not a bug, but a real, fixable inconsistency: bringing
  `readPci`/`writePci` into a `Pci` namespace (`Pci.read(T, address)`/
  `Pci.write(T, address, value)`, no instance data needed since PCI config
  space is addressed directly rather than through a handle) would match
  `Port`'s existing shape with a small, mechanical, low-risk rename.
- **`architecture/user.zig` has the same split.** `createThread`/
  `destroyThread`/`initializeThread` are flat free functions; `SyscallFrame`
  a few lines below, in the same file, is the wrapper-struct-with-methods
  style (`.syscall()`, `.arg()`, `.setReturnValue()`). Same fix shape:
  `Thread.create`/`.destroy`/`.initialize` would match `SyscallFrame` and
  `paging.zig`'s `PageTable`/`interrupts.zig`'s `InterruptFrame` (both
  already object-style).
- **Three genuinely orphan free functions at `architecture`'s top level**:
  `spinLoopHint`, `halt`, `earlyDebugWrite` (`architecture/root.zig`) don't
  have an object to belong to under the current file-per-subsystem scheme,
  because they're fundamentally "current executor" operations and Innigkeit
  has no `Executor.current` namespace the way CascadeOS's post-restructure
  `arch.zig` does. Not urgent — root.zig is a small, reasonable landing spot
  — but worth deciding deliberately (either introduce a minimal
  `Executor.current` namespace for these three, matching CascadeOS's shape,
  or explicitly decide root.zig-level free functions are the intended
  pattern for anything that doesn't cleanly belong to one subsystem file)
  rather than leaving it as an artifact of how the code grew.
- **`scheduling.zig`'s flat style** (`getCurrentTask`/`setCurrentTask`/
  `initializeTaskArchSpecific`) is *not* flagged as inconsistent —  these
  are low-level arch primitives that `innigkeit.Task.Current` (the real,
  richer kernel-side object) is built on top of, so a flatter, more
  primitive naming register arguably makes the layering clearer rather than
  muddier. Recorded so it isn't mistaken for the same issue as the two
  above on a future pass.
- **"paging" vs "mem" naming precision** (CascadeOS itself renamed
  `arch.paging` → `arch.mem` in `9bbb95e6`, since the module also houses
  general memory-access operations like `safeMemcpy` that aren't really
  "paging"): a legitimate naming-precision question, but a much wider-
  blast-radius rename (every call site across the kernel) for a real but
  modest clarity gain. Worth considering, not recommending outright —
  flagged here so it's a deliberate choice later, not forgotten.

Not implemented in this pass — these are naming/organization proposals
for sign-off, not yet applied to any file.

## disk-image-step / "Dimmer": decision already reached — defer

Compared in full against `build/ImageStep.zig` +
`tools/image_builder/{gpt,fat}`. Dimmer (renamed from disk-image-step) is a
broader, general-purpose disk-image DSL/compiler (MBR+GPT, FAT12/16/32 via
the external `zfat`/FatFs binding). Innigkeit's own pipeline is narrower but
**shares its GPT/FAT struct definitions directly with the kernel's own
runtime filesystem parser** — a real architectural advantage Dimmer cannot
offer, since adopting it would mean maintaining two independent GPT/FAT
implementations (Dimmer's `zfat`-based one for build-time image assembly,
Innigkeit's own for runtime parsing) instead of one shared one. **Decision:
do not adopt Dimmer, wholesale or partial-merge. Keep the in-house
`image_builder`/`ImageStep` pipeline.** No further action; this line item is
closed.

---

## Next steps — status

0. **DONE** — `user_memory_range`/`kernel_memory_range` top-boundary-page
   exclusion (the CRITICAL SYSRET-class fix), x64/arm/riscv, plus the
   invariant documented in the shared `Decls.zig` contract. Verified on x64
   (137/137) and arm (97/12-skipped).
1. **DONE** — `FlushRequest` ordering fix (`.monotonic` → `.acquire`/
   `.release`). Verified on x64 and arm, same baseline.
2. **DONE** — `sync/` cache-line-marker consistency (`Parker.zig`/
   `RwLock.zig`). Verified on x64 and arm, same baseline.
3. **DONE** — per-process fault isolation. `memory/root.zig::onPageFault`'s
   `.user` branch now kills only the faulting process (sets
   `exit_status = 139`, calls the same `Scheduler.Handle.terminate()` path
   `exit_process` already uses) instead of panicking the kernel. No new
   machinery — entirely reused `Process.exit_status` and `ProcessCleanup`'s
   existing signal-on-zero-refcount logic. `onKernelPageFault` (supervised
   kernel access to user memory) is untouched and still panics on a genuine
   kernel bug, matching hiillos's own scoping. Same single-thread-only
   limitation `exit_process` itself already has (no multi-thread
   force-termination on SMP — a pre-existing, documented gap, not a new
   one). x64 only in practice today (arm's data-abort routing to
   `onPageFault` doesn't exist yet), but the fix is architecture-generic.
   Directly unblocks a TH-3-equivalent test per `docs/test-harness-plan.md`
   once Stage 3's fixture-app infrastructure lands. Verified on x64
   (137/137) and arm (97/12-skipped, same baseline).
4. **DONE** — `.?` unwrap audit: all 98 sites across 36 files converted to
   `orelse unreachable`, each individually verified. See the dedicated
   section above for details, including the two site categories that
   needed more than a mechanical rename (`FaultInfo.zig`'s
   implementation-dependent invariant, the virtio drivers' `orelse return`
   idiom fix).
5. **DONE** — `resource_arena` sizing comparison: Innigkeit's own
   `memory/arena/Arena.zig` already has the fixed shape (confirmed non-issue
   above).

Also done in this pass but sourced from the style-pass section, not this
numbered list: the `io.zig`/`user.zig` `Pci`/`thread` namespace grouping,
and the x64 interrupt-handler stub deduplication (from CascadeOS's
`bd48de3a`). Everything in "Confirmed non-issues" and "Lower priority /
comparison-only" above remains recorded, not scheduled.

**All items in this document's original scope are now done.** Everything
recorded under "Confirmed non-issues" and "Lower priority / comparison-only"
remains just that — recorded so it isn't re-researched, not queued.

Items filed as "confirmed non-issue" (scheduler `Handle.block`, user-memory-
access count-vs-bool) or "lower priority/comparison only" (arch restructuring,
syscall-dispatch parallels, safe.memcpy parallels, address/range ergonomics,
build tooling, hiillos's Sender badge/URI addressing, imaginarium's object
namespace) are not scheduled — they're recorded so they aren't re-researched
from scratch later, not because they're queued.
