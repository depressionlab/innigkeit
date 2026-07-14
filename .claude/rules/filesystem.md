---
paths:
  - "src/innigkeit/filesystem/**"
---

# Filesystem invariants

Drafted during Phase 3 Stage 13 (`docs/phase3-review-plan.md`), same
convention `.claude/rules/acpi.md`/`drivers.md`/`network.md`/`memory.md`/
`scheduler.md`/`x64.md`/`arm.md` established for their subsystems.

## On-disk structural fields used as divisors need a nonzero check at the parse boundary — `ext4.zig`'s superblock validation was missing two

The same "validate a firmware/device-controlled structural field before
using it" pattern this review has found gaps in repeatedly (ACPI table
lengths, virtio-gpu display dimensions, TPM control-area addresses, UDP
length fields) applies to on-disk filesystem structures too, with a
distinct failure mode: a field used as a *divisor* rather than a slice
bound turns "value is zero" into a division-by-zero panic instead of an
out-of-bounds read.

- **`ext4.zig`'s `mount()` — FIXED (Stage 13).** `inodes_per_group` and
  `blocks_per_group` are read from the on-disk superblock with no
  validation and used as divisors in `readInode`, `writeRawInode`,
  `writeInode`, `allocInode`, `freeInode` (`inodes_per_group`) and
  `allocBlock`, `freeBlock` (`blocks_per_group`). A corrupted or malicious
  ext4 image with either at `0` panics on the very first `readInode()`
  call — nearly every operation this driver performs. Also validated
  `inode_size >= 128` (the real ext4 minimum) in the same check: a
  too-small `inode_size` leaves the tail of the fixed 256-byte stack
  buffer `readInode`/`writeInode` read/write at unconditional offsets
  (up to `i_block` at `0x64`) uninitialized — inode metadata that later
  flows to userspace via `stat()`, making this a potential kernel-stack
  info leak on top of the crash risk. Fixed with a single check at
  `mount()`'s single parse boundary, returning `error.CorruptFilesystem`
  (an error name already used elsewhere in this file for exactly this
  kind of rejection, e.g. `combineBlockNum`'s 48-bit range check).
- **Every other file in this directory — the correct pattern, already
  present.** `initfs.zig`'s `parseOctal()` uses saturating arithmetic with
  an explicit comment on why; `simple_fs.zig`'s `allocateSectors()` widens
  on-disk `u32` values to `u64` specifically so a hostile value near
  `u32::max` can't wrap the end-of-file bounds check (with its own
  regression test); `VolumeHeader.zig`'s slot parser and
  `EncryptedVolume.zig`'s TPM-slot decoder both bound every length field
  against the buffer before using it in further arithmetic. `ext4.zig`'s
  gap was a real but localized miss in an otherwise very carefully
  hardened 1,388-line file (extent-tree depth/bounds, `DirBlockIter`'s
  zero-length-record protection, symlink hop-count and path-buffer bounds
  are all already correct) — not evidence this directory needs a broader
  re-audit.

## `Ext4.mount()` is not covered by a host-testable regression harness

Unlike `initfs.zig`'s ustar parser (tested against a synthetic in-memory
archive) or `simple_fs.zig`'s `allocateSectors()` (tested against a
synthetic directory-sector buffer), `Ext4.mount()` reads through the real
`innigkeit.drivers.virtio.blk` block-device I/O path, so a corrupt-
superblock regression test would need a fabricated disk image behind a
real or mocked virtio-blk device — no such harness exists yet. If ext4
gets a second superblock-validation gap in the future, standing up that
harness (rather than re-verifying by code trace alone, as Stage 13 did)
is worth the investment at that point.
