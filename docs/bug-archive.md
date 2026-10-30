# Bug archive

Verbatim write-ups of bugs and investigations moved out of `.claude/rules/` so the rule files hold only current invariants (rules load into context; history does not need to). Nothing here is an instruction. Entries keep their original wording, including stale counts and phase names. The invariant each one produced lives in the rule file named in its heading.

---

## From `.claude/rules/sdk.md` (was line 58)

## `sdk/example/`'s `innigkeit_hello` app's build failure — FIXED (2026-07-13), was misdiagnosed as a Zig backend limitation

Building `sdk/example/`'s own worked example used to fail with
`error: failed to select fpext f128 f64` inside `ubsan_rt.zig`/
`std.Io.Writer.print`, under the freestanding soft-float x86_64 target,
and this file previously called it "a Zig compiler backend limitation,
not a bug in `sdk/`'s own code." That framing was wrong. The real cause,
found while root-causing the *identical* symptom in the monorepo's own
`build/App.zig` this session: `sdk/build.zig`'s `createApp()` never set
`sanitize_c` on `app_mod`/`prelude_mod`, so both silently took Zig's
implicit Debug-mode default (`.full`) instead of `.off` — pulling in
`ubsan_rt.zig`'s f128 float-reporting path, which the freestanding
soft-float backend genuinely can't codegen (that specific limitation is
real; the bug was in never avoiding the code path that hits it). Fixed
by setting `sanitize_c = .off` on both modules (`createApp` has no
C-linking capability at all, unlike `build/App.zig`'s `app_module`, so
this is unconditional rather than derived from C-source presence).
Verified: `cd sdk/example && zig build` now compiles `innigkeit_hello`
cleanly, failing only at the codesign step for the expected, unrelated
reason (no local `keys/codesign_private.key` present in this sandbox).

---

## From `.claude/rules/pci.md` (was line 12)

## `getFunction()`'s bus-range check was comparison-inverted for the entire lifetime of this file — fixed in Stage 14, verify any future edit against both endpoints

The bug (now fixed): `if (ecam.start_bus < address.bus or address.bus >=
ecam.end_bus) continue;` instead of the correct `if (address.bus <
ecam.start_bus or address.bus >= ecam.end_bus) continue;`. Since every
ECAM segment's `start_bus` is `0` in every topology this codebase
currently boots, the inverted comparison's actual match condition
(`address.bus <= start_bus`) degenerated to "only bus 0 matches" — which
happens to be exactly the one case that's still correct by accident, so
every device this codebase's test suite exercises (all on bus 0 in the
default QEMU topology) kept working throughout. **A green test suite does
not mean bus enumeration works** for this file specifically — the
regression test added in Stage 14 (`pci: getFunction matches any bus
inside [start_bus, end_bus), not just start_bus`) exists precisely because
the normal test suite's device placement can't detect this class of bug.
Any future change to this comparison must be checked against a bus
*strictly between* `start_bus` and `end_bus - 1`, not just the endpoints,
or a reintroduced inversion will pass the existing suite silently again.

A second, independent consequence of the same inversion: when
`start_bus > 0` (a second/later MCFG segment), the bug's match condition
also admitted addresses *below* `start_bus`, and `bus_offset = address.bus
- ecam.start_bus` (the very next line) would underflow-panic for those.
Fixing the comparison closes both the silent-misbehavior and the
crash-on-nonzero-start_bus paths at once, since they share the same root
cause.

## MCFG `BaseAllocation` entries need `end_pci_bus >= start_pci_bus` validated before subtracting — fixed in Stage 14

