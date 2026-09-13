# Pi 5 hardware bring-up checklist (PM1)

Concrete companion to `docs/rpi5-port-plan.md` §7 ("hardware and tooling this
needs that a cloud sandbox can't provide"). That section says *what* is
needed in the abstract; this doc says exactly what to buy/prepare, exactly
what commands to run, and exactly what to hand back so PM1 (boot to the
existing test suite over serial, on real Cortex-A76 silicon) can actually
close. Nothing below has been exercised on real hardware — it's assembled
from the plan's own research plus this project's existing image-build
pipeline, and the first real attempt will surface whatever this checklist
gets wrong.

## What you need

- **A Raspberry Pi 5 board** (any RAM size). Note the exact revision if you
  can (`BCM2712C1` vs the current `D0` — check the sticker on the board, or
  the packaging) — the plan flags a firmware quirk that differs between
  them (§3).
- **A microSD card**, 8 GB+, and a way to write it from your dev machine
  (built-in reader or a USB adapter).
- **A 3.3V USB-to-serial (UART TTL) adapter/cable** — this is not the same
  as USB from the Pi's own USB ports (those are dead until RP1 works). You
  need three wires (TX, RX, GND) into the Pi 5's dedicated 3-pin JST-SH
  debug connector on the board (not the 40-pin GPIO header — a different,
  always-on debug UART baked directly into the SoC). If your adapter doesn't
  already have a JST-SH pigtail, a bare 3-pin-to-jumper-wire cable works
  fine as long as TX/RX/GND land correctly (cross TX↔RX between the adapter
  and the board, tie GND to GND).
- **A serial terminal** on your dev machine (`minicom`, `screen`, `picocom`,
  PuTTY, etc.) at **115200 8N1** — the plan's sources report this as the
  standard rate for this debug console; if you get garbled output, 921600 is
  the other rate worth trying before assuming something's actually broken.
- Normal Pi power supply, nothing special.

You do **not** need an NVMe drive, a USB drive, or Ethernet for this stage —
all of that lives behind RP1 (§1/§2 of the plan), which isn't wired up yet.
Everything for PM1 happens on the one microSD card.

## Step 1 — Firmware

Download the latest release from **`NumberOneGit/rpi5-uefi`**
(https://github.com/NumberOneGit/rpi5-uefi) — not the archived
`worproject/rpi5-uefi` original; this fork has the D0-board fix. Format the
microSD card FAT32, and follow that repo's own install instructions (extract
the release's files to the card's root, alongside `config.txt`). Boot the
Pi with just this card and the serial adapter connected; you should see the
firmware's own boot log on the serial terminal. **This alone is worth
confirming before going any further** — if you don't get firmware output at
all, the wiring or baud rate is wrong, not Innigkeit.

## Step 2 — Pull real ACPI table data (do this before attempting Innigkeit's own boot)

This is the single most valuable thing to get me before spending a boot
cycle on Innigkeit itself: it directly resolves the plan's flagged open
question (§1's `[F]`) about which GIC-400 address is real, and whether the
firmware's SPCR/DBG2 tables correctly describe the debug UART at all.

From the firmware's UEFI Shell (the boot manager should offer a shell
option, or drop you into one automatically if it finds nothing else to
boot):

- If the shell has `acpiview` or similar built in, dump the MADT, SPCR, and
  DBG2 tables and capture the output over serial (redirect to a file on the
  FAT32 card if the shell supports it, e.g. `acpiview -d -s madt > madt.txt`
  — exact syntax depends on what this firmware's shell actually ships; if
  `acpiview` isn't present, note that and we'll find another way).
- If no ACPI dump tool is available in the shell, even a raw memory dump of
  the tables (UEFI configuration table pointers → `EFI_ACPI_20_TABLE_GUID`
  → RSDP → XSDT → the individual table addresses) captured via `dmem` is
  usable — just get me *something* with the raw bytes, however you can.
- Also worth trying: switch the firmware to **Device Tree mode** (per the
  plan, this mode reportedly has better hardware support than ACPI mode)
  and grab whatever DTB dump or `devicetree` shell command output it offers,
  purely as a cross-check against the ACPI data — Innigkeit can't consume a
  DTB directly today, but a second independent source for the real GIC
  address is worth having if it's easy to grab.

Send me whatever you get from this step, plus the exact firmware version/
release tag you downloaded. I'll use it to correct `arm/init.zig`'s MADT
parsing and confirm (or fix) the fallback addresses in `arm/gic.zig` before
you spend a boot cycle on Innigkeit itself.

## Step 3 — Build and place Innigkeit's own boot files

On a machine with this repo and the Zig 0.16.0 toolchain (see `CLAUDE.md`
Setup):

```sh
zig build image_arm
```

This produces `zig-out/arm/innigkeit_arm.hdd` — a raw disk image with a
single FAT32 ESP holding exactly three files:

- `/limine.conf`
- `/EFI/BOOT/BOOTAA64.EFI`
- `/kernel`

(Confirmed from `build/ImageManifestStep.zig` — arm has no BIOS-boot
partition or separate initfs file; the initfs is embedded in the kernel
binary.)

**Don't `dd` the whole `.hdd` over the SD card** — that would overwrite the
FAT32 partition the rpi5-uefi firmware itself needs to boot from. Instead,
mount the image and copy just those three files onto the *same* FAT32
partition the firmware already lives on, alongside it:

```sh
# mount the generated image (Linux; adjust for your OS)
sudo losetup -fP zig-out/arm/innigkeit_arm.hdd
lsblk   # find the loop device, e.g. /dev/loop0p1 (the single FAT32 partition)
sudo mount /dev/loop0p1 /mnt/innigkeit-image

# copy onto the SD card's existing FAT32 partition (already mounted, e.g. /mnt/sdcard)
sudo cp /mnt/innigkeit-image/limine.conf /mnt/sdcard/
sudo mkdir -p /mnt/sdcard/EFI/BOOT
sudo cp /mnt/innigkeit-image/EFI/BOOT/BOOTAA64.EFI /mnt/sdcard/EFI/BOOT/
sudo cp /mnt/innigkeit-image/kernel /mnt/sdcard/

sudo umount /mnt/innigkeit-image
sudo losetup -d /dev/loop0
```

If the firmware's own files already include an `/EFI/BOOT/BOOTAA64.EFI`
(some UEFI firmware installs do), **don't overwrite it** — rename
Innigkeit's copy to something else (e.g. `/EFI/BOOT/INNIGKT.EFI`) and use
the firmware's boot manager or shell to select it explicitly instead of
relying on the default boot path. Check what's already on the card before
copying.

## Step 4 — Boot and capture the log

Boot the Pi with this card, serial terminal already attached and logging
(`minicom -C bootlog.txt ...`, `screen -L ...`, or your terminal's own
capture feature) from power-on, so nothing before the failure/success point
is lost. Either:

- You see `ALL N TEST(S) PASSED` (or some subset, since storage/network
  tests will legitimately skip — no RP1 driver yet) → PM1 is done, huge
  milestone, send me the log so we can confirm the skip count matches
  expectations and start on PM2 (SMP).
- It hangs, panics, or resets → send me the **entire** captured log from
  power-on, not just the tail. A silent hang with no output at all most
  likely means the GIC address discovery (or its QEMU-`virt` fallback) is
  wrong for real hardware and something faulted before the console even
  came up — which is exactly why Step 2's ACPI dump matters so much: with
  it in hand beforehand, this failure mode should be preventable rather
  than something we debug blind after the fact.

## What to send back, in order of usefulness

1. **Step 2's ACPI table dump** (MADT/SPCR/DBG2, however captured) + the
   firmware release version — ideally before attempting Step 3/4 at all.
2. Board revision (C1 vs D0) and RAM size.
3. The full serial capture from Step 4, whatever the outcome.
4. Anything unexpected along the way (firmware behaved differently than
   this doc assumed, a command didn't exist, wiring didn't work as
   described) — this doc is a first draft with zero hardware validation
   behind it; corrections are expected and useful in their own right.
