---
paths:
  - "src/innigkeit/user/**"
  - "src/innigkeit/memory/safe*"
  - "docs/security-audit.md"
---

# User→kernel boundary rules

All kernel/user memory transfers go through `user/validate.zig`. Never dereference a user pointer outside `copyFromUser`/`copyToUser`/`readUser`/`writeUser`/`userSlice`+`UserAccess`.

**F1 is closed on both x64 and arm.** Every user-pointer access on the boundary is now fault-safe: streaming sites use bounce buffers, the futex atomic load uses `memory.safe.atomicLoadU32` with `immediate` fixup mode. Do not introduce new direct user-memory accesses outside these helpers.

**Bounce buffer pattern for streaming sites:**
- writes (user → device): copy chunk into kernel buffer with `copyFromUser`, hand kernel buffer to driver
- reads (device → user): fill kernel buffer, copy out with `copyToUser`
- never hold a `UserAccess` window across a blocking call
- never touch user memory while holding a spinlock (interrupts disabled)

**Entitlement enforcement:** the dispatch table in `syscalls.zig` checks the declared gate before any handler runs. Two gates are conditional and enforced inside the handler: `open` needs `storage` only with the write flag (bit 0); `cap_create` needs `secure_vault`/`gpu` only for those object types. Do not add blanket table gates for conditional cases.

**Adding a syscall:** see `.claude/skills/new-syscall/SKILL.md` or `docs/syscall-abi.md`. Selector numbers are append-only — never renumber.

**Security audit findings (docs/security-audit.md):**
- F1 HIGH: streaming user access — CLOSED on both x64 and arm (arm's routing was already implemented; only its tests were stale-gated, see `docs/DESIGN.md` Part 3)
- F2 LOW: ELF u16 program-header multiply — FIXED (widened to u32)
- `net_tcp_close` is intentionally ungated (legacy behavior; known gap)
- **F4 MEDIUM, FOUND BY FUZZING, NOT FIXED: UDP (and TCP) socket ids are one global table with no owner.**
  `net_udp_close`/`recv`/`recv_nb`/`send` take a bare `id & 0xFF`
  (`handlers/network.zig`, `network/socket.zig`) and never check who opened it,
  so any process holding the `network` entitlement can close, read from or send
  on another process's socket, or the kernel's own, by guessing a small
  integer. `net_tcp_close` is additionally ungated. Three of four real fuzz
  campaigns ended by closing the harness's own channel socket this way. A
  Debug kernel does not enforce entitlements (`config.zig`), so fuzz findings
  in gated handlers are reachable only by a process with that entitlement in a
  release build. A real fix is to make sockets capabilities (a typed handle in
  the per-process table) rather than a global index; that is an ABI change, so
  it is flagged for the project owner, not made here.
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
  `build/lints/unvalidated_arg_slice.zig` (`zig build lint`) flags, in
  `user/handlers/` only, a `[..]` slice naming a local taken straight from
  `context.arg*()` with no earlier `if` condition or `@min`/`@max` mentioning
  it. Heuristic, not dataflow: it confirmed both slice sites in the pre-fix
  `open()` and reports nothing on the current tree, but it cannot see taint
  carried through a struct field (`spec.name_len`) or a guard that does not
  return. Its in-file unit tests could not be run standalone (zlinter's test
  harness needs the zls module graph); the same cases were checked through a
  throwaway handler file in a real `zig build lint` run.

**`Process.ExitStatus`: single source of truth for kernel-initiated kill exit codes.** `128 + POSIX signal number`, matching the shell/`wait(2)` "killed by signal" convention. Every kernel-initiated kill path uses it: `process_kill` (`sigint`), the page-fault handler (`sigsegv`, `memory/root.zig`), and per-architecture unhandled-exception isolation (`sigill`/`sigfpe`/`sigbus`/`sigtrap`/`sigsegv` depending on vector, see `.claude/rules/x64.md`). Add a new kernel-initiated kill path by adding/reusing a constant here, not a fresh magic number at the call site.

**Fault isolation, generalized (Phase 3 Stage 6a/6c).** `Process.terminateCallingThread(status)` is the shared mechanism: kills only the calling thread (a sibling from `spawn_thread` is unaffected), never the whole kernel, for anything the offending process's own execution triggered — not just page faults. Per-architecture unhandled-exception handlers (x64: `interrupts/handlers.zig`'s `unhandledException`) must route every user-mode exception through this, with the single exception of vectors that indicate the CPU itself can no longer reliably run any code (double fault / machine check equivalents), which still panic. When porting this pattern to a new architecture, default new/uncertain vectors to isolate, never to panic — see `.claude/rules/x64.md`'s `exceptionDisposition` writeup for the reasoning.