`pci/init.zig`'s `initializeECAM()` computes `number_of_buses =
base_allocation.end_pci_bus - base_allocation.start_pci_bus` directly from
firmware-supplied `u8` fields with no validation. A malformed MCFG entry
with `end < start` underflows this subtraction and panics during PCI ECAM
setup — very early boot, before most error-recovery infrastructure
exists. This is the same "firmware-controlled field used in unchecked
arithmetic" pattern `.claude/rules/acpi.md` documents for
`MCFG.baseAllocations()`'s array-length computation (Stage 10a) — that fix
covers the *overall entry-array length*; this one covers each individual
entry's own `start`/`end` self-consistency, a distinct field pair the
earlier fix didn't touch. Fixed by rejecting (skipping with a warning
log) any entry where `end_pci_bus < start_pci_bus`, matching this
codebase's established graceful-degradation style for malformed
ACPI-derived structures.

---

## From `.claude/rules/filesystem.md` (was line 52)

## `simple_fs`'s per-process `open_files` table leaked across process slab reuse — FOUND AND FIXED

`user/handlers/filesystem.zig`'s `fs_read`/`fs_write`/`fs_close` trust any
non-null `Process.open_files[idx]` entry unconditionally — no check that
the calling process is the one that actually opened it, only that the
slot isn't empty. `Process.create()` never reset this array on slab reuse
(it resets `entitlements`/`fd_table` but had no equivalent line for
`open_files`), so a process spawned into a reused `Process` slab slot
inherited whatever `OpenFile`s (`start_sector`/`size`/`pos`/`writable`)
the previous, unrelated, already-exited occupant had open — accessible
under FD numbers 3..14 the new process never called `fs_open` on itself.
A real cross-process file-handle leak (not just a resource leak; `OpenFile`
is a plain value with nothing to free), reachable by any process since
`fs_open`/`fs_read`/`fs_write`/`fs_close` are all entitlement-gated `.none`.
Fixed: `Process.create()` now resets `open_files` to all-null, and
`Process.cleanupProcess` now closes (via `simple_fs.close()`, flushing any
pending writable-file size update) every still-open entry before the
process returns to the cache — see `.claude/rules/capabilities.md` for the
sibling `cap_table` bug found in the same audit, same root cause.

---

## From `.claude/rules/memory.md` (was line 53)

## Page-table lock gap — FIXED

Originally found (Stage 4a) as a documented-not-fixed gap; fixed in a
follow-up pass once the project owner asked for it.

The page table used to be mutated by two disjoint code paths sharing no
common lock:

- **`AddressSpace.unmap()`** and **`AddressSpace.changeProtection()`**
  mutate the page table directly (`innigkeit.memory.unmap()` /
  `innigkeit.memory.changeProtection()` in `memory/root.zig`, neither of
  which takes any lock itself) while holding only `entries_lock.writeLock()`.
  `page_table_lock` is asserted **unlocked** during these calls.
- **`vmem_map`/`framebuffer_map`** (`user/handlers/{vmem,framebuffer}.zig`)
  populated the page table via `mapSinglePage()` while holding only
  `page_table_lock`, taken *after* `AddressSpace.map()` had already released
  `entries_lock`.

Since a process can have multiple threads (`spawn_thread`) scheduled
concurrently on different executors (SMP), this was reachable: thread A
calls `vmem_map`, which inserts a new `Entry` under `entries_lock` and then
released it; before or while A subsequently took `page_table_lock` to run
`mapSinglePage` on that range, thread B (a sibling thread in the same
process) could call `unmap`/`changeProtection` targeting an overlapping
range, take `entries_lock.writeLock()` (now free), see the entry A just
inserted, and mutate the same page-table structure via
`innigkeit.memory.unmap()`/`changeProtection()` — with no lock serializing A
and B against each other.

**The fix**: `MapOptions` gained a `keep_entries_locked: bool` field. When
`true`, `map()` returns with `entries_lock` still held (write) instead of
releasing it, paired with a new `unlockEntriesAfterMap()` the caller must
call exactly once when done. `vmem_map`, `framebufferMap`, and
`framebufferMapGpu` now pass `keep_entries_locked = true` and hold
`entries_lock` across their `page_table_lock`-guarded `mapSinglePage()`
loop, releasing `page_table_lock` then `entries_lock` (in that order —
inner lock first) before returning or falling through to `unmap()`'s own
cleanup on a population failure (calling `unmap()` while still holding
`entries_lock` would self-deadlock, since `unmap()` takes it itself).

This closes the gap by extending the *already-established*
`entries_lock` (outer) → `page_table_lock` (inner) nesting that
`FaultInfo`'s demand-paging fault path already used (`FaultInfo.zig` lines
~301, ~426 take `page_table_lock` while `entries_lock` is held) to these
two handler call sites, rather than inventing a new lock order — so no
new deadlock ordering was introduced. Verified: `zig build verify
-Darm=true`, x64 139/139 and arm 99/99 (unchanged pass count from before
this fix; no dedicated concurrency stress test was added since exercising
the specific race deterministically would need a new multi-threaded
harness in the spirit of `testing/smp.test.zig` — flagged as a
recommended follow-up, not done here).

---

## From `.claude/rules/x64.md` (was line 164)

## `spawn_thread`'s "second thread never dies" bug — root-caused and FIXED (was misdiagnosed first as an `enterUserspace` hang)

Found while adding a real integration test for sibling-thread force-termination
(see `docs/roadmap.md`'s "Carried-over tracked items"). First appearance
looked exactly like a hard kernel hang: after `Thread.start` (`spawn_thread`'s
path) entered userspace for a second thread, the whole run just sat there —
no exception, no panic, no further log output — until a watchdog eventually
tripped. **That first read was wrong**, corrected by re-running with a short
watchdog and `-Dinterrupts=true`: the watchdog fired cleanly and the suite
finished normally reporting one FAILED test, proving the kernel was never
actually stuck — `architecture.user.enterUserspace` and the whole
`spawn_thread`/second-thread-entry path work fine, on both x64 and arm. The
`-d int` trace's "repeating vector" that looked like a fault loop was
resolved (via `addr2line` against the deterministic, non-KASLR kernel ELF)
to `task.Handle.idle`/`root.halt` plus the periodic-tick return path — i.e.
the CPU legitimately idling because nothing was runnable, not faulting.

**The real bug, found with `sysYield`/`exitProcess` tracing**: the sibling
thread reached userspace fine and called `yield()` in a loop exactly as
written — forever, because it was never told to stop. The main thread *did*
reach `exit_process` and call `Process.terminateCallingThread`, but
`forceTerminateSiblings` (the sibling-kill cascade added alongside this
test) never ran: `Process.terminating`'s compare-exchange was losing
immediately because the field was already `true`. Root cause: `Process`
objects come from a slab cache reused across processes (see
`.claude/rules/capabilities.md`'s "slab reuse" invariant, which this repo
already documents prominently for exactly this reason), and
`Process.create()` explicitly resets `entitlements`/`fd_table` for reuse but
was never updated to also reset the newly-added `terminating` field —
so a process whose slab slot previously held an already-exited process
inherited `terminating = true` from the start, and its own first call to
`terminateCallingThread` silently skipped both `exit_status` and the
sibling-kill cascade. **Fixed**: `Process.create()` now also resets
`process.terminating.store(false, .monotonic)`, mirroring the existing
entitlements/fd_table reset pattern exactly.

**Also found via the same investigation, unrelated to the above**:
`CapabilityTable.deinitAll()`'s own doc comment says "called when a process
exits," but its only real call site was the slab cache's *destructor*,
which fires only when a whole slab is reclaimed (rare), not on ordinary
process exit (`Process.cleanupProcess`). Every process leaked its entire
capability table on exit, and a reused Process slab slot handed the next
process a capability table still populated with the previous process's
live entries — a cross-process capability leak, not just a resource leak.
Fixed by calling `process.cap_table.deinitAll()` from `cleanupProcess`,
matching the doc comment's stated (but previously unfulfilled) contract.

Verified end-to-end, not just compiled: `testing/fixtures/itest_sibling_kill`
+ `testing.integration.test.zig`'s "a busy-looping sibling thread is
force-terminated when its process exits" now passes for real on both x64
(160/160) and arm (158/158, 11 skipped), confirmed via `zig build
verify -Darm=true [-Dtpm=true]` with no regressions elsewhere.
`hello_world`'s `Thread.spawn`-based tests (`testTryLock`/`testDetach`)
still only run interactively via `zig build run_x64`, never through
`test_x64`/`verify` — a real, still-open automated-coverage gap for that
higher-level wrapper specifically, separate from the two bugs above (which
this pass's own new integration test now covers).

## Stage 6 (`architecture/x64/`, 11,885 lines) — DONE across 6a/6b/6c

One severe design-level gap (unhandled user-mode exception isolation,
fixed — see above) and eight mechanical bugs across the three sub-stages: 2
misspelled/wrong-type identifiers invisible to the build, 4 debug-print
copy-paste bugs, 2 doc-comment copy-paste bugs. See
`docs/phase3-review-plan.md` for the per-substage summary.

---

## From `.claude/rules/x64.md` (was line 39)

## Per-process fault isolation now covers every exception vector — FIXED

Originally found (Stage 6a) as a severe documented-not-fixed gap:
`interrupts/handlers.zig`'s `unhandledException()`'s `.user` branch
`std.debug.panic`d the entire kernel for any exception other than a page
fault.

**The design**: `Interrupt.exceptionDisposition()` (in `interrupts/
Interrupt.zig`) maps every named exception vector to one of two
dispositions:
- **`.isolate: u8`** — terminate only the calling thread with the given
  exit status (`user.Process.ExitStatus`'s `128 + POSIX signal`
  convention, shared with `process_kill` and the page-fault handler — see
  `.claude/rules/user-boundary.md`). The default and safe choice for
  *any* exception raised from user mode: whatever caused it is confined
  to that one process.
- **`.always_fatal`** — reserved for exactly two vectors, `double_fault`
  and `machine_check`: the CPU detected a failure severe enough that it
  couldn't reliably keep running *any* code, including this kernel's own
  isolation machinery. Panics regardless of privilege level.

Every named vector is listed explicitly (not inferred from a numeric
range) so the choice is visible per-vector. Because `Interrupt` is a
non-exhaustive enum (must represent arbitrary raw vector numbers via
`@enumFromInt`), Zig can't make this switch a compile error for a future
named vector the way an exhaustive enum would — so the `else` fallback
itself has to be the safe choice (`.isolate` with `sigsegv`), never
`.always_fatal` and never `unreachable`. This is the actual "future-proof"
property: a vector nobody thought to add to the table explicitly still
gets contained to one process, not a kernel panic.

**Verified end-to-end, not just compiled**: `apps/
itest_illegal_instruction` (test-only fixture) deliberately executes an
architecture-specific illegal-instruction encoding
(`ud2`/`udf #0`/`unimp`); `testing/integration.test.zig`'s new test spawns
it and asserts the exit status is `sigill` (132). Before this fix, this
exact test would have panicked the entire kernel rather than reaching the
assertion — the log line confirming this actually happened in QEMU:
`unhandled user-mode exception invalid_opcode, killing process (exit
status 132)`, followed by the suite completing normally.

