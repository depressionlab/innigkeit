---
paths:
  - "library/filesystem/**"
---

# `library/filesystem/` invariants

Drafted during Phase 3 Stage 20 (`docs/phase3-review-plan.md`, Tier 4).
Distinct from `.claude/rules/filesystem.md`, which covers
`src/innigkeit/filesystem/**` — the kernel-side VFS/ext4 driver. This
directory is a standalone wire-format codec library consumed by
`tools/image_builder/` to *construct* disk images at build time, not to
mount/parse arbitrary on-disk data at runtime.

## `ext.zig` is dead code — confirmed unused anywhere, self-documented as WIP

`// TODO: This file is *very* WIP.` (line 6) is accurate: grepping the
whole repo for `filesystem.ext` or `@import("ext.zig")` turns up nothing
outside this directory's own `root.zig` re-export. The file is 1,094 lines
of pure struct/enum layout definitions (ext2/3/4 superblock, group
descriptor, feature-flag bitfields) with **zero functions** — no parsing,
no arithmetic, nothing with control flow to have a traditional bug in.
Several fields already carry their own `TODO: correct field references` /
`TODO: Check all of the "Only valid if:" in the document comments`
comments, i.e. the incompleteness is already known and flagged by whoever
wrote it. Not a target for a field-by-field ext4-spec cross-reference audit
unless/until something actually starts consuming it — auditing an
acknowledged, unused draft against the real spec would be effort spent on
code nobody can currently reach a bug through.

## `fat.zig`/`gpt.zig`/`mbr.zig` are trusted-input, build-time-only — Tier 2's bug class doesn't transfer

Unlike `src/innigkeit/filesystem/ext4.zig` (mounts and parses an on-disk
image at runtime, on a real attacker-reachable boundary — see
`.claude/rules/filesystem.md`), these three files are only ever used by
`tools/image_builder/` to **construct** a FAT/GPT/MBR image from
build-system-controlled inputs (a repo-committed `ImageDescription`, app
binaries built by the same pipeline) — there is no "parse an untrusted
byte buffer" path here at all. `fat.zig`'s one real logic function,
`ShortFileName.checksum()`, is the standard VFAT short-name checksum
algorithm (`sum = ((sum & 1) << 7) + (sum >> 1) + byte` over all 11
name+extension bytes) — verified to match the canonical Microsoft
algorithm exactly. `gpt.zig`'s `Header.copyToOtherHeader()` arithmetic
(computing the backup header's `partition_entry_lba` from the primary's)
is guarded by the same branch condition that makes each subtraction safe,
and only ever operates on values the same build tool just computed for
itself, not external data.

`tools/image_builder/fat/DateTime.zig`'s day-of-month off-by-one (Stage
17) was a bug in a *consumer* of this library's `Date` type, not in
`fat.zig` itself — `Date.day`'s 1-based DOS/FAT convention was correctly
defined here throughout.

## Stage 20 found no additional bugs

A genuine negative result, not a shortened pass — matches Stage 15's
`init/` precedent of reporting "reviewed, nothing found" directly rather
than manufacturing a finding. `mbr.zig` (35 lines) is a single trivial
struct. All four files read in full.
