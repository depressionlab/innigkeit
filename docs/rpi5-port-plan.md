# Raspberry Pi 5 port plan

Research pass completed 2026-09-14 (web research + codebase audit, no hardware
in hand yet). Companion to `docs/aarch64-port.md` (the QEMU `virt` aarch64
port this builds on) — read that first; this doc only covers what's
*different* about real Pi 5 hardware.

**Project-owner decisions (recorded 2026-09-14), superseding the original
§6 recommendations below where they conflict:**

1. GIC/UART address discovery uses **the more complicated system**: runtime
   ACPI/MADT discovery (§6 decision #1's "heavier" option), not a build-time
   `-Dboard=` flag. See the updated PM0 in §5.
2. **SD card is the first storage target**, not NVMe — reverses §2's
   original NVMe-first lean (§6 decision #3). RP1/SDIO comes before `pcie1`
   NVMe in the milestone order.
3. **Hardware TPM (PM6) is deferred** — not part of this port's near-term
   scope (§6 decision #4).
4. **Porting strategy**: port/adapt PCIe and storage bring-up from an
   existing working driver (Linux's `pcie-brcmstb.c` for BCM2712 PCIe;
   RP1's DWC_mshc/SDHCI glue for SD) rather than reimplementing from the RP1
   datasheet from scratch. See the new §2a and the line-count estimate at
   the end of §2.

---

## Verdict up front

**Feasible, but materially harder than the QEMU aarch64 port, for one
structural reason**: on QEMU's `virt` machine, every device Innigkeit talks to
(GIC, PL011, virtio-blk/net/gpu) is a simple, always-mapped, well-documented
synthetic device. On real Pi 5, the CPU/GIC/timer are just as simple and
directly comparable — but *every other piece of I/O that matters* (USB,
Ethernet, SD-card storage, and even the "real" per-pin UARTs) lives behind
**RP1**, a companion chip reached only over a PCIe link that firmware
deliberately leaves untrained. Getting a shell prompt with disk and network
access on real Pi 5 hardware requires writing a full Broadcom PCIe
host-controller driver and an RP1 peripheral driver from a still-partial
public datasheet — there is no virtio-equivalent shortcut. Nothing else
in this plan is anywhere near as hard as that one piece.

The good news: a meaningful, real first milestone (boot to the existing test
suite over serial, on real Cortex-A76 silicon) does **not** need any of that,
and a surprising amount of Innigkeit's existing arm code turns out to already
be more portable than the "QEMU-only" framing suggests (see below).

---

## 1. The SoC and what's actually different from QEMU `virt`

- **BCM2712**: quad Cortex-A76 @ 2.4 GHz, 12-core VideoCore VII GPU. CPU
  architecture is standard ARMv8.2-A — nothing exotic for the parts of
  Innigkeit that don't touch MMIO (scheduler, capabilities, memory, syscalls,
  the whole non-driver kernel).
- **GIC**: GIC-400, i.e. **GICv2-compatible** — the same interrupt
  architecture Innigkeit's M3 SMP work (`arm/gic.zig`) already implements and
  has tested (SGIs, IPIs, per-executor CPU interface). This is the single
  biggest piece of good news in this whole investigation: the GICv2 driver
  built for M3 is very likely reusable almost as-is, once its addresses stop
  being hardcoded (see §4).
  - Distributor/CPU-interface block base: **`0x10_7FFF_8000`**, corroborated
    by multiple independent bare-metal writeups — but treat this as
    "needs on-hardware confirmation before first use," not gospel; a wrong
    GIC address is a silent hang, not a helpful fault. The devicetree
    reports a *different* address (`0x10_7FFF_9000`) for the same block, and
    at least one bare-metal developer specifically warned that applying the
    devicetree address with the standard GIC-400 offset table gives wrong
    results — there's a real, documented discrepancy here to resolve
    empirically, not by picking whichever value "looks more official."
  - **[F] GIC-400 base address venn `0x10_7FFF_8000` vs `0x10_7FFF_9000`
    needs first empirical confirmation.** Do NOT commit either to code
    without booting real hardware with a scoped-down probe.
- **Timer**: pure ARM generic timer (`CNTV_CTL_EL0`/`CNTVCT_EL0`/
  `CNTV_CVAL_EL0` system registers) — architecturally standard, **zero
  SoC-specific dependency**. Innigkeit's `arm/timer.zig` is confirmed
  register-only (no MMIO base at all) — this file should need **no changes**
  for Pi 5.
- **A dedicated, always-on debug UART exists directly on the BCM2712 die**,
  at `0x107d001000` — a real PL011, on the board's 3-pin JST-SH debug
  connector, initialized by firmware at boot and explicitly documented as
  safe for OS/TF-A-level early console use. This is the practical anchor for
  a first bring-up milestone: it means "get a boot log out of the box" does
  **not** require PCIe/RP1 to be working at all.
- **Everything else** (the "normal" 40-pin-header UART, USB 2.0/3.0,
  1 Gbps Ethernet via a Broadcom PHY) lives on **RP1**, Raspberry Pi's own
  custom I/O companion chip (dual Cortex-M3, connected over 4 PCIe lanes).
  RP1 has a public, if still described as "draft," datasheet.
- **Correction (PM4 pass): the physical microSD card slot is *not* behind
  RP1 after all — this was wrong above.** Fetching and reading the actual
  reference devicetree (`raspberrypi/linux`,
  `arch/arm64/boot/dts/broadcom/{bcm2712.dtsi,bcm2712-ds.dtsi,bcm2712-rpi-5-b.dts}`)
  rather than relying on the general "RP1 owns all the I/O now" framing found
  the real wiring: the board's `&sdio1 { status = "okay"; ...  }` override —
  commented directly in the reference DTS as `/* SDIO1 is used to drive the
  SD card */` — is a plain on-die controller
  (`compatible = "brcm,bcm2712-sdhci", "brcm,sdhci-brcmstb"`, at
  `soc@107c000000`'s `mmc@fff000`, i.e. physical `0x10_00FFF000`) with a real
  card-detect GPIO and a fixed 200 MHz `clk_emmc2`, not a PCIe-attached RP1
  peripheral. RP1 does have its own `mmc@180000`/`mmc@184000` nodes
  (`compatible = "raspberrypi,rp1-dwcmshc"`) — but those are `status =
  "disabled"` on this reference board and drive something else (their
  `broken-cd`/no-`vmmc`-fixed-3.3V wiring doesn't match a real removable
  card slot the way `sdio1`'s does); WLAN SDIO (`sdio2`) is a *third*,
  separate on-die controller, also not RP1. **This means PM4 (storage) does
  not depend on PM3 (PCIe/RP1) at all** — see the updated PM3/PM4 below. A
  driver now exists: `src/innigkeit/drivers/sdhci/brcmstb.zig` (unverified,
  see its own doc comment).

## 2. PCIe / RP1 — the hard part

BCM2712 has **three** PCIe controllers (Broadcom "STB"/iProc family, the same
lineage Linux's `pcie-brcmstb.c` driver — itself derived from the BCM7712 code
paths — already supports for this chip):

- `pcie0` — general purpose
- `pcie1` — routed to the M.2/NVMe FFC connector on Pi 5's underside
- `pcie2` — routed to RP1 (this is the one that matters for USB/Ethernet/SD)

**Firmware does not train any of these links** (`PHYLINKUP=0`, `DL_ACTIVE=0`
at handoff) — VideoCore only loads RP1's own firmware over I²C into RP1's
SRAM before the PCIe link even exists. Link training, and therefore reaching
RP1 (or an NVMe drive) at all, is explicitly left to the OS. Known
BCM2712-specific quirks an implementation has to get right (confirmed from
Linux's own driver, which had to add BCM2712-specific code paths distinct
from the BCM2711/Pi4 version it's descended from):
- **RESCAL**: a single shared analog calibration block (`~0x10_0011_9500`)
  common to all three controllers that must be initialized and polled
  *before* the first controller comes up.
- **SSC forced off**: BCM2712's MDIO register map differs enough from
  BCM2711 that the inherited SSC (spread-spectrum clocking) programming
  sequence is invalid on this chip and must be skipped, not adapted.
- MSI handling differences in this generation of Broadcom's root complex
  have needed dedicated workarounds in other OS's drivers too.

Once the link to RP1 is up, RP1 itself needs its own peripheral driver
(BAR0-mapped registers; the one concretely reverse-engineered data point
found this pass: firmware maps RP1's BAR0 to CPU address `0x1f00000000`, with
UART0 living at offset `0x30000` inside it — see the `BatMetal` project,
which exists specifically to drive RP1 bare metal for this reason).
**This is genuinely new engineering, not adaptation of existing Innigkeit
code** — nothing in the current PCI/virtio code (`drivers/pci/`,
`drivers/virtio/`) transfers, since those exist to talk to QEMU's *virtual*
devices over a generic ECAM, not to bring up a real, quirky, Broadcom-specific
root complex from cold.

**Storage order: SD card first (project-owner decision, reversing this
plan's original NVMe-first lean).** The original reasoning above (NVMe is an
open, well-specified protocol vs. RP1's comparatively undocumented SDIO
block) is still true as a pure engineering-tractability argument, but SD
wins on the criterion that actually matters more: every Pi 5 has a
microSD slot; not every Pi 5 has an NVMe HAT attached. SD-first also
happens to line up with the porting-strategy shift in §2a below — RP1's SD
controller turns out to be a **standard Synopsys DWC_mshc/DWC_mshc_lite
core wrapped in the ordinary SDHCI register interface**, not fully custom
Broadcom silicon, which de-risks the "undocumented Southbridge" concern
considerably once there's a real driver to port from rather than a
datasheet to reverse-engineer against.

## 2a. Porting strategy: adapt existing drivers, don't reimplement from the datasheet

Project-owner direction: *"try to find a project that did this already; we
don't gain much by reimplementing every Raspberry Pi driver in Zig at this
point."* Concretely, that means:

- **PCIe host-controller bring-up** (RESCAL calibration, link training, the
  SSC/MDIO quirk) is ported from Linux's `drivers/pci/controller/pcie-brcmstb.c`
  (BCM2712-specific code paths) and `pcie-iproc.c` (generic iProc config-space
  access), translated line-for-line where the register sequence is what
  matters, not re-derived from RP1/BCM2712 documentation from scratch.
- **RP1 SD/SDIO** is ported from the generic Synopsys DWC_mshc SDHCI glue
  (`drivers/mmc/host/sdhci-of-dwcmshc.c` upstream) plus whatever RP1-specific
  register differences the `raspberrypi/linux` downstream fork's own
  DWC_mshc glue documents — not written against the RP1 datasheet's raw
  register tables as a first resort.
- This is a translation/adaptation exercise (C register-poke sequences →
  Zig, with Innigkeit's own driver-registration/PIO conventions), not a
  research-and-derive exercise. It should read like `arm/Pl011.zig` or
  `drivers/tpm/crb.zig` — a straightforward MMIO register driver — not like
  a reverse-engineering log.

**Line-count estimate for PCIe (`pcie2`, RP1 only) + SD, minimal scope
(single board, polling/PIO only — no DMA, no MSI, no UHS speed modes, no
hotplug):**

- PCIe bring-up: RESCAL init/poll, link-training/PERST sequencing, the
  SSC-skip (mostly *omitting* code, not writing it), and a single-controller
  ECAM/config-space read/write wrapper plus RP1 BAR0 window setup —
  measured against `pcie-brcmstb.c`'s real BCM2712-specific code (~80-120 of
  its ~2,400 lines are the actual quirks) plus the generic scaffolding
  around it, this is roughly **300-500 lines** of Zig.
- RP1 SD/SDHCI: clock/reset init, card detection, the SD command state
  machine (CMD0/CMD8/ACMD41/CMD2/CMD3/CMD9/CMD7/CMD16/CMD17/CMD18/CMD24/
  CMD25), PIO block read/write — a trimmed, PIO-only SDHCI+SD-protocol
  driver (no DMA/UHS/tuning, which is most of what makes upstream SDHCI
  drivers large) lands around **400-600 lines**.
- **Total: roughly 700-1,100 lines.** This straddles the ~1,000-line mark
  the project owner asked about rather than clearing it comfortably —
  see the note in the chat reply for the honest uncertainty behind that
  range (in short: the PCIe side is grounded in a real driver I've read
  directly; the RP1-specific SD glue is only confirmed to exist in the
  downstream `raspberrypi/linux` fork, which I have not yet fetched and
  read line-by-line, so that half of the estimate is closer to an
  informed category guess than a measured one).

## 3. Firmware and boot chain

- **No official Raspberry Pi Foundation UEFI firmware exists.** The
  community has built one: originally `worproject/rpi5-uefi` (TF-A + EDK2),
  **archived February 2025**, whose final release only really worked
  correctly on early "BCM2712C1" boards and has known problems on current
  production **"D0" revision boards**. The actively maintained fork today is
  **`NumberOneGit/rpi5-uefi`**, which specifically fixes D0-board pin-control
  remapping — **this is the firmware to target**, not the archived original.
- Install is SD-card-based: FAT32 partition, firmware files extracted to its
  root alongside `config.txt`, boots to a UEFI shell/boot-manager the same
  way Pi 4's PFTF firmware does (which Limine is independently confirmed to
  have been tested against on real Pi 4 hardware — a good sign for the
  general "Limine + community Pi UEFI firmware" combination, though no
  direct Pi-5-specific confirmation of Limine was found this pass; that's a
  first-boot-attempt risk to budget for, not a known blocker).
- **ACPI mode is explicitly immature**: the maintainer describes it as
  "under development, limited to a few devices with existing driver
  bindings." Concretely: the PL011 ACPI driver in the firmware's own boot
  environment fails to start (though the DBG2-described debug console still
  works independent of that), and ACPI-mode PCIe is limited to
  single-function devices. **Device Tree mode gives better hardware support**
  per the maintainer, but its bundled DTB targets the Linux downstream
  6.1.y kernel specifically — not something Innigkeit could consume as-is.
- Ethernet is reported flatly "not working" in the firmware itself
  regardless of mode; eMMC/CM5 status is "unknown," with NVMe/USB
  recommended instead for Compute Module 5 users.
- **PSCI is implemented** (TF-A's BL31 provides it) and **multi-core SMP is
  confirmed working** for other OSes booted via this firmware — meaning
  Innigkeit's existing Limine-mediated AP bring-up (which already goes
  through real PSCI under the hood, not a from-scratch implementation)
  should transfer with no conceptual change, once the boot chain otherwise
  works.
- **Secure Boot status on this firmware is unresearched** — genuinely don't
  know yet whether it implements UEFI Secure Boot verification at all. Flag
  as open, not as "probably fine."

## 4. What this means for Innigkeit's existing arm code

Audited the actual current arm architecture code (not assumed from memory):

| Component | Current state | Pi 5 impact |
| --- | --- | --- |
| `arm/timer.zig` | Pure system-register (`CNTV_*`), no MMIO base at all | **No change needed.** |
| `arm/Pl011.zig` | **Superseded by the PM0 UART fix below — no board-specific change needed here after all.** Already takes `base: u64` as a runtime parameter to `init`/`getInitOutput`; only the *default* `UART_BASE` constant (`0x0900_0000`, QEMU's address) is QEMU-specific | This row originally called for hardcoding the real debug-UART base (`0x107d001000`) at the arm init call site. PM0's `.prefer_generic` flip means that's no longer necessary *if* Pi 5's SPCR/DBG2 table correctly describes the debug PL011 — the existing generic path would then discover `0x107d001000` itself, no hardcoded address anywhere. `UART_BASE` stays exactly what it says on the tin: the QEMU-`virt`-only last-resort fallback for when SPCR/DBG2 isn't available (unaffected by any of this). Whether real hardware's SPCR actually holds up is unconfirmed until PM1's real boot — if it doesn't, *then* a hardcoded fallback base becomes the right fix, informed by what the real boot log shows rather than guessed now. |
| `arm/gic.zig` | **DONE (PM0).** `distributorBase()`/`cpuInterfaceBase()` accessors backed by module-level vars, `setBases()` override called from `arm/init.zig`'s MADT parse | Was: `GICD_BASE: u64 = 0x0800_0000` hardcoded `const`, no override mechanism. |
| `arm/PageTable.zig`'s `mapDeviceMmio` | **DONE (PM0).** GIC region bases now come from `arm.gic.distributorBase()`/`cpuInterfaceBase()` at map time (as two independent 64 KiB regions, not one contiguous span) | Was: a hardcoded comptime array of `{base, size}` device regions matching only QEMU `virt`. |
| `acpi/` (`uacpi`-based) | **Confirmed reusable as-is, no new ACPI-side code needed** — `acpi.init.AcpiTable(MADT).get(0)` plus `MADT.iterate()` already existed and needed only a new consumer (`arm/init.zig`'s `discoverGicAddressesFromMadt`); the console-UART side turned out to already be *fully wired* (`SPCR.init.tryGetSerialOutput` already handles `ArmPL011`) and only needed arm's own `Pl011.getInitOutput` preference flipped from `.use` to `.prefer_generic` to actually get used | Whether Pi 5's immature ACPI mode hands over a correct MADT (and a working SPCR/DBG2 for the debug UART) in practice is still a PM1 question — the maintainer's "under development" caveat was about *driver bindings* (PL011, PCIe), not necessarily about MADT's own correctness. |
| PCI/virtio (`drivers/pci/`, `drivers/virtio/*`) | ECAM-based enumeration of QEMU's synthetic virtio devices | **Not reusable for real hardware I/O.** A real PCIe host-controller driver (§2) and RP1/NVMe device drivers are new subsystems, full stop. |
| TPM (`drivers/tpm/crb.zig` transport; `tpm.zig`/`Session.zig` command layer) | CRB (memory-mapped) transport only | No on-board TPM on Pi 5. An SPI-attached hardware TPM (e.g. Infineon Optiga SLB9672 on a "LetsTrust"-style HAT) is a real option for the boot/at-rest security epic, but needs a **new TPM-over-SPI transport driver** (per the TCG PC Client SPI interface spec) — the command layer (`tpm.zig`, `Session.zig`, `kdf.zig`, all of this session's SB-7 work) is transport-agnostic and would sit on top unchanged. |

## 5. Staged milestone plan

Mirrors `docs/aarch64-port.md`'s M1→M2→M3 structure (boot+test-suite, then
storage, then SMP), but Pi 5's version of each stage is a bigger lift than
its QEMU equivalent, and a genuinely new PM0 stage (board abstraction) has
to come first since QEMU-`virt`-only assumptions are baked into arm today.

**PM0 — Board abstraction via runtime ACPI/MADT discovery (project-owner
decision: the "more complicated system," not a build-time flag). — DONE for
the code side; PM1 still owes real-hardware confirmation.**
`arm/gic.zig`'s distributor/CPU-interface bases and `PageTable.zig`'s
device-MMIO table no longer hardcode QEMU-`virt`-only constants:
`arm/init.zig`'s `captureSystemInformation(.early, ...)` now parses the
firmware's MADT (via the already-present `uacpi`/`AcpiTable` infrastructure
— turned out to need no new ACPI-side code at all, just a new consumer) for
the `gic_distributor`/`gic_cpu_interface` entries' `physical_base_address`
fields and feeds them to a new `arm.gic.setBases()`, which
`PageTable.zig`'s device-MMIO mapping now reads at map time instead of a
comptime table. This has to run at the `.early` stage specifically —
*before* `initializeMemorySystem` builds that mapping — since ACPI
early-table access is already up by then (`stage1.zig` calls
`acpi.init.earlyInitialize()` before `captureSystemInformation`) but the
device-MMIO table is built immediately after; discovering the addresses any
later would map the wrong physical range. Falls back to the QEMU-`virt`
fixed addresses (logging why) if the MADT or either GIC entry is absent, so
this is a strict superset of the old hardcoded behavior, not a replacement
that could regress QEMU. The console UART got the same treatement for free:
turned out `Output.zig`'s generic ACPI-SPCR/DBG2 serial-output path already
existed and already handles `ArmPL011` — arm's `tryGetSerialOutput` was
just never given the chance to use it (`Pl011.getInitOutput`'s
`preference` was `.use`, meaning "always win," when it should have been
"only if nothing more authoritative is available"). Flipped to
`.prefer_generic`; the hardcoded QEMU PL011 path is now purely the
fallback for a board without a working SPCR/DBG2, not the default winner.
Verified: `zig build verify -Darm=true` passes at the documented arm
baseline (158 passed) with no regression, confirming the new discovery path
is at minimum transparent on QEMU `virt` (whose real MADT reports the same
`0x0800_0000`/`0x0801_0000` addresses the old hardcoded fallback used, so
this run can't yet distinguish "discovery worked" from "discovery silently
fell back and nobody noticed" — that distinction is real hardware's job,
not something a QEMU boot can prove either way). **Still owed**: PM1's
first real Pi 5 boot is what actually proves this against non-QEMU MADT
content and a real SPCR/DBG2 pointing at the debug PL011 — nothing here
should be read as "confirmed working on hardware."

**PM1 — Boot to serial console + non-driver test suite, real hardware.**
Get `NumberOneGit/rpi5-uefi` + Limine to hand off to Innigkeit at all;
console via the always-on debug PL011 at `0x107d001000` (needs no PCIe);
confirm the GIC-400 address empirically (§1's flagged item) and get
`gic.zig`'s existing SGI/IPI logic working against real silicon; run
whatever of the existing non-driver test suite doesn't depend on virtio
storage/network. This is the direct real-hardware analog of the original
aarch64 port's M1, and is where the "does this actually work at all" risk
gets retired.

**PM2 — Real SMP (all 4 Cortex-A76 cores).**
Given PSCI is confirmed implemented and multi-core is confirmed working for
other OSes on this firmware, this should be a comparatively short stage once
PM1 lands — Limine's existing AP bring-up path doesn't change conceptually.
Re-run the M3 SMP test suite (`testing/smp.test.zig`) against real hardware
instead of QEMU's TCG emulation — worth specifically re-verifying the
WFI-as-hint reschedule-IPI-latency fix from this session's earlier M3 work
against real silicon, since real hardware's WFI timing characteristics won't
match QEMU/TCG's.

**PM4 — Storage: native on-die SDHCI, not RP1 (§1's correction).**
**Done, code-side, unverified** —
`src/innigkeit/drivers/sdhci/brcmstb.zig` is a PIO-only driver (reset, clock
divider, CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7/ACMD6 init sequence, CMD17/24
single-block PIO read/write) for the on-die `brcm,bcm2712-sdhci` controller
at `0x10_00FFF000`, ported from Linux's `sdhci-brcmstb.c` (fetched and read
directly, confirmed only ~30 lines of BCM2712-specific quirks, none of which
this minimal-scope driver needs — see the file's own doc comment) plus the
generic SD Host Controller / SD Physical Layer specifications. Two real
bugs were caught and fixed by manual verification before this ever touched
QEMU or hardware: the clock-divider math originally computed a 781.25 kHz
floor for the identification phase (above the SD spec's 400 kHz ceiling —
needed the 10-bit divided-clock mode's extra 2 bits, not just headroom), and
`readSectors`/`writeSectors` could `@intCast`-panic on a `lba` near
`u32::max` with `count > 1` (fixed with a saturating bounds check per
`.claude/rules/drivers.md`'s existing bias here). Regression-tested against
a plain zeroed `Regs` struct standing in for real MMIO (`zig build
test_arm`, gated arch-appropriately) — this pins the divider bit-math and
proves every wait is genuinely bounded (fails safe with `Timeout`, doesn't
hang), but **cannot** prove the SD protocol sequencing is correct against a
real card, since no QEMU model of this hardware exists (§7). Not wired into
any boot path yet (deliberate scope cut — see `.claude/rules/arm.md` and the
file's own doc comment for why): `filesystem/ext4.zig`/`EncryptedVolume.zig`
still hardcode calls to `innigkeit.drivers.virtio.blk`, and choosing how a
given arch/board picks its storage backend is its own board-abstraction
decision (echoes PM0's), better made with PM1's real hardware feedback in
hand than guessed now. **Still owed**: PM1's first real boot, run against
`docs/rpi5-hardware-checklist.md`'s guidance to pull a real ACPI dump before
attempting anything else, is what actually proves `physical_base` and the
init sequence against real silicon — nothing here should be read as
"confirmed working."

**PM3 — PCIe host-controller bring-up (`pcie2` → RP1, USB/Ethernet only).**
No longer a storage prerequisite (§1's correction retired that dependency
entirely) — this is now purely PM5's (networking/USB) foundation. The hard
part (§2/§2a) is unchanged: RESCAL calibration, link training, the
BCM2712-specific SSC/MDIO quirk — ported from `pcie-brcmstb.c`/`pcie-iproc.c`
per §2a, not rederived from scratch. Its own test criterion stays narrow and
mechanical: enumerate RP1's config space and map its BAR0 correctly.
**Deliberately not started this pass** — unlike PM4's SDHCI driver, this has
no equivalent of "port from ~30 lines of quirks in an otherwise-generic
driver": it's genuinely new engineering (§2) with a real BCM2712-specific
register sequence, and RESCAL/link-training bugs are exactly the kind of
silent-hang failure mode that's much costlier to carry unverified than
PM4's bounded-timeout SD commands were.

**PM5 — Networking and USB.** RP1's Ethernet MAC/PHY, and RP1's USB 2.0/3.0
controllers, on top of PM3. Lower priority than storage for reaching a
usable shell (PM4 no longer needs PM3 to get there at all). NVMe over
`pcie1` (a separate controller from `pcie2`/RP1, per §1) was never
RP1-dependent either, and could in principle land independently of PM3 with
its own, separate PCIe host-controller bring-up — not committed to in this
plan; SD already covers the "usable persistent storage" need PM4 targets.
USB additionally unblocks the previously-parked YubiKey/FIDO2 recovery-key
work from the boot/at-rest security epic.

**PM6 (hardware TPM over SPI) — deferred, not scheduled.** Project-owner
decision: out of scope for this port for now. New transport driver only;
the command layer (`tpm.zig`/`Session.zig`/`kdf.zig`) already exists and is
transport-agnostic, so nothing here blocks revisiting this later — it just
isn't part of the near-term milestone sequence.

## 6. Open decisions (flagging rather than picking silently)

1. ~~**Board-selection mechanism (PM0)**~~ — **RESOLVED by project owner
   (2026-09-14): runtime ACPI/MADT discovery**, the "heavier" option
   originally recommended against. Since Pi 5's ACPI mode now has to work
   for GIC/UART discovery regardless, this also substantially answers
   decision #2 below in ACPI's favor — see the updated PM0 in §5.
2. **ACPI vs Device Tree on Pi 5 itself, for anything beyond GIC/UART**: #1's
   resolution means Innigkeit is now committed to Pi 5's ACPI mode working
   at least for MADT (and likely SPCR/DBG2 for the UART) — but whether that
   commitment extends to *other* runtime hardware description (RP1
   presence/version, memory size) via ACPI, or whether some of that ends up
   needing a devicetree parser after all if ACPI mode's coverage proves too
   thin in practice, is still open and won't be known until PM1's real boot.
3. ~~**Storage target order (PM4)**~~ — **RESOLVED by project owner
   (2026-09-14): RP1/SD first**, not NVMe. See the updated §2/§5.
4. ~~**Hardware TPM (PM6)**~~ — **RESOLVED by project owner (2026-09-14):
   deferred**, not scheduled as part of this port. See the updated §5.
5. **Firmware fork commitment**: this plan recommends `NumberOneGit/rpi5-uefi`
   over the archived `worproject/rpi5-uefi` based on its D0-board fix, but
   it's itself explicitly community-maintained with the maintainer saying
   continued development "depends on community participation" — worth
   knowing this is a soft foundation to build a whole port on, not a vendor
   commitment, before investing heavily.

## 7. Hardware and tooling this needs that a cloud sandbox can't provide

This entire plan was researched without hardware in hand. Actually executing
PM1 onward needs, at minimum: a real Raspberry Pi 5 board, a way to flash/
prepare its SD card from wherever development happens, a serial adapter for
the debug UART (the 3-pin JST-SH debug connector needs a USB-serial cable —
common but not something every setup has by default), and — for anything
past PM1 — patience for a much slower edit/flash/reboot/observe loop than
QEMU's instant-boot iteration. Worth setting expectations that this is a
different mode of working than every other milestone this project has
executed so far, which all ran inside this same cloud sandbox against QEMU.

**Checked this pass for a closer QEMU emulation option — none exists.**
This sandbox's host QEMU is 8.2.2, whose `-machine help` only goes up to
`raspi3b`; upstream QEMU's own docs (checked live, 2026-09-15) list
`raspi0`/`raspi1ap`/`raspi2b`/`raspi3ap`/`raspi3b`/`raspi4b` as the full set
of Raspberry Pi machine types that exist anywhere in QEMU, mainline or
otherwise — **there is no `raspi5`/BCM2712 machine type, and no RP1
emulation, in any QEMU version.** `raspi4b` (BCM2711) wouldn't help even if
this sandbox had a new enough QEMU to offer it: it's a devicetree/Linux-boot
target with no UEFI firmware path, incompatible with Innigkeit's
Limine+UEFI+ACPI boot flow, and BCM2711 predates RP1 entirely (Pi 4's SD/USB/
Ethernet are on-SoC, not behind a PCIe companion chip) — its GIC-400 being
architecturally the same as Pi 5's doesn't make it a useful stand-in. The
aarch64 `virt` machine this project already uses for every other arm
milestone remains the best available QEMU proxy for the parts of Pi 5 that
are architecturally generic (the Cortex-A76 core, GICv2, the ARM generic
timer, ACPI/MADT discovery in the abstract) — which is exactly what PM0
already leverages. Everything Pi-5-specific — real GIC/UART addresses, RP1,
the BCM2712 PCIe quirks — has no emulation path at all and can only be
validated on real hardware. See `docs/rpi5-hardware-checklist.md` for the
concrete PM1 bring-up procedure this implies.

## 8. Sources

- [`raspberrypi/documentation` BCM2712 processor page](https://github.com/raspberrypi/documentation/blob/master/documentation/asciidoc/computers/processors/bcm2712.adoc)
- [Raspberry Pi Forums: Using the GIC-400 of the Raspberry Pi 5 (BCM2712)](https://forums.raspberrypi.com/viewtopic.php?t=371974)
- [Raspberry Pi RP1 datasheet coverage — CNX Software](https://www.cnx-software.com/2023/10/07/raspberry-pi-rp1-datasheet-block-diagram/) / [Raspberry Pi's own RP1 announcement](https://www.raspberrypi.com/news/rp1-the-silicon-controlling-raspberry-pi-5-i-o-designed-here-at-raspberry-pi/)
- [`worproject/rpi5-uefi`](https://github.com/worproject/rpi5-uefi) (archived) and its [DeepWiki](https://deepwiki.com/worproject/rpi5-uefi) / [Device Tree Mode page](https://deepwiki.com/worproject/rpi5-uefi/4.2-device-tree-mode)
- [`NumberOneGit/rpi5-uefi`](https://github.com/NumberOneGit/rpi5-uefi) (actively maintained fork, D0-board fixes)
- [`leopoldch/BatMetal`](https://github.com/leopoldch/BatMetal) — Rust bare-metal kernel driving RP1 via PCIe directly; source of the BAR0/UART-offset data point in §2
- Linux kernel iProc/`pcie-brcmstb` driver and devicetree binding docs (RESCAL, SSC/MDIO quirks) — [`brcm,iproc-pcie.txt`](https://www.kernel.org/doc/Documentation/devicetree/bindings/pci/brcm,iproc-pcie.txt), [`pcie-iproc.c`](https://github.com/torvalds/linux/blob/master/drivers/pci/controller/pcie-iproc.c), [`pcie-brcmstb.c`](https://github.com/torvalds/linux/blob/master/drivers/pci/controller/pcie-brcmstb.c) (fetched and read directly this pass — source of the ~80-120-line BCM2712-quirk-vs-~2,400-total-line figure in §2a)
- [`sdhci-of-dwcmshc.c`](https://github.com/torvalds/linux/blob/master/drivers/mmc/host/sdhci-of-dwcmshc.c) (mainline Synopsys DWC_mshc SDHCI glue, fetched and read directly this pass — no RP1-specific mentions found in it)
- LetsTrust/Infineon Optiga SLB9672 SPI TPM HAT product pages
- Limine's own PROTOCOL.md (DTB request support) and its confirmed-on-real-Pi-4-hardware testing note

**Fetched and read directly this later pass (PM4), source of §1's RP1
correction and the `brcmstb.zig` driver** — all from `raspberrypi/linux`
(`rpi-6.12.y` branch) and `torvalds/linux` (`master`), via
`raw.githubusercontent.com` (this pass found egress to it unblocked, unlike
the "not consulted" TF-A note below — worth retrying that fetch too before
PM1):
- [`arch/arm64/boot/dts/broadcom/bcm2712.dtsi`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm64/boot/dts/broadcom/bcm2712.dtsi) — the on-die `sdio1`/`sdio2` SDHCI nodes and `clk_emmc2` this pass's whole correction rests on
- [`arch/arm64/boot/dts/broadcom/bcm2712-ds.dtsi`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm64/boot/dts/broadcom/bcm2712-ds.dtsi) and [`bcm2712-rpi-5-b.dts`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm64/boot/dts/broadcom/bcm2712-rpi-5-b.dts) — the reference board's `&sdio1 { status = "okay"; ... }` override, `/* SDIO1 is used to drive the SD card */`
- [`arch/arm64/boot/dts/broadcom/rp1.dtsi`](https://github.com/raspberrypi/linux/blob/rpi-6.12.y/arch/arm64/boot/dts/broadcom/rp1.dtsi) — RP1's own `mmc@180000`/`mmc@184000` (`raspberrypi,rp1-dwcmshc`, `status = "disabled"` on this board) and `serial@30000` (UART0), confirming which devices really are RP1-attached
- [`drivers/mmc/host/sdhci-brcmstb.c`](https://github.com/torvalds/linux/blob/master/drivers/mmc/host/sdhci-brcmstb.c) — the actual driver `brcmstb.zig` is ported from; `match_priv_2712`'s `cfginit`/`ops` confirmed to need only ~30 lines of BCM2712-specific handling, none of it required at this driver's PIO/no-UHS/real-CD-GPIO scope
- [`drivers/mmc/host/sdhci.h`](https://github.com/torvalds/linux/blob/master/drivers/mmc/host/sdhci.h) — canonical SDHCI register/bit definitions, cross-checked against rather than transcribed from memory (source of catching the clock-divider bug, see PM4 above)

**Not consulted this pass** (blocked by sandbox network egress policy, would
be worth a direct read before PM1 execution): Trusted Firmware-A's own
`rpi5.rst` platform documentation — the single most authoritative source for
the exact memory map and PSCI implementation details, currently only
triangulated here through secondary sources and forum posts.