**For Stage 9 (`architecture/arm/`)**: replicate this same philosophy
(isolate-by-default, `always_fatal` reserved for CPU-detected
catastrophic failure equivalents only) for arm's own exception vectors —
don't assume arm's fault handling already has equivalent isolation until
checked.

---

## From `.claude/rules/capabilities.md` (was line 16)

- **`cap_table` was never deinitialized on ordinary process exit — FOUND AND FIXED.** `CapabilityTable.deinitAll()`'s own doc comment says "called when a process exits," but its only real call site was the slab cache's *destructor* (fires only when a whole slab is reclaimed, an event distinct from and much rarer than a process exiting). Every process leaked its entire capability table on exit (every referenced object staying refcounted forever), and — the actual security-relevant half of this — a reused `Process` slab slot handed the *next* process a capability table still populated with the previous process's live entries, a cross-process capability leak rather than a mere resource leak. Fixed by calling `process.cap_table.deinitAll()` from `Process.cleanupProcess` (`user/Process.zig`), before the process returns to the slab cache. Found alongside the `Process.terminating` slab-reuse bug documented in `.claude/rules/x64.md` — same root class (slab-reuse invariant not fully honored), different field.
- **`Process.open_files` (the older flat filesystem-handle table) had the identical gap, also FOUND AND FIXED in the same audit.** `fs_read`/`fs_write`/`fs_close` (`user/handlers/filesystem.zig`) trust any non-null `open_files[idx]` entry unconditionally — no ownership check beyond null-ness. `Process.create()` reset `entitlements`/`fd_table` but never `open_files`, so a reused slab slot handed the next process a live, previously-opened file handle (whatever `start_sector`/`size`/`pos`/`writable` state the old process left it in) under an FD number (3..14) it never called `fs_open` on — a real cross-process file-handle leak, exploitable by any process (the `fs_*` syscalls are entitlement-gated `.none`). Fixed by explicitly resetting `open_files` to all-null in `create()`, and by closing (flushing any pending writable-file size update via `simple_fs.close()`) every still-open entry in `cleanupProcess`, mirroring `fd_table.closeAll()`'s existing adjacent pattern. `Process.next_thread_id` had the same class of gap too, but cosmetic-only (default thread naming only) — fixed for consistency while already touching this exact invariant in the same function.
- **`.grant` ("can transfer a copy of this capability to another process") was checked at exactly one call site — `frame.clone` — and unenforced at all three real cross-process derivation paths: FOUND AND FIXED in the same audit.** `CapabilityTable.transferCaps` (IPC delegation, `Endpoint.send`/`recv`), `handlers/spawn.zig`'s cap-grant resolution loop (a parent handing capabilities to a spawned child), and `cap_copy`'s `copyLocked` were all confirmed by direct code reading (grepping every `.grant`/`insertLocked` site) to hand off a capability regardless of whether its slot's `.grant` bit was set. Audited every real grant/copy call site in the tree first (no app or test fixture called `cap_copy` at all yet; the only real exerciser of `transferCaps` was the TH-2 integration test, which granted its transferred `Notify` without `.grant` and was updated to grant it explicitly — the correct fix, since that test's whole point is delegating a capability onward). Fixed by adding an `info.rights.grant` check to `transferCaps` (drops the handle, same as an already-invalid one) and to `handlers/spawn.zig`'s grant loop (same rejection style as its existing rights-escalation check) — **deliberately not** added to `copyLocked`: that operation never leaves the calling process's own table, so there is no "to another process" for `.grant` to gate there, and adding it would have broken the existing "equal rights" `copyLocked` test for no security reason. A negative-path integration test was written (sender granted the notify *without* `.grant`, asserting the receiver sees a dropped handle) but is skipped unconditionally, not committed as a running test: it deterministically hit the pre-existing, already-documented concurrent-spawn race (`.claude/rules/arm.md`) as the *second* concurrent-spawn-pair in the same boot, confirmed via temporary diagnostic logging to never even reach `transferCaps` — not a bug in the fix itself, which the passing positive-path (`.grant = true`) sibling test already exercises correctly. Revisit once that race is fixed. Verified: `zig build verify -Darm=true` clean on both arches (x64 181/181 passed, 2 skipped; arm 181/181 passed, 13 skipped), `zig build check` clean.
- **`copyLocked` could revive a capability its own holder had just revoked — FOUND AND FIXED while building the formal capability-revocation model (`docs/test-system-plan.md` §3).** `copyLocked` looked up its source slot via `getLocked`, which only checks `type != .null` — unlike `getAndRefLocked`, it never compares the slot's stored generation against the object's current one. `revokeLocked`'s own doc comment promises "every slot in every table that points to the same object... will fail `getAndRefLocked`", but that promise didn't extend to `copyLocked`: a process holding a slot with `.revoke` rights could revoke the object (bumping its generation, correctly invalidating every existing slot including its own) and then immediately `copyLocked` that same now-stale slot into a brand-new slot — which picks up the *current* (post-revocation) generation at insert time and is therefore fully live again, with whatever rights the stale slot recorded. Confirmed empirically (not just by inspection) with a temporary diagnostic test under `zig build test_x64` before fixing. Net effect: generation-based revocation was not the hard, one-way cutoff its own documentation claimed — the original holder could silently un-revoke for itself (and then re-`transferCaps` the fresh copy to anyone), as long as it never called `removeLocked` on the stale slot. Fixed by routing `copyLocked` through `getAndRefLocked` instead of `getLocked` (which also removes the duplicated ref/rights-snapshot logic `copyLocked` used to hand-roll) — a revoked source slot now fails with `error.NotFound`, same as an empty or out-of-range one, matching `getAndRefLocked`'s own existing "revoked reads as not-found" convention rather than inventing a new error variant. Regression test: `capabilities.CapabilityTable.test."capability: copyLocked rejects a revoked source slot"`. Verified: `zig build test_x64` → 180/180 passed (1 skipped), `zig build check` clean.
- **`CapabilityTable.free_head` was never reset to its canonical order on process-slab reuse — FOUND AND FIXED while building the syscall-dispatch fuzz target (docs/test-system-plan.md §5, staging step 4).** `deinitAll()` (run on every ordinary process exit, before the slab slot returns to the cache) empties every occupied slot correctly, but its free-list reconstruction threads reclaimed slots onto whatever `free_head` already was, in increasing-index visit order — so `free_head` ends up pointing at the *highest*-index slot that process ever occupied, not slot 0. `Process.create()` already had the documented slab-reuse pattern for `entitlements`/`fd_table`/`open_files`/`terminating` (each with its own "same slab-reuse invariant" comment), but `cap_table` was missing from that list — the same class of bug as the `terminating`/`open_files` ones above, just in the free-list structure rather than a plain field. Net effect: `insertLocked`'s very next call after a reused slab slot's prior occupant held more than one capability (or whose *last*-occupied slot wasn't index 0) lands the new grant at whatever stale index `free_head` was left at, not slot 0 — silently breaking any caller (every existing cap-grant fixture and test in this tree, including the new one that found this) that assumes its first, only capability grant lands at handle 0. Confirmed empirically: a fixture spawned late in the suite (after `itest_cap_sender`, a two-capability process, had already cycled through the same process slab slot) got `error.BadHandle` on its very first `endpointRecv`, using a handle that had worked in every earlier, luckier test. Fixed by calling `process.cap_table.init()` in `Process.create()`'s existing slab-reuse reset block — safe and idempotent since every slot is already `.type = .null` after `deinitAll()`; this only restores the free list's canonical 0->1->2->... order. Verified: `zig build test_x64 -Dfuzz_channel=true` (187/187 passed) and both `zig build test_x64`/`test_arm` (184/184 passed each, no regression) after the fix.

---

## From `.claude/rules/user-boundary.md` (was line 26)

- F2 LOW: ELF u16 program-header multiply — FIXED (widened to u32)
- `net_tcp_close` is intentionally ungated (it can only close the caller's own sockets since F4 was fixed)
- **F4 MEDIUM, FOUND BY FUZZING, FIXED (ownership, 2026-10-30): UDP and TCP
  socket ids were one global table with no owner.** `net_udp_close`/`recv`/
  `recv_nb`/`send` and every TCP call took a bare `id & 0xFF` and never checked
  who opened it, so any process with the `network` entitlement could close, read
  from or send on another process's (or the kernel's) sockets by guessing a
  small integer; three of four real fuzz campaigns ended by closing the
  harness's own channel socket this way. Fix, with **no ABI change**: every
  socket records an `network/owner.zig` `Owner` (`.kernel`, or a process by
  address), every `network.socket` function takes the caller's owner, and a
  mismatch behaves exactly like a closed/invalid id (ids reveal nothing).
  Inbound TCP children inherit their listener's owner until `accept` hands
  them to a new `NetSocket` (`tcpReown`).
  **Final design (same day): sockets are capabilities.** `net_udp_open`,
  `net_tcp_listen`/`accept`/`connect` return a `net_socket` handle in the
  process's `CapabilityTable` (`capabilities/types/NetSocket.zig`); the global
  slot id never leaves the kernel. Each `NetSocket`'s `Owner` is its own
  address, so the table checks still apply and a stale handle can never reach a
  reused slot. Handlers resolve handles with `lookup()` in
  `handlers/network.zig` (`getAndRefLocked` + `NetSocket.fromSlot`: type,
  protocol and rights checked; reference held across blocking calls);
  **a new network handler must go through `lookup`/`publish`**. `net_*_close`
  shuts the socket down for all holders when the handle has `write`, else just
  drops the handle. Process exit needs no socket-specific cleanup:
  `cap_table.deinitAll()` unrefs, and the last unref closes the slot and any
  never-accepted connections. The kernel test harness passes `.kernel`, which no
  syscall path can produce. `net_tcp_close` stays ungated and is harmless.
  Tests: `NetSocket.zig`, `network/socket.zig`.
- **F3 HIGH, FOUND BY FUZZING AND FIXED: `open`'s `path_len` argument was used
  as a slice bound before being validated, panicking the whole kernel.**
  `handlers/file.zig`'s `open()` formed `path_buf[0..path_len]` (`path_buf`
  a 63-byte stack array) *before* the `path_len > max_path_len` check that
  existed further down the function — Zig's slice-bounds safety check fires
  on construction, so any `path_len` past 63 panicked the kernel outright
  (`index out of bounds`), not a contained per-process fault. `open` carries
  no entitlement gate for read-only access (`.claude/rules/capabilities.md`'s
  "conditional" gate only applies to the write flag), so this was reachable
  by any process, not just a privileged one. Found by `docs/test-system-
  plan.md` section 5's mutation loop (`tools/kernel_fuzz`) driving a random
  `path_len` through a minimally-entitled fixture — the first real,
  security-relevant bug that harness has found, not just proven the harness
  itself works. Fixed by moving the length check (`path_len == 0 or
  path_len > max_path_len`) before `path_buf` is ever sliced. Audited every
  other handler in `user/handlers/` that slices a fixed buffer by a raw
  syscall argument (`fs_open`'s `name_len`, `initfs_read`'s `name_len`, both
  UDP recv/send paths' `buf_len`, `write`'s chunked copy, `blk_read`'s
  chunked copy) — all of them already clamp or validate before slicing
  (`@min` against the buffer size, or an explicit range check first); `open`
  was the one exception. The bug class is now also caught mechanically:
  `lint/rules/unvalidated_arg_slice.zig` (`zig build lint`) flags, in
  `user/handlers/` only, a `[..]` slice naming a local taken straight from
  `context.arg*()` with no earlier `if` condition or `@min`/`@max` mentioning
  it. Heuristic, not dataflow: it confirmed both slice sites in the pre-fix
  `open()` and reports nothing on the current tree, but it cannot see taint
  carried through a struct field (`spec.name_len`) or a guard that does not
  return. Its in-file unit tests could not be run standalone (zlinter's test
  harness needs the zls module graph); the same cases were checked through a
  throwaway handler file in a real `zig build lint` run.

