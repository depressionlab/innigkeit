# Innigkeit coding craft & style

Conventions that make Innigkeit's kernel code what it is: how to think about it and how it should look. Treat this as binding for new code and reviews. Complements `CLAUDE.md` "Key invariants." This is the single reference for style judgment calls throughout Phase 2's style/efficiency/security review (`docs/phase2-review-plan.md`), not just its first stage — extended here rather than forked into a second document.

---

## Part 1: Ideology

### Make illegal states unrepresentable
Prefer a type that carries the proof of a check over one you re-check later.

Not `getType() -> enum{kernel,user,invalid}` followed by `toUser()` (which re-validates), but `tagged() -> union(enum){ kernel: KernelVirtualAddress, user: UserVirtualAddress, invalid }`. The tag carries the typed value — "check the type, then re-project" collapses into one `switch`, and you cannot ask for the wrong projection.

Look for `if (x.kindOf() == .a) ... x.asA()` shapes — those are candidates. See `wm/protocol.zig`'s `Request`/`Event` unions and the `Error.Syscall`/`Error.Abi` split.

### Make misusable APIs impossible to misuse
If correct use depends on the caller remembering something, redesign so they can't forget.

Not `Handle.block(self) Handle` (caller had to swap to the returned handle or silently use a stale one), but `block(*Handle) void` that mutates in place. Any function returning "a new thing you must use instead of the old thing" is suspect — prefer in-place mutation or consuming the input.

### Types carry meaning; don't pass raw integers
Use `core.Size`, `VirtualAddress`, `VirtualRange`, and domain newtypes (`Handle`, `SurfaceId`) at boundaries where the unit matters. An ELF header field is `entry: VirtualAddress`, not bare `u64`. Slice with `range.subslice(offset, size)`, not `slice[base..][0..len]`.

Introduce a newtype where an integer crosses an API and could be confused with another; skip it for values produced and consumed once.

### Assert the post-condition you just established
A one-line `assert` next to code that's supposed to guarantee an invariant turns silent corruption into an immediate, located failure. `assert(caches_created == count)` caught a real under-allocation. Gate hot paths behind `core.is_debug`.

### Explicit control flow beats a clever `defer`
At sharp boundaries (syscall entry/exit, interrupt entry/exit) prefer explicit ordered steps over a `defer` whose timing is non-obvious. Use `errdefer comptime unreachable;` in functions that must not fail — a stray error path becomes a compile error.

### Size/allocate by the real unit
Not `sizeof(RawCache)` but `[QUANTUM_CACHES_PER_PAGE]RawCache` — size by the thing actually stored per unit, then assert the resulting count.

### Keep arch-specific names out of generic code
The generic kernel must never name a physical register or one arch's frame field. Cross the boundary through `architecture.Functions` slots (`setReturnValue` → x86-64 `rax` / AArch64 `x0`, `setInstructionPointer`, etc). Writing `rax` directly in generic code was a latent aarch64 bug.

### Defend hot concurrency state from false sharing — structurally
A leading `_: void align(std.atomic.cache_line) = {}` marker in a struct with hot atomics ensures they never share a cache line with a neighbour. Any struct with a hot atomic that gets embedded in a larger struct should lead with it.

### Fallible access must fail, not panic
Kernel code touching memory that might fault for external reasons (user pointers) must convert an unhandleable fault into an error return. `memory.safe.memcpy` is the canonical implementation. See Part 3.

