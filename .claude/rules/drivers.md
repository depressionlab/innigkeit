---
paths:
  - "src/innigkeit/drivers/**"
---

# Device driver invariants

Drafted during Phase 3 Stage 11 (`docs/phase3-review-plan.md`), same
convention `.claude/rules/acpi.md`/`memory.md`/`scheduler.md`/`x64.md`/
`arm.md` established for their subsystems. Does not cover
`src/innigkeit/drivers/tpm/`'s boot-security *design* decisions (those live
in `.claude/rules/tpm-secure-boot.md`, scoped to `acpi/tables/TPM2*` +
`capabilities/types/SecureVault*`) — this file is about this directory's
own driver-level defects.

## Device/firmware-reported length, offset, and address fields need the same bounds-checking as ACPI tables — inconsistently applied here too

The same bug class `.claude/rules/acpi.md` documents for ACPI table parsing
(a firmware/device-controlled length or offset used in arithmetic with no
bound before the operation) recurs here, since virtio devices and the TPM
are the same kind of "softer" trust boundary:

- **`virtio/gpu.zig`'s `getDisplayInfo()` — FIXED (Stage 11).** Accepted
  any `mode.r.w`/`mode.r.h` from the virtio-gpu device's `GET_DISPLAY_INFO`
  response with only a `> 0` check, no upper bound, before computing
  `fb_width * fb_height * 4` for the backing-store allocation size — a
  large-enough device-reported mode overflows that multiplication (Zig
  panics on checked-multiply overflow). The file already defined
  `MAX_FB_PAGES` ("Maximum supported framebuffer") but never referenced it
  anywhere. Fixed: added `modeFitsFramebuffer()` using saturating
  arithmetic (`*|`/`+|`) so an oversized report saturates and safely fails
  the `MAX_FB_PAGES` comparison instead of overflow-panicking.
- **`tpm/crb.zig`'s `fromAcpi()` — FIXED (Stage 11).** `head_phys =
  control.value - @sizeOf(RegsHead)` had no check that the ACPI TPM2
  table's `address` field was actually `>= @sizeOf(RegsHead)` (0x40) —
  exactly the same shape as the already-fixed `MCFG.baseAllocations()`
  underflow (`.claude/rules/acpi.md`). Fixed: reject (return `null`) any
  `control.value` below `@sizeOf(RegsHead)`, same as the existing `== 0`
  check right above it.
- **`tpm/crb.zig`'s `bufferAt()` — FIXED (Stage 11).** The one deliberate
  bounds check in this file (`p < region_phys or p + len >
  region_phys + region_size`, guarding every command/response buffer
  address the TPM's live control-area registers report) could itself
  overflow-panic if the device reported `p` near `usize::max`, defeating
  the exact check meant to catch a bad address. Fixed with a saturating
  add (`p +| len`).
- **`virtio/blk.zig`'s `readSectors`/`writeSectors` — FIXED (Stage 11).**
  `lba + count > dev.capacity_sectors` could wrap for `lba` near
  `u64::max`, bypassing the range check (though with no memory-safety
  consequence here — the DMA scratch buffer is independently bounded by
  `count <= 8`, and the virtio-blk device itself rejects the resulting
  out-of-range LBA with an I/O-error completion). Fixed anyway
  (`lba > capacity_sectors or count > capacity_sectors - lba`) since it's
  free and matches the project's bias against any caller-controlled sum
  bypassing a bounds check via wraparound.
- **`tpm/eventlog.zig` and `tpm/tpm.zig` — the correct pattern, already in
  the codebase.** Every TCG-event-log offset/length and every TPM
  response's TPM2B length field is checked against the buffer size
  *before* the arithmetic or slice that uses it — `eventlog.zig`'s
  `parseVariableData` even says so explicitly ("Bound both lengths against
  the event before any arithmetic (garbage-safe)"). Point any future
  driver at these two files as the template; `crb.zig`'s two gaps above
  were a real, localized inconsistency relative to the rest of this same
  subsystem, not a systemic issue.

## `virtio/legacy.zig`'s `LegacyQueue` is the shared vring layer for blk/net — its bounds-checking is the reason those drivers don't need their own

`LegacyQueue.setup()` rejects a device-reported queue size of `0` or
`> QUEUE_SIZE_MAX` before it ever feeds `usedOffset()`/`ringPageCount()`'s
arithmetic — the layer both `blk.zig` and `net.zig` build on. Both callers
additionally validate device-supplied `used` ring entries
(`elem.id`/`elem.len`) against their own buffer bookkeeping before
touching memory (`net.zig`'s `pollRx()` has an explicit comment: "Validate
the device-supplied values before touching memory"). Any new virtio driver
built on `LegacyQueue` should follow the same pattern: the ring layer
bounds-checks the *device's* declared queue size once at setup, but each
individual `used` ring entry's `id`/`len` is the *driver's* responsibility
to re-validate against what it actually owns, every time.

## `SealedObject` (`tpm/tpm.zig`) trusts its own `private_len`/`public_len` fields once constructed

`load()` slices `obj.privateBytes()`/`obj.publicBytes()` using
`private_len`/`public_len` with no re-validation against `private.len`
(256) / `public.len` (128) at that call site — safe today because the only
producer, `create()`, already validates both lengths before ever
constructing a `SealedObject`. If a future change adds a second producer
(e.g. deserializing a `SealedObject` from disk in `filesystem/`), that
producer must perform the same validation `create()` does; `load()` itself
does not re-check.
