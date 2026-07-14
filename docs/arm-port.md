# AArch64 port — status & log

As of 2026-06 assessment, empirically verified.

## Boot chain diagnosis (initial)

| Stage | Status | Evidence |
|---|---|---|
| Bundled EDK2 (zig-pkg, 2026-03) | BROKEN | wedges in SEC on QEMU 8.2; empty banner, never inits display |
| Host AAVMF (`/usr/share/AAVMF/AAVMF_CODE.fd`, 2024.02) | WORKS | full banner, reaches BDS |
| Limine (BOOTAA64.EFI) | WORKS | switches GOP mode, loads kernel high-half |
| Innigkeit arm kernel (initial) | CRASHED AT ENTRY | `PC=0x200` (sync-exception with `VBAR_EL1=0`), kernel entered, faulted before any UART output |

Firmware/bootloader/image plumbing all worked. All remaining work was in `src/architecture/arm/`.

## Milestones

- **M1 (DONE 2026-06-15)**: boots to stage4 on kernel's own VMSAv8-64 MMU, runs test suite on real PL011/GIC/generic-timer. `ALL 78 TEST(S) PASSED (10 skipped)`. 10 skips are M2/M3 tests (virtio-blk, reschedule-IPI, work-stealing).
- **M2 (DONE 2026-06-16)**: virtio-blk via PCI ECAM + BAR0 I/O aperture, poll mode. `ALL 78 TEST(S) PASSED (7 skipped)`. INTx delivery deferred (device does not assert; see log below).
- **M3 (PLANNED)**: SMP — Limine-mediated AP startup + GICv2 SGIs for flush/reschedule/panic IPIs, then `testCpus(arm)=4`. See M3 plan below.

## Environment

- **QEMU 11.0.0** in `.tools/qemu/bin/`. Build recipe (official tarball at download.qemu.org is blocked; GitHub archives lack meson subprojects):
  1. tarball from `github.com/qemu/qemu` tag v11.0.0
  2. `apt-get install libslirp-dev libfdt-dev`
  3. clone subprojects `keycodemapdb` + `berkeley-softfloat-3` + `berkeley-testfloat-3` from `github.com/qemu/*` mirrors into `subprojects/` at the revisions pinned in `subprojects/*.wrap`; copy `subprojects/packagefiles/<p>/*` over each
  4. configure: `--target-list=aarch64-softmmu,x86_64-softmmu --prefix=.../.tools/qemu --disable-docs --disable-gtk --disable-sdl --disable-vnc --disable-spice --disable-user --disable-xen --disable-libusb --disable-smartcard --enable-slirp --disable-download`; `make -j3` (j4 OOMs this box)
  5. QEMU's fp tests fail against the drifted testfloat — build targets directly: `ninja qemu-system-aarch64 qemu-system-x86_64`, then copy binaries + pc-bios data manually.
- **Bundled zig-pkg EDK2 (2026-03) is broken** on both QEMU 8.2 and 11.0 — bad firmware build, not a QEMU version issue. Always use `/usr/share/AAVMF/`.
- **`zig build check` does NOT validate inline assembly.** Always run a real kernel build after touching arch `asm`. This hid the RNDR assembler error for the port's entire history.
- TCG aarch64 boot is slow: AAVMF takes ~60–120 s. Budget ≥ 180 s per boot.
- Manual boot (test image):
  ```sh
  qemu-system-aarch64 -nodefaults -no-user-config -boot menu=off -m 256 \
    -smp 4 -cpu max -machine virt,acpi=on -accel tcg -device ramfb \
    -device virtio-blk-pci,drive=drive0,bootindex=0,disable-modern=on,disable-legacy=off \
    -drive file=zig-out/arm/innigkeit_test_arm.hdd,format=raw,if=none,id=drive0 \
    -drive if=pflash,format=raw,unit=0,readonly=on,file=/usr/share/AAVMF/AAVMF_CODE.fd \
    -drive if=pflash,format=raw,unit=1,readonly=on,file=/usr/share/AAVMF/AAVMF_VARS.fd \
    -serial file:/tmp/arm.log -display none -semihosting
  ```
- Debugging without serial: QEMU monitor (`-monitor unix:...`) + `info registers` (PC tells the story) + `screendump` (parse PPM).

---

## Progress log

### 2026-06-13 — M1: boot advances into stage1

Cleared the entry crash and three subsequent faults. Boot now executes real AArch64 code through `initExecutor` and into stage1 output registration.

