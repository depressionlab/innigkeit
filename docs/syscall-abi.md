# Syscall ABI reference

Per-syscall contract, maintained in sync with the dispatch table in `src/innigkeit/user/syscalls.zig` (selector + handler + entitlement gate) and the selector enum in `library/innigkeit/syscall.zig`. When adding a syscall: one table row, one handler.

## Model

**Selector**: `u64` (`Syscall` enum). x86-64: `rax`; aarch64: `x8`; riscv64: `a7`.

**Arguments**: up to 6 registers. x86-64: `rdi, rsi, rdx, r10, r8, r9`; aarch64: `x0–x5`; riscv64: `a0–a5`. Handlers read them via `ctx.arg(.one .. .six)` (typed accessors in `syscall_context.zig`).

**Result**: one register (`rax` / `x0` / `a0`). Non-negative = success; negative = error wire code. Userspace decodes with `Syscall.decode(isize) -> Error.Syscall!usize`.

**Errors**: one curated set, `Error.Syscall`, shared by kernel and userspace (`library/innigkeit/Error.zig`). Handlers return `Error.Syscall!usize`; the dispatcher maps the error to its stable wire code once. Not POSIX — a small deliberate set — though the numbers are POSIX-compatible so a future libc/POSIX-compat layer maps errno for free.

### Error wire codes (`Error.Abi`, append-only)

| code | Error.Syscall | code | Error.Syscall |
|---:|---|---:|---|
| -1 | PermissionDenied | -17 | AlreadyExists |
| -2 | NotFound | -19 | NoDevice |
| -5 | IoError | -22 | InvalidArgument |
| -9 | BadHandle | -28 | NoSpace |
| -11 | WouldBlock | -38 | Unsupported |
| -12 | OutOfMemory | | |
| -14 | BadAddress | | |

Userspace also surfaces `error.Unknown` for an unrecognised code.

### Entitlements