### Remove language footguns at the source
Prefer bare `.?` for a provably-non-null optional — it's shorter, and `zig build lint`'s `no_orelse_unreachable` rule (`zlinter`) now flags `orelse unreachable` as the thing to avoid (flipped 2026-07-08 to match `zlinter`'s default rather than fight it). Use `orelse @panic("why")` when a message would help a future reader, or an `if (opt) |x|` capture when the value is then used.

---

## Part 2 — Formatting & micro-style

**Comment density is scope-dependent — two tiers, not one rule.**

- **Internal kernel code** (most of `src/innigkeit/`): WHY, not WHAT, and only when non-obvious. Well-named code already shows what it does; a comment earns its place by carrying something the code can't — a hidden constraint, a subtle invariant, a workaround for a specific bug, a reason a reader would otherwise get wrong. If removing a comment wouldn't confuse a future reader, it shouldn't be there.
- **External/developer-facing code** (`library/innigkeit/`, syscall wrappers, anything an app author links against without seeing the kernel-side implementation): lean thorough. Sectioned doc comments on most non-trivial public functions, even ones that read fine standing alone — an outside caller can't check the implementation to resolve an ambiguity the way an in-tree reader can.

**Sectioned doc comments:**
```zig
/// Output a debug message.
///
/// ### Arguments
/// - `arg1`: length of the message
/// - `arg2`: pointer to the message
///
/// ### Errors
/// none
///
/// ### Return
/// undefined
```
Required for a syscall handler, a public API another module depends on, or an FFI boundary, regardless of tier. Apply uniformly when a file is touched (not piecemeal — mixed styles are worse than either).

**`@branchHint` discipline.** Mark cold paths on every error/rare arm (`@branchHint(.cold)`), and `.likely`/`.unlikely` on lazy-init fast paths.

**Lazy-init shape:**
```zig
const cache = if (self.cache) |c| c else blk: {
    @branchHint(.unlikely);
    const c = try build();
    self.cache = c;
    break :blk c;
};
```

**Bare `.?`** for provably non-null (enforced by `zlinter`'s `no_orelse_unreachable`, `zig build lint`). `orelse @panic("why")` when a message helps and the value isn't otherwise used; `if (opt) |x|` when it is.

**`comptime unreachable`** for branches unreachable at compile time (the `else` of an exhaustive comptime switch). `errdefer comptime unreachable;` proves a function can't error.

**Return error sets, not `bool`**, for fallible operations: `fn memcpy(...) MemcpyError!void`, not `fn memcpy(...) bool`.

**Helpers are private** (`fn`, not `pub fn`) unless a caller outside the file needs them.

**Capitalised type-files**: `Foo.zig` for a file whose primary export is a type; lowercase for files exporting several decls (`wm/protocol.zig`).

**Naming**: short verbs — `tagged`, `subslice`, `getUserRange`. Avoid `getX`/`isX` when the result can carry more than a bool.

---

## Part 3 — Fault-safe user memory access

**The problem.** Validate-then-`@memcpy` has two holes: (1) a user-triggerable kernel panic — a pointer in-range but unmapped, or a guard page, makes the fault handler panic; (2) TOCTOU on SMP — a sibling thread can `munmap` between the check and the copy.

**The fix.** Perform the copy; if an unhandleable fault occurs, the page-fault handler sets a per-task result slot to "failed" and redirects the faulting instruction to a recovery label. The syscall returns `BadAddress` instead of panicking. No pre-check to race, no fault that escapes. This is how `copy_to_user` works in mature kernels.

The two complementary directions:
- **Fault-fixup under the typed API.** `validateUserBuffer` stays as a cheap early reject; the actual copy becomes `arch.paging.safeMemcpy` so unhandleable faults return `error.BadAddress`. `copyFromUser`/`copyToUser`/`readUser`/`writeUser` keep their signatures; only their implementation changes.
- **Shrink the surface that needs it.** Move bulk data through shared frame capabilities (map a `Frame`/`gpu_buffer` cap into both address spaces, zero-copy). The kernel only copies small fixed-size control structures; the fault-fixup is the safety net for those.

Status: x64 done. Arm needs data-abort → `onPageFault` routing (decode ESR/FAR in `arm/vectors.zig`, build `PageFaultDetails`). This unblocks safe-copy and demand paging on arm simultaneously.

---

## Part 4 — Mechanical style recipes

Run `zig build verify -Darm=true` after each sweep.

**A. `orelse unreachable` → `.?`**
Find: `rg 'orelse unreachable' --type zig` (or let `zig build lint`'s `no_orelse_unreachable` rule find them). Per site: provably non-null → bare `.?`; a message would help a future reader → `orelse @panic("reason")`; value then used in the same expression → keep as `if (x) |y|` / `const y = x orelse ...;`. Skip generated code and test fixtures.

**B. `unreachable` → `comptime unreachable`**
Only where the branch is unreachable at compile time (the `else` of a comptime-known switch, a path the type system already excludes). Leave runtime assertions alone. Add `errdefer comptime unreachable;` to functions that must not fail.

**C. Protection/cache flag formatting**
Absent permission bits print `-` (ls-style `rwx`), not `*`. Use `/` as the field separator (`U/RWX/WB`) so `-` is unambiguously "bit absent."

**D. Sectioned doc comments**
Add `### Arguments/Errors/Return` to syscall wrappers and handlers when a file is touched — apply uniformly across the file.

**E. Error sets over `bool`**
When touching a `fn ...() bool` whose `false` means "failed", convert to `Error!void`. Mechanical at call sites (`if (!f()) return err` → `try f()`).

---

## Part 5 — When goals conflict

Style, efficiency, and security don't usually fight each other here — "make illegal states unrepresentable" (Part 1) is simultaneously the simplest *and* the safest choice, not a tradeoff. When they genuinely do conflict: **judge case-by-case, don't apply a formula.**

One part of this isn't up for debate: a capability-security invariant (rights monotonicity, fault isolation, the user/kernel boundary) is never traded away for elegance or speed. If a defensive check looks ugly, the fix is a better abstraction that makes the check invisible at call sites (Part 1's "make misusable APIs impossible to misuse") — not deleting the check.

Past that, there's a real bias worth naming so reviewers aren't guessing, not a mechanical priority ladder: lean security first, then simplicity (the simplest implementation that satisfies the security requirement — don't add generality, caching, or configurability the current call sites don't need, see karpathy-guidelines), then efficiency last and evidence-gated (optimize a named, identified hot path — syscall dispatch, scheduler, page-fault handling, IPC — not speculatively; a "more efficient" pattern that adds real complexity needs to point at what it's actually saving, the same way `docs/verification-and-ci.md`'s apt-caching decision was left alone pending real step-duration data rather than optimized blind).

That bias is a tiebreaker, not an algorithm. Genuinely hard calls — where a reasonable second engineer would disagree, or where the right answer depends on context this guide can't see — get flagged to the project owner (matching the "three explicitly deferred judgment calls" pattern already established in `docs/roadmap.md`) rather than resolved silently, *even when the bias above would technically resolve them.* Silent resolution via the bias is for the easy cases only.

## Part 6 — Voice and tone

- **Banners, informal log lines, and comments with no contract**: playful and warm is fine and encouraged. Don't sanitize these into generic kernel-log sobriety.
- **Doc comments, error messages, invariant notes, anything a future contributor relies on to not break something**: precise and professional. The joke stops at the boundary of something someone will grep for at 2am while debugging a page fault.
- A style-review finding that "this comment is too casual" only applies inside that second category — never flag tone alone in a banner or an internal log line.

## Part 7 — Efficiency-conscious style

Newly explicit for Phase 2's efficiency mandate (Parts 1-4 predate it and don't cover this ground). Efficiency sits last in Part 5's bias and is evidence-gated — these are the concrete forms that takes:

- **Don't allocate where a bounded-lifetime stack/arena value works.** Heap allocation is for genuinely unbounded or cross-call-lifetime data; a value that dies at the end of the function or the syscall doesn't need `memory.heap.allocator`.
- **No redundant computation across independent steps in the same request path** — if two branches of a syscall or fault handler compute the same derived value, compute it once and pass it down, don't re-derive.
- **Branch hints target named hot paths**: scheduler tick, syscall entry/exit, and IPC send/recv get `@branchHint(.likely)`/`.unlikely` on their fast/slow forks (the mechanical rule itself is in Part 2); error returns and first-time lazy init get `.cold`.
- **False-sharing defense (Part 1) is the one default-applied exception** — cache-line markers on hot atomics are cheap insurance, always worth adding regardless of measurement. Everything else here needs a named hot path or a measured cost before you add it.
- **Prefer cap-based zero-copy over streaming copies for bulk data.** Part 3 already establishes this for the user-memory boundary specifically; it's the general default for any bulk-data path.
