---
paths:
  - "src/innigkeit/pci/**"
---

# PCI subsystem invariants

Drafted during Phase 3 Stage 14 (`docs/phase3-review-plan.md`), same
convention `.claude/rules/acpi.md`/`drivers.md`/`network.md`/`filesystem.md`
established for their subsystems.

## `getFunction()`'s bus-range check was comparison-inverted for the entire lifetime of this file — fixed in Stage 14, verify any future edit against both endpoints

The bug (now fixed): `if (ecam.start_bus < address.bus or address.bus >=
ecam.end_bus) continue;` instead of the correct `if (address.bus <
ecam.start_bus or address.bus >= ecam.end_bus) continue;`. Since every
ECAM segment's `start_bus` is `0` in every topology this codebase
currently boots, the inverted comparison's actual match condition
(`address.bus <= start_bus`) degenerated to "only bus 0 matches" — which
happens to be exactly the one case that's still correct by accident, so
every device this codebase's test suite exercises (all on bus 0 in the
default QEMU topology) kept working throughout. **A green test suite does
not mean bus enumeration works** for this file specifically — the
regression test added in Stage 14 (`pci: getFunction matches any bus
inside [start_bus, end_bus), not just start_bus`) exists precisely because
the normal test suite's device placement can't detect this class of bug.
Any future change to this comparison must be checked against a bus
*strictly between* `start_bus` and `end_bus - 1`, not just the endpoints,
or a reintroduced inversion will pass the existing suite silently again.

A second, independent consequence of the same inversion: when
`start_bus > 0` (a second/later MCFG segment), the bug's match condition
also admitted addresses *below* `start_bus`, and `bus_offset = address.bus
- ecam.start_bus` (the very next line) would underflow-panic for those.
Fixing the comparison closes both the silent-misbehavior and the
crash-on-nonzero-start_bus paths at once, since they share the same root
cause.

## MCFG `BaseAllocation` entries need `end_pci_bus >= start_pci_bus` validated before subtracting — fixed in Stage 14

`pci/init.zig`'s `initializeECAM()` computes `number_of_buses =
base_allocation.end_pci_bus - base_allocation.start_pci_bus` directly from
firmware-supplied `u8` fields with no validation. A malformed MCFG entry
with `end < start` underflows this subtraction and panics during PCI ECAM
setup — very early boot, before most error-recovery infrastructure
exists. This is the same "firmware-controlled field used in unchecked
arithmetic" pattern `.claude/rules/acpi.md` documents for
`MCFG.baseAllocations()`'s array-length computation (Stage 10a) — that fix
covers the *overall entry-array length*; this one covers each individual
entry's own `start`/`end` self-consistency, a distinct field pair the
earlier fix didn't touch. Fixed by rejecting (skipping with a warning
log) any entry where `end_pci_bus < start_pci_bus`, matching this
codebase's established graceful-degradation style for malformed
ACPI-derived structures.