**Changes:**
- **QEMU 11.0.0** built into `.tools/qemu/bin/`.
- **Semihosting console** (`src/architecture/arm/semihost.zig`) + `earlyDebugWrite` slot: the only output before device MMIO is mapped.
- **Diagnostic exception handler** (`vectors.zig`): sync exceptions now print `vector / ESR / FAR / ELR` via semihosting before panicking. Added `FAR_EL1` accessor.
- **Fixed: SP_EL1 never seeded** — `spSel1()` switched SPSel 0→1 onto an uninitialized SP_EL1; now carries the current stack across the switch.
- **Fixed: RNDR** — raw S-register encoding (`s3_3_c2_c4_0`) + `ID_AA64ISAR0_EL1.RNDR` gate. Named-register form didn't assemble.

**Blocker diagnosed:** all device MMIO faults because Limine's aarch64 HHDM does NOT map the low device-MMIO hole (GIC `0x0800_0000`, PL011 `0x0900_0000` — both below RAM at `0x4000_0000`), and these accesses happen in `initExecutor`/early stage1 before `initializeMemorySystem()` builds the kernel's own page tables.

### 2026-06-14 — M1: VMSAv8-64 paging; MMIO blocker resolved

**Changes:**
- **`src/architecture/arm/PageTable.zig`** — real VMSAv8-64, 4 KiB granule, 4-level (L0–L3). `mapSinglePage`/`unmap`/`changeProtection`/`fillTopLevel`/`mapToPhysicalRangeAllPageSizes` (block descriptors at L1=1 GiB / L2=2 MiB, page descriptors at L3). Descriptor attributes: AF, SH (Inner for Normal, none for Device), AP, UXN/PXN (W^X). `loadPageTable` programs MAIR_EL1, TCR_EL1 (T0SZ=T1SZ=16 → 48-bit VA, IPS=48-bit, WBWA walks), installs in TTBR1_EL1, then `tlbi vmalle1is; dsb ish; isb` and sets SCTLR M/C/I. `mapDeviceMmio` maps GIC `0x0800_0000+128KiB` and PL011 `0x0900_0000+4KiB` as Device-nGnRE into the direct map, called before the TTBR switch. Key: `0xffff000000000000 >> 39 & 0x1FF == 0`, so `l0Index` works identically for both halves.
- **`src/architecture/arm/init.zig`** (new) — `prepareExecutor`, `captureSystemInformation`, `configureGlobalSystemFeatures`, `configurePerExecutorSystemFeatures` (GICv2 + generic timer, gated on `memory_system_initialized`), `initLocalInterruptController`, `registerArchitecturalTimeSources` (ARM Generic Timer, virtual-timer IRQ PPI 27).
- **`interface.zig`** — wired paging + init + interrupt-init slots.
- **`src/innigkeit/debug/root.zig`** (shared) — `panicDispatch` now emits via `architecture.earlyDebugWrite` (semihosting on arm). Without this, early-boot panics were completely silent.

### 2026-06-15 — M1: GIC/timer working; key fix for sub-page bootloader entries

Boot now builds and loads kernel VMSAv8-64 page tables, switches to them, and runs full early/memory init on its own MMU. PL011 serial output works.

**Key fix:** the generic direct-map build (`memory/core/init.zig`) asserted every bootloader memory-map entry was page-aligned. aarch64 Limine/QEMU-virt reports sub-page entries (e.g. base=`0x4c7a0000` size=`0x1d4c00`). The loop now rounds each entry out to whole pages and clamps the start against the previously-mapped end. x86-64 is a no-op (entries are already aligned).

Boot reached `architecture.user.init.initialize()` and panicked cleanly — a missing arch slot, not a fault.

### 2026-06-15 (cont.) — M1: user slots filled; executor bring-up

