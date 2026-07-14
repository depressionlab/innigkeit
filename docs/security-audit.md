# User→kernel boundary security audit (2026-06-18)

A threat-model audit of every user→kernel boundary, run to confirm the
`safe.memcpy` DoS was the *last* instance of its bug class, not just the one we
noticed (see `docs/design-goals.md` Part 2). Findings below are **verified
against the code** — an agent sweep produced the candidates, then each was
checked by hand (several were false positives; noted).

## Posture (bottom line)

The boundary is **solid except for one known systemic gap**: the streaming
`userSlice` + `UserAccess` paths touch user memory **directly** (not through
`memory.safe.memcpy`), so a concurrent unmap or an in-range-but-unmapped page during
the access **panics the kernel** — the same DoS class `safe.memcpy` fixed for the
typed-copy helpers. Everything else is either already mitigated, gated by
codesign, or a false positive. No privilege-escalation or memory-safety hole was
found. Capability checks (type/rights/generation/refcount) are sound.

## VERIFIED real findings

### F1 — Streaming user access is not fault-safe (the priority gap). Severity: HIGH (user-triggerable kernel panic / DoS)
The "streaming" pattern — `validate.userSlice(ptr,len)` + `UserAccess.acquire()`
+ the driver touching the user buffer directly — is **not** routed through
`safe.memcpy`, so a fault during the access is unhandleable → panic. A sibling
thread in the same process can `vmem_unmap` the buffer concurrently to trigger
it; a bad in-range pointer triggers it directly. Sites:
- `user/root.zig` `.write` → `terminal_out` (`output.writer.writeAll(buffer)`)
- `user/root.zig` `.read` → `keyboard_in` (`keyboard_buffer.readLine(buffer)`)
- `user/root.zig` `.cap_invoke` → `secure_vault` seal/unseal
  (`vault.seal/unseal(plaintext,out)` over user slices)
- `user/root.zig` `.net_tcp_send` (`socket.tcpSend(id, buf_send)`) — **worse**:
  `tcp/Socket.zig:sendData` reads the user buffer **while holding a spinlock**
  (interrupts disabled), so a fault there is especially bad.
- `user/root.zig` `.net_tcp_recv` (`socket.tcpRecv(id, buf_recv)`)
- `user/handlers/spawn.zig` argv/envp/path copies use `copyFromUser` (safe) — OK;
  but its `UserAccess`-window region copies (lines ~201, ~443) touch user memory
  directly and should be checked when folding.

**Fix:** the "fold the streaming path onto safe-copy" item. Replace each
streaming site with a **bounded kernel bounce buffer** + fault-safe
`copyFromUser`/`copyToUser`: for writes (user→device) copy a chunk into a kernel
buffer then hand that to the driver; for reads (device→user) fill a kernel
buffer then copy out. This removes the `UserAccess` streaming window entirely
(data crosses only via fault-safe copies) and removes the touch-user-memory-
under-spinlock case.

**Status: all bounce-buffer sites done; one special site (futex) remains.**
- ✅ terminal write — chunked 256-byte bounce + `copyFromUser`.
- ✅ keyboard read — `readLine` into a 256-byte kernel buffer + `copyToUser`.
- ✅ net_tcp_send / net_tcp_recv — one-MSS (1460) kernel bounce.
- ✅ SecureVault seal/unseal — heap bounce (sizes bounded by `MAX_PLAINTEXT
  [+ OVERHEAD]`), crypto on kernel buffers, `copyFromUser`/`copyToUser`.
- ✅ spawn argv/envp — per-string `copyFromUser` (was `userSliceConst` +
  `@memcpy` under a window).
- ➖ spawn ELF segment copy (`handlers/spawn.zig` ~442) — **not** an F1 site:
  the destination is the freshly kernel-mapped child address space and the
  source is the initfs ELF; no user-supplied pointer, so it can't be a
  user-triggerable fault. Left as-is (its `UserAccess` window is to write the
  child's user half, not to read an attacker pointer).
- ✅ **futex word read** (`sync/futex.zig` wait/waitTimeout) — done via a new
  `memory.safe.atomicLoadU32`. It is a special case: the load must be **atomic** (a
  torn read can cause a lost wakeup → hang) **and** runs under the bucket
  spinlock, where the `safe.memcpy` fixup (which re-enables interrupts +
  demand-pages) is unsafe. Solved with an `immediate` fixup mode: `onPageFault`
  redirects at the very top — before `decrementInterruptDisable` or any
  demand-paging — so it is safe under a spinlock (`onInterruptExit` restores the
  saved interrupt-disable count). x64 uses an aligned `mov` (atomic+acquire
  under TSO) with a recovery label; arm uses `ldar` with recovery pending the
  arm data-abort routing. Fault-injection test added (x64).

**F1 is now closed on x64** — every user-pointer access on the boundary
(streaming copies + the futex atomic load) is fault-safe. The arm side gains the
same protection once its data aborts route to `onPageFault` (the one shared
follow-up for both `safeMemcpy` and `safeAtomicLoad32`).

## VERIFIED low-severity / defense-in-depth

### F2 — ELF program-header size computed in u16 arithmetic. Severity: LOW (codesign-gated)
`elf/Header.zig:116,134`: `program_header_entry_count * program_header_entry_size`
(both `u16`) is evaluated in `u16` and overflow-panics in safe builds for a
crafted header — but `spawn` verifies the codesig **before** parsing
(`handlers/spawn.zig`: `codesign.verify` precedes `Header.parse`), so a forged
ELF is rejected first. Defense-in-depth only; **fixed** by widening the multiply
(a robust parser must not panic on bad input regardless). The product fits in
`u32`, so only the intermediate type was wrong.

## FALSE POSITIVES (checked, not bugs)
- "Blocking while holding a `UserAccess` window" in net send/recv — **not a
  violation**: `tcp/Socket.zig` `sendData`/`recvData` are non-blocking by design
  (under a spinlock), precisely so the window can stay open. (They are still
  covered by F1's fault-safety gap.)
- `cap_invoke` "rights/object not re-checked after the table lock drops" —
  `getAndRefLocked` validates generation and takes a ref **before** unlock, and
  the ref is held across the operation, so the object can't be freed and the
  snapshot is correct. Sound.
- `@ptrCast`/`@alignCast` of capability object pointers — those come from the
  slab allocator (kernel-side, correctly aligned), not user data. Safe.
- `readUser`/`writeUser` of typed structs — go through `copyFromUser`/`copyToUser`
  → `safe.memcpy`; fault-safe and copy into aligned kernel storage.

## Integer-overflow / size-math sweep (result)
Spot-checked the `(ptr+len)`, `(offset+size)`, `count*stride` sites on user args:
`validateUserBuffer` already rejects `ptr +% len < ptr` (wrap) and out-of-range;
spawn caps argc/envc and per-arg/total lengths before summing; vmem map/unmap go
through `validateUserBuffer`. The only unguarded width issue was F2. No live
overflow→OOB path found.

## What this means for the roadmap
- The audit **confirms** the design-goals doc: the streaming fold (F1) is the
  real remaining DoS-class gap and should be the next security work — it closes
  the last instance of the `safe.memcpy` bug class.
- It also **validates the boundary is otherwise solid** (caps, copies, overflow
  guards), which is the reassurance the audit was for.
