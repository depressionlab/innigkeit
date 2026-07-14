# Innigkeit design goals & decision records

The durable home for long-term pillars, the adversarial-review process that catches design oversights, and honest records for the contested calls. Complements `docs/DESIGN.md` (micro-craft) and `docs/roadmap.md` (sequencing).

---

## Pillars

1. **Security-first, fault-safe kernel.** No user action should panic the kernel or escalate authority. Concretely: capability-first, every user→kernel access fault-tolerant (`safe.memcpy`), W^X + SMEP/SMAP/PAN, KASLR, small TCB. Boot-time integrity (UEFI Secure Boot + TPM 2.0 measured boot) and at-rest confidentiality (disk encryption keyed by TPM/SecureVault) extend this from runtime down to power-on. See `docs/secure-boot.md`.

2. **Zero-copy & async by design.** Bulk data moves through shared frame capabilities, not `(ptr,len)` kernel copies (the seL4 stance — keep the raw-pointer surface tiny). Longer term, an async completion-based syscall/IPC model (io_uring-shaped) is a real differentiator.

3. **Scheduler excellence.** EEVDF + QoS + heterogeneous-core-aware placement; keep investing.

4. **Typed, versioned ABI.** `Size`/`VirtualAddress`/`VirtualRange` and domain newtypes everywhere a unit is meant, fixed-width syscall integers (binary contract must not depend on pointer width), documented versioned userspace ABI.

5. **Multi-arch parity.** x86-64 and AArch64 first-class, RISC-V following. Demand paging + SMP on arm, not just x64.

6. **Deep `std` integration.** Lean on `std` where it earns its place — `std.Io` for streams, `std.ArrayList`/`HashMap` on the process allocator, `std.testing` as the test backbone. The `std.Io` backend (`library/innigkeit/stdio.zig`) still has stubs to fill.

7. **Robust, layered test system.** Host unit tests for every pure core, in-QEMU kernel tests for the integrated system, fault injection as a first-class category, and a user-process integration harness so multi-process IPC paths are exercised end-to-end rather than just compile-checked.

8. **Experience layer.** Clean userspace lib, good virtio drivers, eventually a native WM → Wayland compositor on the cap/zero-copy substrate (stashed; see `docs/wm-wayland-plan.md`).

---

## How we catch design oversights

The `safe.memcpy` gap — validated user pointer, then direct `@memcpy`, so a bad in-range pointer panicked the kernel — wasn't a coding bug; it was a missing adversarial review of a boundary. The fix is process.

### Boundary threat-model checklist

For every syscall / copy / shared-memory path:

- **Bad pointer**: in-range but unmapped? guard page? → must error, never panic.
- **Concurrent mutation (TOCTOU)**: can a sibling thread unmap between validate and use? → fault-fixup or hold the right lock.
- **Integer overflow**: `ptr + len`, `offset + size`, `count * stride` — checked?
- **Alignment / bounds**: does the handler assume alignment the user controls?
- **Resource exhaustion**: can the user force unbounded kernel allocation or work?
- **Capability confusion**: right object type, rights, and generation checked?
- **Blocking discipline**: never block holding a lock or a `UserAccess` window.

Write the answers in the code (doc comment) and turn them into asserts/tests.

### Reference-design diffing

When building or reviewing a subsystem, compare against best prior art (Linux, seL4) and record where we differ and why. This is how the `safe.memcpy` gap was found on a second look.

### Standing practices

- Fault-injection tests are a first-class category; grow the set as boundaries harden.
- Extend `CLAUDE.md` "Key invariants" and assert them in `is_debug` builds.
- Repeat boundary audits after major subsystem work.

---

## Decision records

### DR-1: `safe.memcpy` fault-fixup — **Yes.**
Fault-fixup (exception-table) is the standard technique (`copy_to_user`): race-free, turns any unhandleable fault into a clean error return. Best overall design is fault-fixup for small control-data copies + cap-based zero-copy for bulk. Status: x64 done; arm needs data-abort → `onPageFault` routing.

### DR-2: explicit-width syscall integers — **Partial, by deliberate scoping.**
The selector is `enum(u64)` — fixed-width binary contract, done. Argument/return widths stay `usize`/`isize`: on every supported target `usize == u64`, so widening is a no-op that ripples to every call site for zero benefit until a 32-bit target exists. Revisit then.

### DR-3: typed ELF parser — **Done.**
`Header` uses `VirtualAddress` (entry) + `core.Size` (offsets/sizes) with `TableLocation = {offset, size}`. `ProgramHeader` uses `core.Size` + `VirtualAddress`. Parser is type-safe end to end.

### DR-4: `UserAccess` count vs. bool — **Count, for now.**
A count is forgiving (nesting is safe); a bool would be stricter (catches a class of bug) but is only safe if we prove the ~10 independent `acquire()` sites never overlap. Keep the count until the streaming path folds onto `safe.memcpy` and we can assert non-overlap.

### DR-5: split syscall dispatch into per-handler functions — **Done.**
Declarative table in `user/syscalls.zig`: one row per syscall (selector + handler + `Gate`), comptime jump-table, one `fn(Context) Error.Syscall!usize` handler per syscall in `handlers/*`. See `docs/syscall-abi.md`.

### DR-6: domain newtypes (`Handle`/`Fd`/`Pid`) — **Selective.**
- `Handle` — done; `enum(u32) { _ }`, threaded through `capabilities.zig` + `process.zig`.
- `Fd` — do not force-unify: `io.Fd` is a compile-time stream selector (exhaustive `switch`, `@compileError` for stdin); `filesystem` fds are runtime file handles. Merging them loses the comptime guarantee.
- `Pid` — not a newtype; only `getpid` surfaces it.

General rule: introduce a newtype where an integer crosses an API and could be confused with another integer; skip it where a value is produced and consumed once.

---

## Design-driven workstreams (feeds roadmap)

- **Harden the user→kernel boundary**: security audit + fold streaming path onto `safe.memcpy` + threat-model docs. Pillar 1.
- **Typed/explicit sweep**: `Size`/`VirtualAddress` across drivers/memory. Pillar 4.
- **Boot & at-rest security**: `docs/secure-boot.md`. Pillar 1.
- **Test-system depth**: user-process integration harness + fault injection + `std`/`std.Io`. Pillars 6 and 7.