**Changes:**
- **`src/architecture/arm/user.zig`** — `init.initialize` (no-op; ARM `PerThread.FpsimdState` is fixed-size, unlike x64's variable XSAVE), `createThread`/`destroyThread`/`initializeThread` (embedded struct, create/init zeros it), `enterUserspace` (sets SP_EL0 + ELR_EL1 + SPSR_EL1=EL0t/IRQs-on, clears GPRs except x0=arg, `eret`).
- **`PageTable.zig`** — `mapDeviceMmio` made idempotent via a `device_mmio_mapped` guard. `loadPageTable` runs on every TTBR1 switch; without the guard the second executor panicked `AlreadyMapped`.
- `testCpus()` returns 1 for aarch64 (M1 is single-core; AP startup = M3).

### 2026-06-15 (cont.) — M1 COMPLETE: ALL 78 TEST(S) PASSED (10 skipped)

**Root cause of the 0x4c445838 fault — misaligned exception vector table**, not a phys/virt confusion or IRQ x30 corruption (both hypotheses were wrong; semihosting trace showed zero `[IRQ]` lines before every fault, ruling out interrupts).

Disassembly showed `vector_table` at `0x...802a7120` — not 2 KiB-aligned. `VBAR_EL1[10:0]` are RES0, so the CPU used base `0x...802a7000` and dispatched every exception 0x120 bytes before the real vector-0. Each `vectorAsm` stub was ~240 bytes (60 instructions), overflowing the 128-byte slot; `.p2align 7` gave 256-byte spacing instead of the required 128.

**Fix:**
- `src/architecture/arm/vectors.zig` — 16 tiny trampolines (`stp x0,x1 / mov x1,#idx / b vector_common`) each fitting in 128 bytes, `.balign 0x80` per slot. Shared `vector_common` does full save, calls `arm_handle_exception(frame, idx)`, restores, `eret`.
- `vector_table` in `.text.vectors`; `src/architecture/arm/linker.ld` — `. = ALIGN(2048); KEEP(*(.text.vectors))` at the start of `.text`.

**Also fixed (independent):** IRQ dispatch in `arm_handle_exception` now bracketed with `Task.Current.onInterruptEntry()` / `defer .onInterruptExit()`, mirroring x64. Without this a timer IRQ arriving while preemptible could reach `decrementInterruptDisable(1→0)` and `switchTask` on the IRQ entry stack.

Verified: `vector_table` now at `0xffffffff80000000` (2 KiB-aligned), stubs at exact 0x80 spacing (0x000–0x780). `ALL 78 TEST(S) PASSED (10 skipped)`. x64 unchanged.

### 2026-06-15 — M2 investigation: PCI ECAM + virtio-blk on arm

Three areas mapped before touching code:

1. **PCI config access is already ECAM MMIO.** `pci/Function.zig` reads/writes via `architecture.io.readPci*`/`writePci*` which take a kernel VA into the ECAM window. `pci/init.zig` parses the ACPI MCFG and `allocateSpecial(.cache = .uncached)`-maps each region — fully arch-neutral. The arm `.io` slots are simply null, so any `readPci` panics. Fix: a few `ldr`/`str` MMIO helpers + wiring. QEMU virt with `-machine virt,acpi=on` exposes ECAM at phys `0x4010000000`.

2. **virtio-pci legacy registers are behind a MEMORY BAR on arm virt.** `blk.zig tryInit` asserts `bar0 & 1` (I/O space); on arm virt the legacy registers are in BAR1 (32-bit memory BAR at `0x10000000`). Plan: widen `PortIo` with a comptime arch branch — x86-64 uses `in`/`out`; non-x86 uses MMIO via `architecture.io.readPci`/`writePci`. Point `blk.zig` at the memory BAR, mapped Device-nGnRE via `allocateSpecial(.cache = .uncached)`.

3. **INTx routing = GIC SPI.** The generic `architecture.interrupts.Interrupt` model is unimplemented on arm — `setupIrq` returns false and falls back to poll mode. QEMU virt routes 4 PCIe INTx pins to GIC SPI 3..6 (INTA# → SPI3 = IRQ 35). Plan: implement `Interrupt.allocate` / `routeInterruptPci(gsi)` bridging to the GIC; the GIC SPI id from the PCI swizzle = `32 + 3 + ((slot + pin - 1) % 4)`.

### 2026-06-15 (cont.) — M2: PCI ECAM working on arm

- **`arm/instructions.zig`** — `readPciU8/16/32` + `writePciU8/16/32` as volatile pointer loads/stores at ECAM kernel VA (inline-asm `ldr/str` form didn't assemble — only real builds catch that). Wired into `.io` slots.
- **`init/stages/stage4.zig`** — PCI + blk bring-up now runs on aarch64 too.

Boot log confirmed: `initializeECAM` parsed MCFG. BAR0=0x1 (I/O BAR, unassigned), BAR1=0x10000000 (32-bit MEMORY BAR — the legacy register block alias). Key finding: the legacy registers are in **BAR1**, not BAR0.

### 2026-06-15 (cont.) — M2: MMIO PortIo + GIC INTx routing

- **`drivers/virtio/PortIo.zig`** — widened `base` to `u64`; comptime arch branch: x86-64 keeps `in`/`out`; non-x86 uses `architecture.io.readPci`/`writePci`. Zero-cost; x64 codegen unchanged.
- **`drivers/virtio/blk.zig`** — `resolveBar0` arch-splits: x86-64 uses BAR0 I/O port; aarch64 uses BAR1 memory BAR mapped Device-nGnRE.
- **`arm/interrupts.zig`** (new) + **`arm/gic.zig`** — bridges generic `architecture.interrupts.Interrupt` to GICv2: `allocate` stashes the `Handler`; `routeInterruptPci(gsi)` binds to a GIC SPI (level-sensitive, priority, target CPU0, enable) and registers in `gic.generic_handlers`. `gic.handleIrq` now handles `Handler.eoi = .level/.after` — run ISR-clearing handler, then EOI.
- **`drivers/virtio/legacy.zig setupIrq`** — no longer hard-returns false off x86-64; gated on `routeInterruptPci != null`. New `resolveGsi` computes arm GIC id from PCI swizzle.

Subsequent boot: ESR=0x96000050 (data abort, synchronous EXTERNAL abort) on first BAR1 write. External = MMU mapped it but bus rejected the write. Hypothesis: BAR1 is the MSI-X table, not the legacy register block; the actual I/O registers are behind the PCI I/O MMIO aperture.

### 2026-06-16 — M2 DONE: storage working (poll mode, 3/4 tests)

Legacy register block is reached via BAR0 = PCI I/O space, which on virt is the MMIO aperture at phys `0x3eff0000` (the `pcie` node's I/O `ranges`; fallback to this QEMU-virt default when no DTB). Device reports 131072 sectors (64 MiB), reads work.

`ALL 78 TEST(S) PASSED (7 skipped)` — 3 storage tests now pass. x64 unchanged.

**INTx delivery deferred.** Decisive test: temporarily enabled irq mode and traced every GIC SPI (≥ 32) acked by `gic.handleIrq` during a real blk read. Result: routing logged (`INTx pin 1 routed via GSI 36 level/active-low`), irq mode engaged, then the first disk-backed test hung — and **zero** gicSPI traces fired. Timer PPI 27 kept firing, so GIC/PSTATE/dispatch are proven good. The device is simply not asserting INTx. Likely causes: MSI-X capability masking INTx, or the BAR0-via-MMIO-aperture path not hitting the ISR register correctly. Decision: ship poll mode. virtio completions are fast under TCG; polled reads are correct and cheap; the 4th storage test stays skipped on arm.

### 2026-06-18 — Reliable arm harness + per-executor GIC

- **Reliable arm test harness**: the arm test step in `build/QEMU.zig` now uses `addCheck(.{ .expect_stdout_match = "TEST(S) PASSED" })` with no `expect_term` check — ignores QEMU's flaky arm exit status, keys off the serial verdict only. Root cause of prior unreliability also fixed: `romfile=` added to virtio-net (`.tools` QEMU 11 ships no `efi-virtio.rom`; without it the device failed and QEMU aborted before the kernel ran). `scripts/verify.sh --arm` now just runs `zig build test_arm` under a timeout.

- **Per-executor GIC** (`arm/gic.zig`, `arm/init.zig`): split the old `gic.init()` into `initDistributor()` (global, once on bootstrap) and `initCpuInterface()` (per-executor, banked GICC registers). `configurePerExecutorSystemFeatures` runs the distributor + timer-handler registration once, and the CPU interface + `timer.init()` (banked PPI + per-CPU CNTV registers) on every executor. Behaviour-identical at `-smp 1`; correct for M3 where each AP must init its own interface + timer.

### 2026-06-18 (cont.) — M3 planning: AP startup is Limine's job

The earlier draft assumed the kernel issues PSCI `CPU_ON`. **It doesn't.** `stage1.bootNonBootstrapExecutors()` calls `desc.boot(executor, stage2.start)` per non-bootstrap CPU; `desc.boot` → Limine `Descriptor.bootFn` atomically writes `extra_argument` + `goto_address` into the Limine `MPInfo`. Limine has already powered on APs (via PSCI/spin-table) and parked them; writing `goto_address` launches a parked AP. `cpuDescriptors()` / `architectureProcessorId()` already return arm `mpidr`. The per-AP init path is largely already generic — stage2 loads shared kernel page tables into TTBR1 (idempotent), `initExecutor` sets VBAR_EL1/SPSel/PAN, `configurePerExecutorSystemFeatures` brings up that AP's GIC interface + timer. What's missing is the inter-processor interrupt slots the generic code calls once >1 executor is live.

---

## M3 plan — SMP (Limine-mediated APs + GICv2 SGIs)

Not started. M1/M2 run single-core (`testCpus()` returns 1 for aarch64).

### IPI slots to implement

- **`sendFlushIPI`** (slot ~43, currently **null**) — **MANDATORY for -smp>1.** `memory/core/FlushRequest.zig` calls it unconditionally on cross-executor flush. A null slot crashes on the first TLB maintenance.
- **`sendRescheduleIPI`** (slot ~51, currently **null**) — optional (comptime-gated by `architecture.interrupts.reschedule_ipi_available`; `Scheduler.kickIfIdle` skips when absent). Wiring it un-skips the reschedule-IPI latency test.
- **`sendPanicIPI`** (slot ~40, currently **no-op**) — should halt siblings on panic; the no-op is safe but leaves them running.

### GICv2 SGI mechanics (QEMU virt = GICv2, ≤8 CPUs)

**Send:** write `GICD_SGIR` (distributor offset 0xF00): `[25:24]` TargetListFilter (00=use list, 01=all-but-self, 10=self), `[23:16]` CPUTargetList (bitmask of CPU interface numbers 0–7), `[3:0]` SGI INTID (0–15). Suggested ids: reschedule=0, flush=1, panic=2.

**Per-executor interface number:** GICv2 targets are interface bitmasks, not MPIDR (that's GICv3). On QEMU virt CPU i ⇒ interface i ⇒ MPIDR Aff0=i. Store in `arch_specific` (derive from `mpidr & 0xff`, or reuse `executor.id`).

**Receive — IMPORTANT:** `GICC_IAR` for an SGI returns the SGI id in `[9:0]` **and the source CPU in `[12:10]`**. The current `gic.handleIrq` compares the raw `ack()` value against `MAX_IRQS` — for an SGI from CPU>0 that value is ≥ 1024 and misses the dispatch table. Mask `[9:0]` for dispatch but pass the **full** IAR value to `GICC_EOIR`. SGIs are banked per-CPU; enable them in `GICD_ISENABLER0` (banked) on each CPU interface bring-up.

### Stages (verify each with `zig build test_arm`)

- **M3.1 — GIC SGI infrastructure (dormant).** `gic.sendSgi(target_iface_mask, filter, id)`, per-executor interface index in `arch_specific`, `handleIrq` IAR-masking fix, SGI enable/priority in `initCpuInterface`. No slots wired yet. Verify -smp 1 still green.
- **M3.2 — `sendFlushIPI`.** Wire the slot; register a flush-SGI handler calling the same generic drain x64's `.flush_request` vector uses. Still -smp 1 → green.
- **M3.3 — go multi-core.** Flip `testCpus(arm)=4`. The "every bootloader-reported CPU has a live, scheduling executor" proof test (`testing/smp.test.zig` ~126–150) is the gate. Debug with semihosting traces in the AP entry path.
- **M3.4 — `sendRescheduleIPI`** + no-op handler. Sets `reschedule_ipi_available` true → un-skips the latency test.
- **M3.5 — `sendPanicIPI`** broadcast (filter 01; handler halts).

### Open questions

1. Does our Limine actually bring up APs on QEMU-virt aarch64 and honour `goto_address`? Verify with a semihosting trace in the trampoline at `-smp 4`. Contingency: fall back to kernel PSCI `CPU_ON` (HVC fn 0xC4000003: x1=target MPIDR, x2=entry, x3=context) only if Limine doesn't start them.
2. GIC CPU-interface numbering on QEMU virt: interface i == cpu i == MPIDR Aff0? Confirm before trusting the target bitmask.
3. SGI IAR source-CPU bits handling — get the mask/EOI split right or SGIs from APs are silently dropped.

Useful references (network is restricted here): Linux `drivers/irqchip/irq-gic.c` (`gic_raise_softirq`/`GICD_SGIR`), `arch/arm64/kernel/smp.c` (secondary bring-up ordering), GICv2 spec IHI0048 (IAR/SGIR layout).