Each protected syscall declares its entitlement in the table; the dispatcher enforces it before the handler runs. `Entitlements` is a packed `u64` per process set from the verified `.codesig` at spawn. Two gates are conditional and enforced inside the handler (a blanket table gate can't express them): `open` needs `storage` only with the write flag; `cap_create` needs `secure_vault` / `gpu` only for those object types.

## Registry

Gate column: `—` = unprivileged.

| # | name | gate | signature |
|---:|---|---|---|
| 0 | exit_thread | — | `() -> noreturn` |
| 1 | spawn_thread | — | `(entry, arg) -> 0` |
| 2 | write | — | `(fd, buf, len) -> n` |
| 3 | read | — | `(fd, buf, len) -> n` |
| 4 | yield | — | `() -> 0` |
| 5 | spawn | spawn | `(spec_ptr) -> notify_handle` |
| 6 | exit_process | — | `(status) -> noreturn` |
| 7 | wait_process | — | `(notify_handle) -> exit_status` (blocks) |
| 8 | cap_invoke | —¹ | `(handle, op, arg) -> result` |
| 9 | cap_copy | — | `(handle, rights) -> new_handle` |
| 10 | cap_move | — | `(handle) -> new_handle` |
| 11 | cap_delete | — | `(handle) -> 0` |
| 12 | cap_create | —² | `(type, ...) -> handle` |
| 13 | cap_revoke | — | `(handle) -> 0` (needs .revoke right) |
| 14 | mmap | — | `(size, prot) -> addr` |
| 15 | munmap | — | `(addr, size) -> 0` |
| 16 | futex_wait | — | `(addr, expected) -> 0` (blocks) |
| 17 | futex_wake | — | `(addr, max_wake) -> woken` |
| 18 | vmem_map | — | `(frame_handle) -> addr` |
| 19 | vmem_unmap | — | `(addr, size) -> 0` |
| 20 | framebuffer_map | framebuffer | `(info_ptr) -> va` |
| 21 | initfs_read | — | `(spec_ptr) -> bytes` |
| 22 | uptime_ms | — | `() -> ms` |
| 23 | blk_read | — | `(spec_ptr) -> bytes` |
| 24 | kbd_read | keyboard | `(buf, len) -> count` |
| 25 | nanosleep_ms | — | `(deadline_ms) -> 0` (blocks) |
| 26 | futex_wait_timeout | — | `(addr, expected, deadline_ms) -> 0` |
| 27 | getpid | — | `() -> pid` |
| 28 | wait_process_nb | — | `(notify_handle) -> exit_status \| WouldBlock` |
| 29 | process_kill | — | `(notify_handle) -> 0` |
| 30 | blk_write | storage | `(spec_ptr) -> 0` |
| 31 | fs_open | — | `(name, len, flags) -> fd` |
| 32 | fs_read | — | `(fd, buf, len) -> n` |
| 33 | fs_write | — | `(fd, buf, len) -> n` |
| 34 | fs_close | — | `(fd) -> 0` |
| 35 | thread_set_hint | — | `(hint) -> 0` |
| 36 | efi_var_get | — | `(spec_ptr) -> Unsupported` (stub) |
| 37 | efi_var_set | — | `(spec_ptr) -> Unsupported` (stub) |
| 38 | blk_disk_size | — | `(dev_idx) -> sectors` |
| 39 | mouse_read | mouse | `(buf, len) -> count` |
| 40 | gpu_flush | — | `(w, h) -> 0` |
| 41 | net_set_ip | network | `(ip) -> 0` |
| 42 | net_get_mac | network | `(buf) -> 0` |
| 43 | net_udp_open | network | `(port) -> sock_id` |
| 44 | net_udp_send | network | `(sock, dst_ip, dst_port, buf, len) -> 0` |
| 45 | net_udp_recv | network | `(sock, from, buf, len) -> bytes` (blocks) |
| 46 | net_udp_close | network | `(sock) -> 0` |
| 47 | net_ping | network | `(dst_ip, timeout_ms) -> rtt_ms` |
| 48 | net_tcp_listen | network | `(port) -> listener_id` |
| 49 | net_tcp_accept | network | `(listener_id) -> sock_id \| WouldBlock` |
| 50 | net_tcp_connect | network | `(dst_ip, dst_port, src_port) -> sock_id` (blocks) |
| 51 | net_tcp_send | network | `(sock, buf, len) -> bytes` |
| 52 | net_tcp_recv | network | `(sock, buf, len) -> bytes \| WouldBlock` |
| 53 | net_tcp_close | —³ | `(sock) -> 0` |
| 54 | open | —⁴ | `(path, len, flags) -> fd` |
| 55 | close | — | `(fd) -> 0` |
| 56 | lseek | — | `(fd, offset, whence) -> new_offset` |
| 57 | fstat | — | `(fd, stat_ptr) -> 0` |
| 58 | net_udp_recv_nb | network | `(sock, from, buf, len) -> bytes \| WouldBlock` |
| 59 | thread_set_qos | — | `(qos) -> 0` (0=interactive,1=default,2=background; caller only) |
| 60 | present | — | `(x, y, w, h) -> 0` (damage rect; clamped; no-op on plain fb) |

¹ `cap_invoke` checks the capability's per-op rights, not an entitlement.
² `cap_create` gates `secure_vault`/`gpu_buffer` inside the handler, conditional on the requested type.
³ `net_tcp_close` is ungated — a known gap (socket ids are global), flagged for a future security pass.
⁴ `open` requires `storage` only when the write flag (bit 0) is set; enforced in the handler.

## Adding a syscall

1. Add a variant to `Syscall` in `library/innigkeit/syscall.zig` (append-only; never renumber).
2. Write `fn(Context) Error.Syscall!usize` in the appropriate `handlers/*` file.
3. Add a `sys(.name, handlers.x.fn, .gate)` row to the table in `syscalls.zig`.
4. Add a userspace wrapper in `library/innigkeit/*` if apps need it.
5. `zig build verify -Darm=true`.