---

## From `.claude/rules/arm.md` (was line 9)

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
- **Still open: the load failure itself. Deterministically reproduced via
  checkpoints (docs/test-system-plan.md §4 staging step 5); the original
  characterization below (permission fault, B is the victim) is WRONG —
  corrected findings follow.** With the panic mechanism gone, un-gating
  the concurrent-spawn tests on arm shows the original symptom 1 plainly,
  on every attempt (2/2 boots): `spawn: loadAndJump failed: BadAddress`
  for the *second* of two back-to-back spawns (`itest_cap_receiver`). The
  two IPC tests then fail cleanly on their watchdogs, since the receiver
  never runs. In the same polluted boot, the `process_kill` test then hit
  a kernel-mode `current-EL SP_EL1 synchronous` panic that was not
  investigated. On x64 the same un-gated set passed 2/2 (185/185, 0
  skipped), including the 20-cycle loop. So what hit x64 before was most
  likely this same refcount bug, triggered by a rarer x64 load failure.
  **The gates are unchanged**: the first cause is demonstrably live on
  arm, and x64's 2/2 is too little evidence to call it absent there.
  Un-gating x64 is a judgment call left to the project owner
  (docs/test-system-plan.md §4).

  **Corrected findings (checkpoint-driven deterministic repro,
  `checkpoint.test.zig`'s `spawnOverlapping` + two
  `loader_before_protect`/`loader_after_protect` tests, x64-only-gated,
  arm skipped pending a fix).** The original hypothesis above (a
  *permission* fault on B, caused by a stale TLB/page-table root left by
  A's `changeProtection`) does not hold up under a controlled repro:

  - **It is process A — the held, already-loaded process — that crashes
    on resume, not process B.** B always exits 42 (clean) in every run.
    A exits 139 (sigsegv) whenever the race hits. This completely
    overturns the original framing, which blamed the second,
    concurrently-loading process.
  - **The fault is a translation fault (the page isn't mapped at all),
    not a permission fault.** Confirmed with temporary `ESR_EL1`/
    `FAR_EL1` diagnostics in `handleUserFault` (added and reverted): the
    fault address is inside A's own, already-copied text segment.
  - **Holding A before vs. after its own `changeProtection` call produces
    the identical outcome** (A=139, B=42/0 depending on hold point) —
    directly disproving the stale-permission-entry hypothesis, which
    predicts a difference between the two hold points and shows none.
  - **A real, independent AArch64 correctness gap was found and fixed
    along the way, but confirmed NOT to be this bug's cause**: the ELF
    loader was missing instruction-cache-coherency maintenance
    (`DC CVAU`/`IC IVAU`/barriers) after copying executable segment data,
    required on AArch64's non-coherent I/D caches (a no-op on x86-64).
    Fixed via a new `architecture.paging.syncInstructionCache` interface
    slot, real arm implementation reading `CTR_EL0` line sizes, wired
    into `loader.zig` right after the segment-copy loop. Kept regardless
    of this race (it's independently correct), but the deterministic
    repro produces byte-identical A=139/B=42 results before and after
    adding it — ruling it out as this bug's mechanism.

  **Leading hypothesis, not yet confirmed**: a physical-page-table-page
  aliasing or double-allocation bug in concurrent `AddressSpace`
  population across two different processes — e.g. `arm/PageTable.zig`'s
  `ensureNextTable` allocating/zeroing a table page for B's address space
  that is actually still needed by, or aliased with, a page-table-level
  page A's structure already depends on. That would explain a
  *translation* fault appearing later in A's own, previously-working
  mapping, consistent with everything observed above. Untested this pass.
  The checkpoint-driven `spawnOverlapping` harness (`checkpoint.test.zig`)
  is now in place to test it: the natural next step is a checkpoint
  inside `ensureNextTable` itself (or around `AddressSpace.map()`'s
  table-population path) to force the interleaving directly, rather than
  relying on natural SMP timing.
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
