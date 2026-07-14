# Innigkeit

Capability-based microkernel in Zig 0.16.0. Targets x86-64 (primary), AArch64 (secondary), RISC-V64. Both x86-64 and AArch64 boot to the test suite; AArch64 is single-core (SMP is M3).

Current focus: boot/at-rest security (UEFI Secure Boot + TPM 2.0 + disk encryption) and test depth (user-process integration harness, `std`/`std.Io` stubs). Display server epic is stashed.

@docs/roadmap.md: read this first after a context reset.

## Working conventions

Apply `.claude/skills/karpathy-guidelines` by default on every change, not just when explicitly invoked: think before coding (state assumptions, surface tradeoffs, ask when genuinely unclear); simplicity first (minimum code that solves the problem, no speculative flexibility); surgical changes (touch only what the request requires, match existing style, don't drive-by refactor); goal-driven execution (define verifiable success criteria up front, loop until they pass). These are default behavior for this repo, not a checklist to run once.

@docs/DESIGN.md is binding for style, not just a reference to consult when stuck: Part 1's ideology (make illegal states unrepresentable, misusable APIs impossible to misuse, assert the post-condition you just established), Part 2's formatting/micro-style rules, Part 5's security > simplicity > efficiency judgment ordering (a bias, not a formula: flag genuinely hard calls rather than resolving them silently), Part 6's voice/tone split (playful in banners/logs, precise wherever a future contributor relies on it), and Part 7's efficiency-conscious style all apply to new code and review the same way karpathy-guidelines does.

**Never `git push` or open a pull request in this repo unless the project owner explicitly asks for it in that specific instance.** Commit locally and deliver patches instead (see session convention below); a prior push/PR does not imply standing permission for the next one.

## Setup

On Claude Code on the web the toolchain is provisioned end-to-end: Zig 0.16.0, a matching ZLS, host QEMU 8.2 for **both** arches + AAVMF firmware, the Zig package cache, the codesign keypair, and the Rust target, and `zig`/`zls` land on `PATH`.

**Reproducible across fresh containers: use the environment _Setup script_, not (only) the SessionStart hook.** A fresh cloud container starts *untrusted*, and everything in the repo: SessionStart hooks **and** project-scope plugins under `.claude/skills`, is gated behind workspace trust, so the in-repo hook does not provision and the `zig-lsp` plugin does not load until someone accepts the trust dialog. The cloud environment's **Setup script** and **environment variables** run *outside* the trust gate (and the Setup script is cached in the filesystem snapshot). Point the environment's Setup-script field at:

```sh
bash <repo-clone-path>/scripts/cloud-setup.sh    # e.g. /home/user/innigkeit
```

`scripts/cloud-setup.sh` runs the provisioning (via the hook's logic), installs the `zig-lsp` plugin at **user** scope (`~/.claude/skills/zig-lsp`, which is *not* trust-gated) so the native LSP tools are live every session with no trust dialog and no `/reload-plugins`, and writes the toolchain `PATH` to `/etc/profile.d`. Idempotent. (Alternatively, accept the workspace trust dialog once: the in-repo hook + plugin then load on every future session with no env config.)

**Verify provisioning ran** at the start of a session (`zig version`, `command -v qemu-system-aarch64`, `ls keys/codesign_private.key`); if any are missing, run `.claude/hooks/session-start.sh` by hand once: idempotent, gated behind a `.tools/.cloud-bootstrap-done` sentinel. If a shell lacks the tools on `PATH`, prefix with `export PATH="$PWD/.tools/zig-0.16.0:$PWD/.tools/zls:$PATH"`.

### Code intelligence (ZLS)

ZLS 0.16.0 is provisioned on `PATH` and at `/usr/local/bin/zls`; ZLS user settings live in `~/.config/zls/zls.json`. The in-repo `zig-lsp` plugin (`.claude/skills/zig-lsp/.lsp.json`, also catalogued in `.claude-plugin/marketplace.json`) wires ZLS into the agent's native **`LSP` tool** (`goToDefinition`, `findReferences`, `hover`, `documentSymbol`, `workspaceSymbol`, `goToImplementation`, call hierarchy). Once the plugin is loaded (see Setup: user-scope via `cloud-setup.sh`, or project-scope after trusting + `/reload-plugins`), prefer the `LSP` tool over `rg` for "where is this defined / who calls this".

QEMU 8.2+ installed separately (`brew install qemu` / `apt-get install qemu-system-x86 qemu-system-arm qemu-efi-aarch64`: the last two give aarch64 QEMU + AAVMF). Rust apps need `rustup target add x86_64-unknown-none`. Two more fresh-clone prerequisites bite before the first build: neither `keys/codesign_private.key` nor `keys/codesign_public.key` is committed (both gitignored). Run `zig build codesign -- keygen` once to (re)generate both (the setup script does this automatically); and Zig's package fetcher cannot traverse a CONNECT proxy (cloud sessions fail with `HttpConnectionClosing`, empty global cache), so pre-populate it by `curl`-ing each `build.zig.zon` dependency (release URL, or `codeload.github.com/<owner>/<repo>/tar.gz/<sha>` for `git+https` deps) and `zig fetch <local-tarball>`. The printed hash must match the `.zon`. The web hook automates all of this.

## Build

| Command | Effect |
| --- | --- |
| `zig build run_x64` | boot in QEMU (x86-64) |
| `zig build run_arm` | boot in QEMU (AArch64) |
| `zig build test_x64` | test suite in QEMU; exit 1 = all passed |
| `zig build test_arm` | arm suite (see Testing section) |
| `zig build image_test_arm` | build arm test image without booting |
| `zig build codesign -- keygen` | generate `keys/codesign_{public,private}.key` |
| `zig build codesign -- sign <elf> <manifest.toml> <out.codesig>` | sign a binary |
| `zig build codesign -- verify <elf> <sig.codesig>` | verify a signature |

Release: append `-Doptimize=ReleaseSafe` (or `ReleaseFast`, `ReleaseSmall`).

Debugging: `-Ddebug=true` exposes a QEMU GDB stub on `localhost:1234` and starts frozen (`-S`) until a debugger attaches (also disables acceleration/KASLR). Checked-in `.gdbinit`/`.lldbinit` point at `zig-out/x64/kernel`; `gdb -x .gdbinit` or add `add-auto-load-safe-path` to your own `~/.gdbinit` first (GDB's auto-load safety feature won't source a project-local file otherwise).

### Verification gate

```sh
zig build verify                  # check + host tests + x64 suite (-smp 4)
zig build verify -Darm=true       # also the arm suite
zig build verify -Dcpus=1         # single-core run (any of the above)
zig build verify -Dtpm=true       # also the opt-in TPM suite (build-managed swtpm + QEMU tpm-crb)
zig build verify -Dsecboot=true   # also the UEFI Secure Boot suite (own PK/KEK/db, signed boot)
zig build check                   # compile check only
```

`zig build test_x64`/`test_arm`/`run_x64`/`run_arm` are equally safe to run directly now (`build/QEMU.zig` picks host QEMU over any bundled copy and prefers host AAVMF firmware for arm; see "QEMU gotcha" below). Baseline: x64 148/148, arm 104 (+14 skipped), host `test_native` 66 (incl. `wm_core` 29 + AES-XTS/encrypted-block + volume_header/passphrase_keyslot/recovery_flow, and two fuzz tests via Zig 0.16's built-in `std.testing.fuzz`: `VolumeHeader.parse`'s and `tcp/Segment.parse()`'s bounds-safety properties; run the real coverage-guided fuzzer with `zig build test_native --fuzz`). Networking (and hence `tcp/Segment`'s tests) is x64-only today: arm's build doesn't reach `network/` at all yet, a pre-existing gap unrelated to fuzzing. x64/arm include the SB-6a EFI System Table test and the spawn/wait integration test (arm skips the latter, see `.claude/rules/arm.md` and `docs/test-harness-plan.md`). The TPM suite (`-Dtpm=true`, opt-in) attaches a build-managed `swtpm` + QEMU `tpm-crb` device (`build/TpmHarness.zig`): GetCapability, GetRandom, PCR extend/read, CreatePrimary, PolicyPCR, Create/Load/Unseal, sealToPcr round-trip + unseal-fails-after-PCR-change, multi-PCR bind {0-7,11}, TPM-backed SecureVault, sealed-volume-key→AES-XTS, on-disk-header provision/open, firmware TCG event-log replay (reproduces PCRs 0-7), and the PCR-7 SecureBoot read (skips on non-secboot firmware). Baseline with `-Dtpm=true`: x64 155 passed (2 skipped: the PCR-7 SecureBoot read and the encrypted-volume boot-scan mount, both gated on secboot-capable firmware, absent under plain `-Dtpm=true`). The firmware measurement log is consumed via Limine's `TPMEventLog` request (`boot.tpmEventLog`), not the ACPI TPM2 LASA/LAML fields (which this firmware doesn't populate). The TPM driver lives in `drivers/tpm/`; disk encryption in `crypto/{xts,encrypted_block}.zig` + `filesystem/encrypted_volume.zig`; UEFI access in `firmware/efi.zig`. TPM tests skip when no TPM is present, so the default suite is unaffected.

`zig build check` uses `-fno-emit-bin` so inline assembly is NOT validated. Always run a real kernel build after touching arch `asm`. `zig build build_all` (real linked builds for every arch incl. riscv, no QEMU) closes that gap; see @docs/verification-and-ci.md for the full build-step hierarchy and how CI/release wire into it.

### QEMU gotcha

Use host distro QEMU 8.2 for **both** arches (`/usr/bin/qemu-system-x86_64` + `/usr/bin/qemu-system-aarch64`; arm also needs host AAVMF at `/usr/share/AAVMF/`). `build/Platform.zig` picks host QEMU over any bundled copy (`.tools/qemu/bin/`, built from https://download.qemu.org/ as a last-resort fallback) and prefers host AAVMF firmware for arm over the vendored `edk2` package (which wedges in SEC on real QEMU) and this is now correct build-graph behavior, not a bash override, so `zig build test_x64`/`test_arm`/`run_x64`/`run_arm` are safe to invoke directly. If host QEMU is ever too old, build 11.0.0 from https://download.qemu.org/ (recipe in `docs/arm-port.md`).

## Layout

```
src/innigkeit/        kernel core
  acpi/               ACPI table parsing, TPM detection
  capabilities/       capability table, object types, rights
  drivers/            virtio-blk/network/gpu, PS/2, PCI
  filesystem/                 initfs (ustar), simple_fs, ext4, VFS
  init/               boot stages (stage1–stage4)
  memory/                UVM address spaces, PMM, slab heap
  network/                Ethernet/ARP/ICMP/UDP/TCP
  sync/               futex, mutex, RwLock, spinlocks, Parker
  task/               EEVDF scheduler, Task struct
  user/               Process, Thread, syscall dispatch
    codesign/         Manifest, SigBlob, Verify
    elf/              ELF parser
    handlers/         per-syscall fn(Context) Error.Syscall!usize
src/architecture/     x64/, arm/, riscv/
library/innigkeit/    userspace lib (syscall wrappers, entry, allocator)
apps/                 sample apps; each has main.zig + manifest.toml
keys/                 codesign keypair generated by `keygen`, gitignored (not committed)
```

`user/syscalls.zig` is a declarative table: one row per syscall (selector + handler + entitlement gate), comptime jump-table dispatch. See @docs/syscall-abi.md.

## Security model

Every kernel resource is a typed capability handle. Rights (`read`, `write`, `grant`, `revoke`) are monotonically decreasing: a copy can only restrict, never add. 256 slots per process. SMEP/SMAP enforced on x86-64.

Each process has an `Entitlements` packed `u64` (set from the verified `.codesig` at spawn) that gates protected syscalls before any handler runs. Only `spawn = true` by default.

Debug builds skip all enforcement (`config.zig`: `enforce_code_signing` and `enforce_entitlements` are both `builtin.mode != .Debug`).

### Code signing

Every initfs app has a `.codesig` sidecar (144 bytes): Blake3 ELF hash + packed entitlements, Ed25519-signed. The kernel embeds `keys/codesign_public.key` at compile time. `spawn` calls `codesign.verify()` before ELF load.

### Adding an app

1. `apps/<name>/main.zig` + `apps/<name>/manifest.toml`
2. Register in `apps/root.zig`
3. `zig build`: codesign runs automatically

Manifest entitlements are booleans; omit a key to take the default (false, except `spawn = true`).

## Key invariants

- **User buffer validation**: all kernel/user transfers go through `user/validate.zig` (`copyFromUser`/`copyToUser`, `readUser`/`writeUser`, or `userSlice` + `UserAccess`). Never dereference a user pointer outside these helpers. Never hold a `UserAccess` window across a blocking call.
- **Rights monotonicity**: `CapabilityTable.copyLocked` rejects any `new_rights` not a strict subset of the source.
- **Generation counters**: revocation increments an atomic counter; all existing slots fail `getAndRefLocked` afterward.
- **W^X**: `LoadableRegion` rejects writable+executable segments; `mmap` rejects `write|exec`.
- **Slab reuse**: the constructor runs once per slot. Re-initialise all mutable state in the caller of `cache.allocate()`.
- **No physical register names in generic code**: cross the arch boundary through `architecture.Functions` slots (`setReturnValue`, `setInstructionPointer`, etc). Writing `rax` directly was a latent aarch64 bug.
- **SecureVault keys**: zeroed on `unref`, never cross the kernel/user boundary.

## IPC

Synchronous: `Endpoint` (send / recv / call / reply). Async: `Notify` (signal / wait). Message: 8-byte tag + 4×u64 payload + 4 capability handles.

## Scheduler

EEVDF, same algorithm as Linux 6.6+. 5 ms interrupt period. Real-time class supported. Cross-executor placement via `Scheduler.queueTaskOnRemote` + idle-flag IPI handshake (x86-64 vector 253; 5 ms tick remains the backstop on arm/riscv). Work stealing uses `tryLock` on the victim; RT and pinned tasks are never stolen. No path ever holds two scheduler locks.

## Testing

148 kernel-side tests: scheduling, memory, IPC, capabilities, networking, codesign, spawn, SMP, safe user-access fault recovery, boot/at-rest security, user-process integration (spawn + observe exit status). Host tests (`zig build test_native`) cover pure-logic units like TCP parsing, `wm_core`, the volume-header/passphrase-keyslot/recovery-flow codecs, and (as of the next-epoch test-expansion pass) two fuzz tests.

**AArch64**: judged by the serial verdict (`ALL N TEST(S) PASSED`), via `build/VerdictStep.zig`: a real build-graph dependency of `test_arm`, not a manual grep. Use `zig build verify -Darm=true` (or `zig build test_arm` directly). Baseline: 104 passed, 14 skipped (x64-only, SMP/M3, safe-access fault tests, and the integration test; arm panics on runtime process spawn today, see `.claude/rules/arm.md` and `docs/test-harness-plan.md`). Firmware is host AAVMF (`/usr/share/AAVMF`), preferred automatically by `build/Platform.zig`; the vendored EDK2 build wedges in SEC.

SMP stress tests (`testing/smp.test.zig`): executor bring-up proof (migration-pinned workers so stealing can't mask a dead AP), spinlock/mutex contention, cross-executor WaitQueue ring, Parker ping-pong, blk reads, IPI wake-latency, idle stealing. Every wait is watchdog-bounded and a deadlock fails the suite.
