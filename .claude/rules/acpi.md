---
paths:
  - "src/innigkeit/acpi/**"
---

# ACPI subsystem invariants

Drafted during Phase 3 Stage 10a (`docs/phase3-review-plan.md`), extended
through 10b (`uacpi_kernel_api.zig` + `root.zig`) and 10c (`uacpi.zig`), same
convention `.claude/rules/memory.md`/`scheduler.md`/`x64.md`/`arm.md`
established for their subsystems. Stage 10 (`acpi/`) is now fully reviewed.

## Firmware-supplied length/offset fields must be bounds-checked before arithmetic — inconsistently applied

`SharedHeader.isValid()` bounds `header.length` to
`[sizeOf(SharedHeader), 4 MiB]` before using it to slice the checksum
region — the correct pattern. But individual table parsers derive their own
*additional* fixed-size requirements (a table-specific reserved field, a
trailing array's element stride) from `header.length`, and not all of them
re-check against their own minimum before doing arithmetic:

- **`MCFG.baseAllocations()` — FIXED (Stage 10a).** Computed
  `header.length - (sizeOf(SharedHeader) + sizeOf(u64))` unconditionally.
  `SharedHeader.isValid()` only guarantees `length >= sizeOf(SharedHeader)`,
  not `>= sizeOf(SharedHeader) + 8` (MCFG's own reserved-field requirement) —
  a table with `length` in that 8-byte gap underflows the subtraction,
  producing a huge slice length with **no upstream check** (`pci/init.zig`
  calls `mcfg.baseAllocations()` straight off `AcpiTable(MCFG).get(0)` with
  no additional validation). This would iterate far past the actual MCFG
  table into unrelated direct-mapped memory, misinterpreting garbage as
  `BaseAllocation` entries used to set up PCIe ECAM MMIO windows. Fixed:
  return an empty slice when `header.length` is below the fixed-portion
  minimum instead of underflowing.
- **`MADTIterator.next()` — FIXED (Stage 10a zero-length case; over-length
  case found and closed in a later `/code-review` pass over the whole
  Phase 3 diff).** A firmware-corrupted `InterruptControllerEntry` with
  `length == 0` never advanced `current_ptr`, hanging the caller's loop
  forever (confirmed reachable: `x64/ioapic/init.zig`'s
  `captureMADTInformation` calls `madt.iterate()` directly during boot,
  before most error-recovery infrastructure exists). Stage 10a fixed the
  hang but left a sibling gap: nothing checked `entry.length` against what
  actually remained in the table, so `captureMADTInformation`'s
  unconditional `entry.specific.io_apic.*`/
  `entry.specific.interrupt_source_override.*` field reads (fixed byte
  offsets into the entry, independent of what `entry.length` claims) could
  run past the table's mapped extent for an entry near the table's end
  with a forged, over-large `length`. Stage 10c gave `uacpi.zig`'s sibling
  `Resources.Iterator.next()` (below) the fuller `bytes_left` treatment in
  the same pass, but it was never backported to `MADTIterator` — caught by
  the altitude angle of a later `/code-review` run over the full Phase 3
  diff, then closed to match. `MADTIterator` now tracks `bytes_left` and
  rejects zero-length *and* over-length entries the same way
  `Resources.Iterator` does; two regression tests prove both directions
  (a forged over-length entry near the table's end is rejected; a
  well-formed entry that exactly fills the remaining bytes is accepted).
- **`DBG2.zig`'s `DebugDevice` fields and `SPCR.zig`'s `namespaceString()` —
  found, NOT fixed this pass.** `offset_of_debug_device_info`,
  `namespace_string_offset`/`namespace_string_length`, `oem_data_offset`/
  `oem_data_length`, `base_address_register_offset`, `address_size_offset`
  (DBG2) and `namespace_string_offset` (SPCR) are all used as raw pointer
  offsets from the table base with **no check at all** against
  `header.length` — not even the subtraction-based check the fixed bugs
  above needed, just an unconditional `base_ptr + firmware_controlled_offset`
  dereference. A corrupted/malformed table could point these arbitrarily far
  from the table's actual mapped extent. Lower urgency than the two fixed
  bugs (both call sites are early-boot serial-console discovery paths, not
  reachable from a live syscall/user-controlled surface, and a firmware bug
  severe enough to trigger this would likely also break boot in other ways)
  but the same class of defect. **Not fixed**: doing this properly needs a
  systematic per-table audit (every offset/count field checked against its
  own table's `header.length` before use), which is a broader, dedicated
  pass rather than a spot-fix — tracked here so 10b/10c or a future pass
  doesn't have to rediscover the pattern.
- **`TPM2.zig`'s `logAreaMinimumLength()`/`logAreaStartAddress()` — the
  correct pattern, already in the codebase.** Both check
  `header.length < @offsetOf(...) + @sizeOf(...)` and return `null` before
  trusting the field. `acpiStartMethod()` in the same file has an
  unchecked subtraction (`table_length - @offsetOf(...)`) but is safe
  anyway because the result is immediately `@min`'d against the field's own
  fixed 16-byte size — an underflowed huge value just clamps back to 16,
  which is always in-bounds since `_acpi_start_method` is embedded directly
  in the struct. Point any future fix at this file's first two functions as
  the template.

## `MADT`/`DSDT`/`MCFG`'s trailing-array parsing depends on `SharedHeader.isValid()` having already run

`DSDT.definitionBlock()`'s `header.length - sizeOf(SharedHeader)` is safe
*only* because `DSDT` has no additional fixed fields beyond the header
itself, so `SharedHeader.isValid()`'s own `length >= sizeOf(SharedHeader)`
check is sufficient — this is the one trailing-array table that didn't need
a fix. Every other table with its own additional fixed-size fields between
the header and a trailing array (MCFG's reserved `u64`, DBG2's two `u32`
offset/count fields) needs its **own** minimum-length check, not just
`SharedHeader`'s generic one — the bug class above is exactly what happens
when that extra check is skipped.

## `uacpi_kernel_map`/`uacpi_kernel_unmap` depend on `PhysicalRange.pageAlign()` being correct

Real, concrete beneficiary of Stage 7's `pageAlign()` fix (`address/`):
`uacpi_kernel_map` hands the caller's raw, possibly-misaligned
`(physical_address, len)` straight to `memory.heap.allocateSpecial()`,
which calls `pageAlign()` internally to round down/extend/round up exactly
per this function's own doc comment's worked example; `uacpi_kernel_unmap`
mirrors it via `deallocateSpecial()`. Before the Stage 7 fix, a range whose
last byte landed exactly on a page boundary would have been silently
under-mapped by a page here.

## `uacpi_kernel_alloc`/`free` don't hit the `memory.md` over-alignment bug

`heap/c.zig`'s `mallocWithSizedFree`/`sizedFree` always use a fixed 16-byte
`standard_alignment` — the Phase 2 Stage 5 over-alignment bug
(`.claude/rules/memory.md`) only affects `alignment > 16`, so this call
site (uACPI's C-style `alloc(size)`/`free(ptr, size)`, no alignment
parameter) is unaffected. Confirmed by reading `heap/c.zig` directly, not
assumed.

## Several `uacpi_kernel_*` synchronization callbacks are unimplemented stubs that panic (Phase 3 Stage 10b)

`uacpi_kernel_free_event`, `wait_for_event`, `signal_event`, `reset_event`,
`schedule_work`, `wait_for_work_completion`, and
`handle_firmware_request` all unconditionally `panic`/`@panic` if uACPI
ever calls them. `create_event()` doesn't panic but returns a fake,
non-functional handle (explicitly commented as a dummy implementation) —
Event objects can be created but every other operation on one crashes the
kernel. Not observed to fire in the passing test baseline (no ACPI content
in the test environment exercises Sleep/Event/deferred-work AML operators
during boot), but real hardware or richer ACPI content (thermal zones,
embedded controllers, GPE notify handlers) plausibly would. Fixing this
needs real kernel infrastructure — a counting semaphore for Events (not a
blind reuse of `sync.Parker`, which is single-waiter-shaped and doesn't
obviously match Event's counter semantics) and a real deferred-work queue —
comparable in scope to Stage 9's arm EL0-dispatch gap, not attempted this
pass. `uacpi_kernel_sleep()` was the one exception: fixed by reusing the
already-implemented, already-tested `sync.nanosleep.wait()` queue (Stage 8)
instead of panicking, since `Sleep()` (unlike `Stall()`, which correctly
busy-waits) is documented as callable from a context where yielding the CPU
is safe.

## `Resources.Iterator.next()` (`uacpi.zig`, Phase 3 Stage 10c) trusted entry `type`/`length` fields with no bounds-checking — fixed

Unlike `MADT`/`MCFG` (Stage 10a) or the table-length fields checked
elsewhere in this file, `Resources` entries aren't raw firmware bytes — they
come from uACPI's own `uacpi_native_resources_from_aml`, which strictly
validates AML resource encoding before ever writing a native entry. Even so,
the vendored C library's own equivalent iterator,
`uacpi_for_each_resource` (`resources.c`), defensively checks
`bytes_left < 4` and `current->length > bytes_left` before trusting an
entry — proof the uACPI authors consider this worth guarding regardless of
the upstream guarantee. The Zig `Resources.Iterator.next()` reimplemented
iteration instead of calling that C helper (the file's own comment: "superior"
to exposing `uacpi_for_each_resource`) and dropped those checks: no
bounds-check against the buffer's total length, and no guard against a
zero-length non-`end_tag` entry — the exact same defect class as the fixed
`MADTIterator.next()` zero-length hang from Stage 10a. Fixed by tracking
`bytes_left` on the iterator and refusing to advance past it or by zero,
mirroring the C library's own checks. Not currently reachable
(`Resources.iterate()`/`getCurrentResources`/`getPossibleResources`/
`getResources` have no caller in this codebase yet — `forEachDeviceResource`
is a separate path that already uses the C library's defensively-checked
`uacpi_for_each_resource` internally), but cheap enough to fix rather than
just document.

## `uacpi.zig`'s comptime-only handler parameters are a deliberate idiom, not a missed closure

Every `make*HandlerWrapper` factory (`InterfaceHandler`, `NotifyHandler(T)`,
`GPEHandler(T)`, `RegionHandler(T)`, `TableInstallationHandler`, etc.) takes
its handler argument typed as a bare `fn (...) T` rather than
`*const fn (...) T` — Zig requires this to be comptime-known (function
*values*, as opposed to function pointers, only exist at compile time),
which is why each wrapper is generated inside a `comptime`-evaluated
anonymous struct instead of a runtime closure. Worth noting here since it's
easy to misread as a missed capture on first glance; it isn't one.
