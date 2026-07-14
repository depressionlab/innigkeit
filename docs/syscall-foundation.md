# Syscall foundation design & migration record

**Status: done** (all 7 steps). All 59 syscalls run through the comptime table; the legacy switch and `errno.zig` are deleted; userspace shares the kernel's error set. `root.zig` is 59 lines (was 1351). Gate: x64 125/125, arm 85 (+9 skipped).

The canonical per-syscall contract is `docs/syscall-abi.md`. This doc is the design record.

---

## What shipped

The error model lives in `library/innigkeit/Error.zig` as one namespace — `Error.Syscall` (the set), `Error.Abi` (wire enum), `Error.code`/`Error.fromCode` — with `OutOfMemory` (idiomatic Zig, not POSIX `NoMemory`).

`user/syscalls.zig` is a declarative table: one row per syscall (selector + `fn(Context) Error.Syscall!usize` + entitlement gate), comptime jump-table dispatch. Per-syscall implementations are in `handlers/*`, individually reviewable. Entitlement is declared in the table, not scattered across handler code.

Known gap: `net_tcp_close` is ungated to match legacy behavior — socket ids are global. Flagged for a future security pass.

---

## Design rationale

### One error vocabulary, end to end

The original design had three stacked layers: kernel handlers returned `errCode(e.EXXX)` (POSIX negated), those integers crossed the wire, and userspace `Syscall.decode` mapped them to a clean error set. The POSIX layer was gratuitous — Innigkeit is not a POSIX kernel.

The fix: one curated `Error.Syscall` set (modeled after Zircon's `zx_status_t`) shared by kernel and userspace from a single file. Handlers return `Error.Syscall!usize`; the dispatcher maps to the wire once. Userspace decodes from the same table. The POSIX `errno.zig` layer is gone.

Wire numbers are POSIX-compatible (EPERM=−1, EBADF=−9, etc.) even though the *set* is not POSIX. This was a deliberate choice: the meaningful win is type safety and a small curated set, not different integers. Reusing POSIX-compatible numbers lets a future libc/POSIX-compat shim map errno for free, and it kept the migration wire-neutral (no flag day required between kernel and userspace batches).

### Declarative table + comptime dispatch

Prior art worth knowing:
- **Zircon**: handle-based, curated `zx_status_t`, syscall surface declaratively defined in `.fidl` + abigen with generated dispatch and vDSO wrappers.
- **seL4**: ~12 syscalls, essentially everything is a cap invocation. Lesson: keep the flat syscall surface small; push new functionality through `cap_invoke` ops on typed objects.
- **Linux**: the anti-pattern — flat POSIX numbers, errno conflated with return values, no type safety, ~130 codes.

The table + comptime dispatch gives us Zircon-style declaration in-language, type-checked. Adding a syscall is one table row + one handler. Entitlement gating is data (auditable) rather than scattered `checkEntitlement` calls that could be forgotten.

### Migration recipe (for reference / the next person)

The migration ran in batches by area, gate-green at every step:
1. error model first (additive — `Error.Syscall` + `Error.Abi` + mapping, host-tested)
2. dispatch infrastructure as a parallel path (`if (syscalls.tryDispatch(...))`)
3. migrate by area — each arm becomes a `fn(Context) Error.Syscall!usize` + table row + legacy arm collapsed to `=> unreachable`
4. entitlements centralized as the batches moved (string check → table enum)
5. delete the giant `switch`, `errno.zig`, per-handler `errCode` once all migrated
6. userspace `Syscall.decode` pointed at the shared table
7. `docs/syscall-abi.md` generated/curated from the table

Delicate batches: cap (security-critical, `handlers/cap.zig`), spawn (security-critical, codesign path), process control (some arms end in `noreturn`), futex (blocking under spinlock), TCP (all `.network`).

### What we don't have yet

- Generated userspace wrappers (deferred — the hand-written wrappers in `library/innigkeit/` earn their place and the table doesn't yet produce them)
- Typed handler arg accessors beyond `ctx.arg(.one..)`/`ctx.arg32(..)` — a `getUserRange(ptr, len)` typed accessor would be nice but is deferred until it pays off in a new handler cluster
