---
paths:
  - "src/innigkeit/user/**"
  - "src/innigkeit/memory/safe*"
  - "docs/security-audit.md"
---

# User→kernel boundary rules

All kernel/user memory transfers go through `user/validate.zig`. Never dereference a user pointer outside `copyFromUser`/`copyToUser`/`readUser`/`writeUser`/`userSlice`+`UserAccess`.

**F1 is closed on x64.** Every user-pointer access on the boundary is now fault-safe: streaming sites use bounce buffers, the futex atomic load uses `memory.safe.atomicLoadU32` with `immediate` fixup mode. Do not introduce new direct user-memory accesses outside these helpers.

**Bounce buffer pattern for streaming sites:**
- writes (user → device): copy chunk into kernel buffer with `copyFromUser`, hand kernel buffer to driver
- reads (device → user): fill kernel buffer, copy out with `copyToUser`
- never hold a `UserAccess` window across a blocking call
- never touch user memory while holding a spinlock (interrupts disabled)

**Entitlement enforcement:** the dispatch table in `syscalls.zig` checks the declared gate before any handler runs. Two gates are conditional and enforced inside the handler: `open` needs `storage` only with the write flag (bit 0); `cap_create` needs `secure_vault`/`gpu` only for those object types. Do not add blanket table gates for conditional cases.

**Adding a syscall:** see `.claude/skills/new-syscall/SKILL.md` or `docs/syscall-abi.md`. Selector numbers are append-only — never renumber.

**Security audit findings (docs/security-audit.md):**
- F1 HIGH: streaming user access — CLOSED on x64, pending arm data-abort routing
- F2 LOW: ELF u16 program-header multiply — FIXED (widened to u32)
- `net_tcp_close` is intentionally ungated (legacy behavior; known gap)

**`Process.ExitStatus`: single source of truth for kernel-initiated kill exit codes.** `128 + POSIX signal number`, matching the shell/`wait(2)` "killed by signal" convention. Every kernel-initiated kill path uses it: `process_kill` (`sigint`), the page-fault handler (`sigsegv`, `memory/root.zig`), and per-architecture unhandled-exception isolation (`sigill`/`sigfpe`/`sigbus`/`sigtrap`/`sigsegv` depending on vector, see `.claude/rules/x64.md`). Add a new kernel-initiated kill path by adding/reusing a constant here, not a fresh magic number at the call site.

**Fault isolation, generalized (Phase 3 Stage 6a/6c).** `Process.terminateCallingThread(status)` is the shared mechanism: kills only the calling thread (a sibling from `spawn_thread` is unaffected), never the whole kernel, for anything the offending process's own execution triggered — not just page faults. Per-architecture unhandled-exception handlers (x64: `interrupts/handlers.zig`'s `unhandledException`) must route every user-mode exception through this, with the single exception of vectors that indicate the CPU itself can no longer reliably run any code (double fault / machine check equivalents), which still panic. When porting this pattern to a new architecture, default new/uncertain vectors to isolate, never to panic — see `.claude/rules/x64.md`'s `exceptionDisposition` writeup for the reasoning.
