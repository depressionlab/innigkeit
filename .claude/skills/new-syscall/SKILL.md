---
description: Checklist and guidance for adding a new syscall to Innigkeit. Use when asked to add, implement, or create a syscall.
argument-hint: <syscall-name>
---

# Adding syscall: $ARGUMENTS

Follow these steps in order. Every step is required; skipping any will break the build or the ABI.

## 1. Add the selector (append-only)

In `library/innigkeit/syscall.zig`, add a new variant to the `Syscall` enum **at the end**. Never renumber existing variants — the numbers are a binary contract.

The current highest number:
!`grep -E '^\s+[a-z_]+ = [0-9]+' library/innigkeit/syscall.zig | tail -1`

## 2. Write the handler

Create `fn handle(ctx: Context) Error.Syscall!usize` in the appropriate `src/innigkeit/user/handlers/*.zig` file. Group by domain (network, capabilities, memory, misc, io, file, etc.).

Handler rules:
- Read args via `ctx.arg(.one)` .. `ctx.arg(.six)` (typed accessors in `syscall_context.zig`)
- Return `error.Yyy` from `Error.Syscall` — never raw integers
- Conditional entitlement gates (storage-only-on-write, gpu-only-for-gpu-buffer) go inside the handler, not the table
- User pointer access must go through `copyFromUser`/`copyToUser`/`readUser`/`writeUser` — never direct dereference

## 3. Add a table row

In `src/innigkeit/user/syscalls.zig`, add:
```zig
sys(.name, handlers.module.handle, .gate),
```
Where `.gate` is one of: `.none`, `.spawn`, `.storage`, `.network`, `.keyboard`, `.mouse`, `.framebuffer`, `.gpu`, `.secure_vault`. Use `.none` for unprivileged; conditional gates stay in the handler.

## 4. Add a userspace wrapper (if apps need it)

In `library/innigkeit/syscall.zig` (or a domain wrapper like `thread.zig`, `net.zig`): a typed wrapper that calls `Syscall.invoke(...)` and decodes the result.

## 5. Document it

Add a row to the registry table in `docs/syscall-abi.md`.

## 6. Verify

```
zig build verify -Darm=true
```

Expected baseline: x64 138/138, arm 98 (+13 skipped). If you added a test, counts go up.
