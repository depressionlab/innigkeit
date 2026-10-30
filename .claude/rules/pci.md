---
paths:
  - "src/innigkeit/pci/**"
---

# PCI subsystem invariants

Drafted during Phase 3 Stage 14 (`docs/phase3-review-plan.md`), same
convention `.claude/rules/acpi.md`/`drivers.md`/`network.md`/`filesystem.md`
established for their subsystems.

## ECAM bus-range checks

- `getFunction()` must reject with `address.bus < ecam.start_bus or address.bus >= ecam.end_bus`. A green suite proves nothing here: every default topology puts devices on bus 0, which also satisfies an inverted comparison. Keep the regression test that uses a non-zero `start_bus`.
- MCFG `BaseAllocation` entries need `end_pci_bus >= start_pci_bus` validated before subtracting.
