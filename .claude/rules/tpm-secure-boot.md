---
paths:
  - "src/innigkeit/acpi/tables/TPM2*"
  - "src/innigkeit/capabilities/types/SecureVault*"
  - "docs/secure-boot.md"
---

# Boot & at-rest security

## Design decisions v3 (2026, "zero compromises" — supersedes/extends v2, do not regress)

User directive (verbatim intent): complete security, no compromises; aspire to
Apple Secure Enclave / FileVault-class protection plus hardware tokens. **Mind
session limits: offload mechanical, well-specified work to a weaker model
(Sonnet subagent) and have the lead verify it; keep subtle crypto/boot code with
the lead.** Honor repo craft (docs/DESIGN.md): illegal states unrepresentable,
fallible boundaries return errors, no physical register names in generic code,
numbered patches.

1. **Kernel verified boot — REQUIRED (was "accept the gap"; now closed).** Secure
   Boot currently verifies Limine (`BOOTX64.EFI`) but Limine loads the kernel
   *unverified*. Must close it: Limine has to verify the kernel too (kernel hash
   in `limine.conf`, or Limine's own signature check) so a tampered kernel does
   not even load. Every stage verifies the next (M-series model). No compromise.
2. **Enforcement when boot is untrusted = fail safe & quiet.** SB disabled / PCR
   mismatch → the data volume stays sealed & unavailable, the system still boots
   without it (no panic). **Full-disk encryption is user-toggleable (on/off);
   Secure Boot is MANDATORY and never user-disableable.** So a user setting
   controls whether the data volume is encrypted at all; SB is always enforced.
3. **Production vs dev key custody.** Production/release signing (PK/KEK/db +
   bootloader + kernel) happens in **GitHub Actions with a CI secret key + build
   attestation** (SLSA / GitHub artifact attestation). Dev (this cloud env)
   regenerates SB keys locally on a debug launch (`zig build secureboot -- keygen`).
   Dev keys never ship; production keys live only in CI secrets.
4. **Recovery = strongest available, FileVault-like.** Passphrase keyslot with a
   strong KDF (**Argon2id**) as the primary escape hatch — deliberately
   TPM-independent so a legit TPM clear / firmware update doesn't destroy data
   (accepted tradeoff for the recovery slot). **Also add YubiKey/FIDO2
   (hmac-secret) as an additional hardware keyslot.** Passphrase input path:
   userspace/offline recovery tool for now (no early-boot console yet).
5. **Anti-rollback of the on-disk sealed header:** do the TPM NV monotonic
   counter binding **if it turns out easy; otherwise defer + note** as a known
   narrow gap (an attacker restoring an old captured header after key rotation).
6. **OS measurement completeness — REQUIRED.** Measure **kernel image + initfs +
   config** into PCR 11 (today only the codesign root key is extended). Full
   binding, no compromise. (Production key custody from #3 covers the rest.)

### Research findings (2026, Fable) — sharpen the roadmap
- **Kernel verified boot is ~90% already done.** Limine's generated `limine.conf`
  already pins the kernel via `kernel_path: boot():/kernel#<blake2b512>`, and
  Limine **enforces** it — proven empirically: flip one byte in `/kernel` in the
  ESP → Limine refuses to boot (qemu hangs, no verdict). The remaining gap is
  `enroll-config`: bind the *config file's* BLAKE2B-512 into the signed
  `BOOTX64.EFI` (`limine enroll-config <efi> <hash>`), else an attacker just edits
  `limine.conf` to swap the kernel hash. The vendored `limine.c`
  (`zig-pkg/*/limine.c`) compiles standalone (`cc -std=c99 -I <pkgdir> limine.c`)
  and exposes `enroll-config`; `b2sum -l 512` computes the hash (128 lc hex). So
  [C] = add enroll-config to the secboot signing flow **before** sbsign, giving
  the full chain: SB → signed BOOTX64.EFI → enrolled config hash → verified
  limine.conf → kernel `#hash` → verified kernel. **Doable now.**
- **YubiKey/FIDO2 is BLOCKED: no USB stack.** No xhci/ehci/usb drivers exist;
  FIDO2 needs XHCI + USB enumeration + HID + CTAP2 — a large separate epic.
  Defer [E]'s hardware-token half; keep the Argon2id passphrase keyslot
  (`std.crypto.argon2` IS in the stdlib). Note this clearly in [E].

### Session snapshot (resume here)
> **[E1b] status corrected (2026).** An earlier session snapshot claimed patches
> 0050–0052 (multi-keyslot volume header + recovery CLI) were lost in a container
> restart. That was a false alarm: the work survived. Commit `854820f` did the
> real implementation, and the immediately-following `d7135e8 re-namespacing`
> commit renamed the files to the repo's PascalCase convention
> (`volume_header.zig`→`VolumeHeader.zig`, `passphrase_keyslot.zig`→
> `PassphraseKeyslot.zig`, `encrypted_volume.zig`→`EncryptedVolume.zig`) — this
> file's status notes just never caught up. Verified present and passing:
> `zig build test_native` 63/63 incl. `volume_header` (3), `recovery_flow` (7),
> `passphrase_keyslot` (3).

Green baselines (all reverified after the fix below): **x64 138** default /
**x64 155** `-Dtpm=true` (2 skip) / **arm 98** (13 skip, incl. the arm-AES
KAT) / `test_native` 63 (incl. volume_header + recovery_flow +
passphrase_keyslot) / `-Dsecboot=true` passes end-to-end (signed boots,
unsigned + tampered-config correctly rejected).
**`TPM2_StartAuthSession` rc=0x95 regression — FOUND AND FIXED (2026).**
Root cause: `drivers/tpm/tpm.zig`'s `startAuthSession` tagged its command
header `.sessions` (`TPM_ST_SESSIONS`) but never wrote the authorization-area
bytes that tag promises (unlike every other `.sessions`-tagged command in the
file, e.g. `createPrimary`) — the TPM correctly rejected the resulting
malformed structure with `TPM_RC_SIZE` (0x95 = format-1 base error 0x15).
`policyPcr`/`policyGetDigest`, which also reference a session handle
directly, correctly use `.no_sessions` — confirming session-establishing
commands don't get an auth wrapper. One-line fix: `tpm.zig:289`
`.sessions` → `.no_sessions`. Verified: all previously-failing PolicyPCR/
seal/unseal/multi-PCR-bind/SecureVault/encrypted-volume TPM tests now pass;
`-Dsecboot=true`'s full three-way boot comparison passes end-to-end.
**DONE:** SB-1..SB-5, decision-2 multi-PCR seal {0..7,11}, SB-2c log replay, SB-6a EFI table, SB-6d PCR-7 SecureBoot read, SB-6b/c full UEFI Secure Boot (own PK/KEK/db), [C] kernel verified boot, [D] CI signing+attestation, [E1] Argon2id keyslot core, [B] boot-mount + FDE toggle, **[E1b] multi-keyslot header + recovery CLI**, **`TPM2_StartAuthSession` fix**.
**OPEN (pick next):** (1) **[F]** SB-7 HMAC/param-encrypted TPM sessions + anti-rollback (last big security workstream); (2) **arm-AES** — file the upstream Zig/LLVM bug (fully root-caused, blocks arm at-rest); (3) **[E2]** YubiKey (blocked: no USB stack).

### Readjusted roadmap (no-compromise), tagged for delegation
- **[A] Expand PCR-11 measurement** (kernel image + initfs + config, fixed order).
  `DELEGATE→Sonnet`, verify with `zig build verify -Dtpm=true` (replay test only
  checks PCRs 0–7, so PCR-11 changes are safe; seal/unseal round-trips per boot).
- **[B] Enforcement gate + user FDE toggle — DONE (patch 0044).**
  `filesystem/encrypted_volume.mountAtBoot()` scans virtio-blk in stage4, mounts the
  first `INNIKVOL` volume via `open()`; the header IS the FDE toggle (plaintext
  disk = FDE off), SB stays mandatory. Fail safe & quiet: untrusted boot / no
  TPM / firmware-measured SB-disabled → key stays sealed, boot continues.
  `bootVolume()` exposes it. Tested x64 (default: plaintext disk unmounted;
  --tpm: 2nd disk provisioned + scan unseals) and arm (mountAtBoot safe).
  **⚠ arm-AES BLOCKER (pre-existing, exposed here):** the freestanding aarch64
  kernel's *software* AES miscompiles — self-consistent but non-standard
  (round-trips pass, IEEE-1619 KATs fail). Leading hypothesis:
  `code_model = .kernel` mis-addresses the AES rodata tables (x64 is fine). So
  **AES-XTS at-rest encryption is NOT trustworthy on aarch64** — do not enable
  FDE on arm until the KAT passes there. KAT skipped on freestanding-arm (loud
  comment in `crypto/xts.zig` + docs/secure-boot.md "arm at-rest status").
  **Investigation (2026, Fable) — narrowed substantially:**
  - Symptom: raw `AES-128(0,0)` on the arm kernel = `e39bd32dfc008faf6f9f972a76f9b80e`
    (expected `66e94bd4ef8a2c3b884cfa59ca342b2e`), and it is *self-inverse*
    (round-trips) → a consistent wrong permutation. So it's the **AES core**, not
    the XTS wrapper.
  - **Correct** in `qemu-aarch64` user-mode with the SAME cpu features
    (`-mcpu generic-neon-fp_armv8`), Debug AND ReleaseSafe → NOT cpu-features,
    NOT optimize level, NOT the AES source itself.
  - Ruled out on the kernel build: `side_channels_mitigations` (.full and .none
    both fail — so it's not table-vs-bitsliced), `code_model` (`.kernel` is
    x86-only; `.large` needs `-fno-pic` which conflicts with kernel PIE),
    `pie=false` (still fails, and the kernel still boots without PIE).
  - **CONCLUSION: it is a compiler codegen bug, not a kernel runtime bug.** The
    decisive `aes_diag` test read a 256-byte const rodata probe table back
    **perfectly (0/256 mismatches)** on the arm kernel while AES was still wrong
    — so rodata mapping/cache is fine; the AES *arithmetic* is miscompiled.
    Trigger is the **`aarch64-freestanding-none` target** specifically:
    `aarch64-linux-musl` with identical cpu/optimize is correct, and adding
    `-fsingle-threaded` in user-mode does NOT reproduce it. (Can't run a
    freestanding binary in `qemu-aarch64` user-mode to bisect further.)
  - **Fix directions (decide later):** (1) build a tiny `aarch64-freestanding`
    AES harness (or reuse the kernel) as a minimal repro → report/​fix upstream
    in Zig/LLVM; (2) vendor a register-only AES into the kernel — but it may hit
    the same freestanding codegen bug, so verify with the KAT before trusting it;
    (3) as a stopgap, run AES on arm via a path the bug misses (e.g. force a
    different optimize/attribute on the crypto TU). arm at-rest stays gated off
    until the KAT passes on the freestanding-arm kernel.
  - **Refined further (lost patches 0048/0049, findings preserved):** the
    miscompile is in the AES *round logic / key schedule*, not the tables — a
    diagnostic read `crypto.aes.soft.sbox_encrypt`/`sbox_decrypt` at their live
    kernel addresses and got the exact FIPS-197 bytes while `AES-128(0,0)` was
    still `e39bd32d...`. And it is robust to build knobs: `code_model=.large`
    **together with** `pie=false` (the standard high-half combo) builds + boots
    but AES is STILL wrong. So no code-model/PIE/optimize knob fixes it — it's a
    genuine LLVM AArch64 miscompile. A minimal harness (`repro.zig` + `linker.ld`
    at a flat/low address) is CORRECT, isolating the trigger to the high-half
    (`0xffffffff80000000`) freestanding link under the MMU. **Next: file at
    ziglang/zig (labels backend-llvm/arch-aarch64/miscompilation); the repro
    scratch package was in `/tmp` and is lost, but is trivially regenerated —
    see the `repro.zig` shape in the transcript, or dump `AES-128(0,0)` from a
    kernel test.**
  - **2026-07-13 follow-up (prompted by an external Zig-maintainer lead,
    `jedisct1`, on a related freestanding-aarch64 AES codegen report):**
    independently re-derived the identical `e39bd32dfc008faf6f9f972a76f9b80e`
    for the zero-key/zero-block FIPS-197 vector (byte-for-byte match with the
    finding above — good cross-session confirmation this is deterministic,
    not environment-dependent). Tried the maintainer's suggested
    `+strict-align` target feature (added to `build/Bundle.zig`'s aarch64
    `kernelTarget`, confirmed via `Target.Query.serializeCpu` that it lands in
    the actual resolved `-mcpu` string) — **does not fix it.** Also confirmed
    (matching a diagnostic question `jedisct1` asked) that it reproduces
    identically under `side_channels_mitigations = .none`, consistent with
    this doc's own earlier finding that it isn't mitigation-path-specific.
    `+strict-align` was kept in the target regardless, as independent,
    low-cost hardening against a *different* real hazard (unaligned-access
    UB on a no-MMU target) — but it is not the fix for the value-correctness
    bug. The KAT stays skipped. Still narrows toward "genuine LLVM AArch64
    backend bug, specifically triggered by the high-half link address" as
    the standing conclusion; filing upstream (see above) remains the next
    step if it hasn't happened yet.
- **[C] Kernel verified boot — DONE (patch 0040).** Limine `#hash` pins the
  kernel (enforced); the `--secboot` gate `enroll-config`s the limine.conf hash
  into BOOTX64.EFI before signing. Chain unbroken: firmware→signed BOOTX64.EFI→
  enrolled config hash→limine.conf→kernel #hash→kernel(+embedded initfs). Gate
  proves signed-boots / unsigned-rejected / tampered-config-rejected.
- **[D] Production signing + attestation — DONE.** `zig build secureboot -- sign` (`tools/secureboot`)
  is the single source of truth for the sign op (enroll-config + platform-dispatched signing);
  `zig build verify -Dsecboot=true` and `.github/workflows/release.yml` both call it.
  The release workflow (tag `v*`) builds `image_x64`, signs BOOTX64.EFI with the
  `db` key from repo secrets (`SECUREBOOT_DB_KEY`/`SECUREBOOT_DB_CERT`), emits a
  SLSA build-provenance attestation (`actions/attest-build-provenance@v2`), and
  attaches the signed image to the release. Dev uses throwaway keys via
  `secureboot-keygen.sh`; prod keys live only in CI secrets. (Follow-up: source
  the codesign keypair from a secret too — currently CI runs keygen.)
- **[E] Recovery keyslots.** [E1 crypto core DONE] `crypto/PassphraseKeyslot.zig`
  — Argon2id-derived wrapping key + XChaCha20-Poly1305 over the volume key
  (salt‖params as AEAD associated data); 132-byte slot; host-tested in
  `test_native` (round-trip, wrong-passphrase, tampered-AD). Runs in a
  userspace/offline recovery tool (needs allocator+Io), NOT early boot.
  **[E1b] DONE** (files renamed to PascalCase by the later `d7135e8
  re-namespacing` commit — spec below described the as-built shape):
  - `src/innigkeit/filesystem/VolumeHeader.zig` (std-only codec): plaintext sector-0
    header `magic[8]="INNIKVOL" ‖ version(u32=2) ‖ slot_count(u32) ‖ reserved[16]`
    then `slot_count × (type(u32) ‖ len(u32) ‖ payload[len])`, all little-endian.
    `SlotType = enum(u32){ empty=0, tpm_pcr=1, passphrase=2, hw_token=3, _ }`,
    `max_slots=8`, `header_start=32`. `pub fn parse(buf)!Header`, `pub fn
    write(buf,slots)!void`, `Header.find(type)?[]const u8`. Bounds-checks every
    slot. Host tests: round-trip 2 slots, bad magic/version/overflow, sector
    overflow. Registered in `filesystem/root.zig` + `build.zig` test_native.
  - `filesystem/EncryptedVolume.zig` refactored onto it: imports it as `vheader`;
    provision encodes the SealedObject into a `tpm_pcr` slot
    (`private_len(u32)‖public_len(u32)‖private‖public`) via
    `encodeTpmSlot`/`decodeTpmSlot` + `vheader.write/parse`; `open` finds the
    `tpm_pcr` slot; `mountAtBoot` checks `vheader.magic`. Preserves other slots.
    (`tpm_slot_max = 8 + @FieldType(SealedObject,"private").len +
    @FieldType(SealedObject,"public").len`.)
  - `src/innigkeit/recovery.test.zig` (rooted at src/innigkeit/ so it can import
    both `crypto/PassphraseKeyslot.zig` and `filesystem/VolumeHeader.zig`): builds a
    header with a tpm_pcr slot + Argon2id passphrase slot, parses cold, unwraps
    with the passphrase → exact key; wrong passphrase rejected; tpm slot
    preserved. Registered as a `recovery_flow` test_native entry.
  - `tools/volume_recovery/` host CLI (`main.zig` + `config.zig`): subcommands
    `info` / `add-passphrase <img> <key-hex> <pass>` / `recover <img> <pass>`.
    Reads/writes sector 0 in place with positioned I/O (`file.reader/writer(io,
    buf)`, `writer.seekTo(0)`); `io.random(buf)` for salt/nonce (NOT
    `std.crypto.random`); Argon2id params t=3/m=64MiB/lanes=1; preserves
    non-passphrase slots, replaces an existing passphrase slot. `config.zig`
    `addImport`s `VolumeHeader` + `PassphraseKeyslot` as modules. Registered in
    `tools/root.zig`. Note: `std.crypto.pwhash.argon2` (not `std.crypto.argon2`);
    `KdfError` is `std.crypto.pwhash.KdfError`.
  - Baselines: x64 138 / --tpm 155 / test_native 63 (verified passing).
  [E2] YubiKey/FIDO2 slot — BLOCKED on a USB stack (deferred). `LEAD`.
- **[F] SB-7 HMAC + parameter-encrypted TPM sessions** (anti-interposer). `LEAD`
  (crypto). Anti-rollback NV counter here if easy (#5).

## Design decisions (maximal-security v2 — do not regress)

**North star:** aspire to Apple M-series-class security architecture — a hardware
root of trust, a sealed key hierarchy, an attested/measured boot chain, and
defense in depth — and implement against **next-generation standards** (TPM 2.0
crypto-agile, UEFI Secure Boot, AES-XTS, HMAC-protected TPM sessions). Bias every
choice toward security over convenience. Honor the repo craft (docs/DESIGN.md):
make illegal states unrepresentable, fallible boundaries return errors, no
physical register names in generic code, deliver work as numbered patches.

Decisions from the SB interview (2026):
1. **SB-6 = full UEFI Secure Boot** (not just runtime posture): sign the kernel/
   bootloader (sbsign-style), enroll PK/KEK/db, use an SB-capable OVMF, AND read
   the `SecureBoot` state at runtime (via Limine's `EFISystemTable` → EFI runtime
   services) to gate sealed-secret release. Feasibility-check the enrollment path
   first (may hit env limits like the ACPI-log dead end did).
2. **Seal the disk key to firmware PCRs 0–7 AND OS PCR 11** (maximal binding), so
   bootloader/firmware tampering — not just OS-measured changes — breaks unseal.
   Requires PolicyPCR over a multi-PCR selection, and measuring more into PCR 11
   (kernel image, initfs, config), not just the codesign key.
3. **Recovery: passphrase keyslot** (LUKS-style second slot wrapping the volume
   key) so legitimate updates / TPM clear don't destroy data.
4. **TPM session hardening: HMAC + parameter-encrypted sessions.** Retrofit the
   sensitive command paths (Unseal, GetRandom-for-keys, Create sensitive, Seal)
   with HMAC-authenticated, parameter-encrypted sessions (salted/bound) to defeat
   a TPM bus interposer. This is a dedicated workstream ("SB-7 hardening") over
   SB-3/4/5 — currently those use empty-password `TPM_RS_PW` with no encryption.

## Current state

Status: SB-1 (CRB driver) **DONE**. SB-2 (measured boot, incl. SB-2c firmware TCG event-log replay) **DONE**. SB-3 (TPM-backed SecureVault) **DONE**. SB-4 (seal data to a PCR policy) **DONE**. SB-5 (AES-XTS encrypted block device + TPM-sealed volume key + on-disk header) **DONE** except wiring `open` into `stage4` for the real data volume (pairs with SB-6 provisioning). **Decision 2 (multi-PCR binding) DONE:** the disk key now seals to firmware/Secure-Boot PCRs 0–7 **and** OS PCR 11 (`tpm.sealToPcrs`/`unsealWithPcrs`, `tpm.policyPcrSet`, `drivers/tpm.seal_pcrs = {0..7,11}`; gated test proves extending PCR 7 breaks unseal). Next up: **SB-6** signing/enrollment (see feasibility below); then decision 3 (passphrase recovery keyslot) and "SB-7" decision 4 (HMAC/parameter-encrypted TPM sessions).

### SB-6 progress
- **SB-6a DONE** — `boot.efiSystemTable()`/`boot.firmwareType()` wired (Limine EFISystemTable + FirmwareType requests); `src/innigkeit/firmware/efi.zig` resolves + validates the EFI System Table and Runtime Services via the direct map (read-only; GetVariable ptr captured). Direct-map deref of EFI tables confirmed safe on x64 + arm. Test in the default suite.
- **SB-6d (SecureBoot read) DONE via the SAFE path** — `drivers/tpm/eventlog.secureBootEnabled()` reads the firmware's measured `SecureBoot` value from the PCR-7 EV_EFI_VARIABLE_DRIVER_CONFIG event (no live EFI runtime call, attested by PCR 7). Returns null on non-secboot firmware (current OVMF → test skips; verify.sh --tpm exempts that one skip). **Decision revisited:** the user picked the literal RT-services GetVariable, but scoping showed it needs identity-mapping firmware runtime code or SetVirtualAddressMap (real boot-destabilization risk) for a value we already get cryptographically + from the log. The event-log read is trust-equivalent and safe, so it landed; the literal GetVariable call remains a documented, separately-gated follow-up if ever wanted. **Enforcement/gating** (refuse sealed-secret release when SB disabled) is deferred until secboot boot works (SB-6c) — hard-gating now would brick the non-secboot test disk.
- **SB-6b/c DONE (own keys + signed boot, end-to-end verified).** `zig build secureboot -- keygen` generates our own PK/KEK/db (RSA-2048 self-signed; `keys/secureboot/`, gitignored). `zig build verify -Dsecboot=true` (`build/Verify.zig`) enrolls them into an OVMF VARS store with `virt-fw-vars` (`--no-microsoft`, so *only* our keys), signs Limine's `BOOTX64.EFI` in the image with `sbsign` (Linux) / `osslsigncode` (macOS) + our db key via `tools/secureboot` (mtools mcopy in/out of the ESP at sector 4096), and boots under `OVMF_CODE_4M.secboot.fd` + swtpm. Proven both ways: the **signed** image boots (147 tests pass, SecureBoot test runs non-skipped and, with `-Dexpect_secure_boot=true`, asserts SB *enabled*); the **unsigned** image is **rejected** by the firmware (no kernel output, no verdict). Tooling: `sbsigntool`+`efitools` (apt), `virt-fw-vars` (pip `virt-firmware`; needs `pip install --force-reinstall cffi` to fix `_cffi_backend`), `mtools`+`gdisk` (apt). Image ESP = GPT partition 2 @ sector 4096; BIOS-boot = partition 1. **NOTE:** the full `--secboot` gate (baseline suite + build + 2 TCG boots, incl. a 60 s unsigned-reject wait) is long; each step was validated individually here. `-Dexpect_secure_boot` build option lives in `build/Options.zig` → `kernel_options.expect_secure_boot`.
- **Enforcement gate — DONE, verified 2026-07-13 (this note had gone stale; the code landed earlier and was never marked done here).** `filesystem/EncryptedVolume.zig`'s `mountAtBoot()` already wires the "refuse to release the disk key when SB is disabled" gate: it calls `secureBootEnabled()` and skips the candidate volume (key stays sealed) on a confirmed `false`, while a `null` (non-secboot test firmware, no event log) falls through unaffected — so the plain non-secboot test path is untouched exactly as this note originally required. Real enforcement is double-layered: even without this explicit check, PCR 7 is already in `seal_pcrs`, so a Secure-Boot-disabled boot changes PCR 7 and `unsealWithPcrs` fails cryptographically regardless — this check just gives a clean log message and skips a wasted TPM round-trip.
- **Kernel supply-chain signature — DONE (2026-07-13).** `tools/codesign` gained `sign-artifact`/`verify-artifact` — a distinct 104-byte format (`magic ‖ blake3_hash ‖ ed25519_sig`, no manifest/entitlements, since those are app-spawn concepts the kernel doesn't have) from the existing 144-byte app `SigBlob`. `build/Kernel.zig`'s `buildKernel` runs it over the release kernel binary and installs `kernel.codesig` next to `kernel` in `zig-out/<arch>/`. Deliberately **not** wired into the boot-time verification chain — that's already unbroken (Limine's `#hash` pin + the enrolled `limine.conf` hash + TPM measured boot, see decision 1/[C] above) — this is purely supply-chain provenance for distributed release artifacts, matching the project owner's own framing of the ask. Verified: `zig build image_x64` → `codesign verify-artifact zig-out/x64/kernel zig-out/x64/kernel.codesig` passes; a single flipped byte in the kernel binary is rejected. `zig build verify -Darm=true` unaffected (x64 157/157, arm 111+14 skipped). Still open: decision 3 (passphrase recovery keyslot) + "SB-7" decision 4 (HMAC/param-encrypted TPM sessions).

### SB-6 feasibility (checked 2026, this cloud env — NOT a dead end)
- **SB-capable OVMF present**: `/usr/share/OVMF/OVMF_CODE_4M.secboot.fd` + pre-enrolled VARS (`OVMF_VARS_4M.ms.fd` = MS keys; `OVMF_VARS_4M.snakeoil.fd` = RH snakeoil PK/KEK/db). The snakeoil **private key** is on disk too: `/usr/share/OVMF/PkKek-1-snakeoil.{key,pem}` — so we can sign our own EFI binaries against a db the firmware already trusts, no key-enrollment step required.
- **Signing/enrollment tooling**: `sbsign`/`sbverify`/`cert-to-efi-sig-list`/`efi-updatevar` (pkgs `sbsigntool`, `efitools`) are **apt-installable** (were missing; installed this session). `openssl` present.
- **Firmware in the build** currently comes from the `edk2` zig-package dep (`build/QEMU.zig` → `x64/{code,vars}.fd`, plain non-secboot OVMF + empty vars). A secboot QEMU profile must point pflash0 at `OVMF_CODE_4M.secboot.fd` and pflash1 at an enrolled VARS copy (writable, so copy it to a build/cache path first).
- **Runtime `SecureBoot` read HAZARD**: calling EFI Runtime Services (`GetVariable`) post-ExitBootServices from the kernel's *own* page tables is risky — the direct map is NX/W^X, so the EFI runtime *code* regions must be mapped executable (analogous to the CRB-MMIO and event-log-reclaim gotchas). `boot.EFISystemTable`/`boot.FirmwareType` request types already exist in `src/boot/limine/` but are **unexported/unwired**. Prefer to *attest* Secure Boot via PCR 7 (already replayed by SB-2c and now sealed-to via decision 2) — that binds the disk key to the SB policy cryptographically without RT-services calls; the runtime boolean read is belt-and-suspenders, do it only after mapping RT code executable.

**What exists:**
- TPM detection: `acpi/tables/TPM2.zig` parses ACPI TPM2 table, yields presence + control-area base address.
- **TPM CRB driver (SB-1): `drivers/tpm/crb.zig` (transport) + `drivers/tpm/tpm.zig` (commands).** Maps the control area as uncached device MMIO via `memory.heap.allocateSpecial` (*not* the direct map — it is device memory, which page-faults there), drives the PTP locality/cmdReady/start handshakes with wallclock-bounded polling, exposes `transmit(cmd) -> resp`. Command layer: `TPM2_GetRandom` + `TPM2_GetCapability`. stage4 probes at boot (`drivers.tpm.init`). Tested via the opt-in gate `zig build verify -Dtpm=true` (build-managed swtpm + QEMU `tpm-crb`, see `build/TpmHarness.zig`). CRB buffers are assumed to lie in the one mapped device page (true for QEMU); relocated buffers on real hardware are future work.
- `SecureVault` (SB-3 DONE): per-vault 256-bit wrapping key, XChaCha20-Poly1305 seal/unseal. `create()` probes `drivers.tpm.device()`; with a TPM present the key is `SHA256(software_key ‖ TPM2_GetRandom)` and `tpm_backed = true`, else software-only.
- PCR-sealing (SB-4 DONE): `tpm.sealToPcr(parent, pcr, data)` / `tpm.unsealWithPcr(...)` seal data to a `PolicyPCR` digest so it unseals only when the bound PCR matches. Built on `createPrimary` (ECC P-256 storage parent), `startAuthSession`/`policyPcr`/`policyGetDigest`, `create`/`load`/`unseal`.
- Disk encryption (SB-5 DONE): `crypto/xts.zig` (AES-XTS), `crypto/encrypted_block.zig` (`EncryptedBlockDevice`, generic backing, host-tested), `filesystem/encrypted_volume.zig` (`provision`/`open` — volume key from TPM RNG, sealed to the boot PCR, persisted in a plaintext sector-0 header (magic `INNIKVOL`), keys a `VirtioBacking` device; data in sectors `data_start_lba`..). Plaintext key zeroed after use. **Remaining:** call `open` on the real data volume in `stage4` + route the filesystem through it (pairs with SB-6 provisioning — first boot must `provision`).
- `efi_var_get/set` (syscalls 36/37): stubs returning `Unsupported`.

**Staging order (docs/secure-boot.md):**
- SB-1: TPM CRB driver + `transmit()`. QEMU: `-tpmdev emulator,id=tpm0 -device tpm-crb,tpmdev=tpm0`. Test: `TPM2_GetCapability` + `TPM2_GetRandom`. **Foundation — everything builds on this.**
- SB-2: measured boot. **DONE:** `pcrExtend`/`pcrRead` (SHA-256 bank, empty-password TPM_RS_PW auth) in `drivers/tpm/tpm.zig`; `drivers/tpm/root.zig` `measure(label, data)` extends the codesign root key into PCR 11 at boot. **SB-2c (consume the firmware TCG event log): UNBLOCKED.** The right path is Limine's `TPMEventLog` request (`boot.tpmEventLog()`), which captures the log via `EFI_TCG2_PROTOCOL.GetEventLog` before ExitBootServices and hands us an HHDM buffer — in QEMU+OVMF+swtpm it delivers a 7261-byte crypto-agile (`tcg_2`) log. Do NOT use the ACPI TPM2 LASA/LAML path: this firmware's table (76 bytes) doesn't expose a usable pointer (the `start_method_specific_parameters` area is method-dependent, so fixed struct offsets mis-read it and tail-byte reads page-fault). `drivers/tpm/eventlog.zig` locates the log; full parse (`TCG_PCR_EVENT2` records) + replaying digests to reproduce the firmware PCRs is in progress.
- SB-3: TPM-backed `SecureVault` (close the TODO)
- SB-4: sealed disk volume key (`Create`/`Load`/`PolicyPCR`/`Unseal`)
- SB-5: AES-XTS `EncryptedBlockDevice` between virtio-blk and filesystem
- SB-6: Secure Boot chain (build/provisioning, EFI var read at runtime)

**Interface to implement:** CRB first (QEMU default). `start_method` in the ACPI TPM2 table identifies CRB vs TIS. Synchronous `transmit(command_bytes) -> response_bytes`. Big-endian TPM 2.0 command structures (header: tag ‖ commandSize ‖ commandCode). Reference: Linux `drivers/char/tpm/tpm_crb.c`.
