# Boot & at-rest security — Secure Boot + TPM 2.0 + disk encryption

Extends Innigkeit's "hostile userspace can only crash itself" security downward to power-on and at-rest data: a verified boot chain (UEFI Secure Boot), attestable measured boot (TPM 2.0 PCRs), and an encrypted data volume whose key is released only to a trusted boot state. Owner doc for roadmap step 3.

**Security posture (v2, 2026):** maximal security — aspiring to Apple M-series-class architecture (hardware root of trust, sealed key hierarchy, measured/attested boot, defense in depth) built on next-generation standards. Binding decisions (full UEFI SB, seal to firmware PCRs 0–7 + OS PCR 11, passphrase recovery keyslot, HMAC/parameter-encrypted TPM sessions) are recorded in `.claude/rules/tpm-secure-boot.md` — treat them as non-negotiable requirements, not defaults.

---

## Current state

- **TPM detection** — `src/innigkeit/acpi/tables/TPM2.zig` parses the ACPI TPM2 table and yields the device presence + control-area base address.
- **TPM CRB driver (SB-1, DONE)** — `src/innigkeit/drivers/tpm/{crb,tpm}.zig`. CRB transport + `TPM2_GetRandom`/`TPM2_GetCapability`. See SB-1 below.
- **Measured boot (SB-2, DONE)** — `pcrExtend`/`pcrRead` + PCR-11 measurement of the codesign root key at boot; SB-2c consumes the Limine TCG event log and replays it to reproduce firmware PCRs 0–7. See SB-2 below.
- **TPM-backed `SecureVault` (SB-3, DONE)** — wrapping key rooted in the TPM hardware RNG; `tpm_backed` is real. See SB-3 below.
- **PCR sealing (SB-4, DONE)** — `sealToPcr`/`unsealWithPcr` bind data to PCR state; `sealToPcrs`/`unsealWithPcrs` bind to a whole PCR set (firmware 0–7 + OS 11). See SB-4 below.
- **AES-XTS encrypted block device (SB-5, DONE)** — `crypto/xts.zig` + `crypto/encrypted_block.zig` + `filesystem/encrypted_volume.zig` (TPM-sealed volume key). Mount auto-open pending. See SB-5 below.
- **`SecureVault` (SB-3, DONE)** — per-vault 256-bit wrapping key, XChaCha20-Poly1305 seal/unseal, keys never cross the user boundary. `create()` roots the key in the TPM hardware RNG (`SHA256(software_key ‖ TPM2_GetRandom)`) and sets `tpm_backed = true` when a TPM is present; software-only otherwise. Sealing a persistent key under a primary + PCR policy is SB-4.
- **Code signing** — Ed25519-over-Blake3 `.codesig` sidecars verify every spawned app. App-level integrity, above the boot chain.
- **Boot chain** — Limine → `init/stages/stage1..4`. `efi_var_get/set` are stubs returning `Unsupported`.

One-line summary of the gap: detected-but-unused TPM, no measured boot, no verified boot chain, no disk encryption.

---

## The three layers

**1. Verified boot (UEFI Secure Boot):** firmware verifies the bootloader signature against enrolled keys (PK/KEK/db); the bootloader verifies the kernel + initfs. A tampered image fails before executing. Answers "is each stage authentic?"

**2. Measured boot (TPM 2.0):** each stage hashes the next stage (and its config) and extends the digest into a TPM PCR before handing off: `PCR_new = H(PCR_old ‖ measurement)`. The final PCR set is an unforgeable summary of exactly what booted, and secrets can be **sealed to a PCR policy** (released only if measurements match). Answers "what booted?"

**3. At-rest confidentiality (disk encryption):** the data volume is encrypted; its volume key is sealed to the TPM under a PCR policy, so tampered boot → PCRs differ → unseal fails → data stays encrypted.

> **Reading the Secure Boot state (SB-6a/SB-6d):** the kernel reads the firmware's
> measured `SecureBoot` value from the PCR-7 event log
> (`eventlog.secureBootEnabled()`), not a live EFI runtime `GetVariable` call.
> The event log is captured by the bootloader and attested by PCR 7 (to which the
> disk key is sealed), so this is trust-equivalent to a live read but avoids
> mapping firmware runtime code executable against the kernel's W^X direct map.
> The EFI System Table itself is wired (`boot.efiSystemTable()`,
> `firmware/efi.zig`) for future runtime-services use.

These compose. The strongest posture: all three, with the disk key sealed to PCRs that only a Secure-Boot-verified Innigkeit can reproduce.

---

## Architecture

### TPM command interface

We need a driver that sends TPM 2.0 commands, not just detects the device. The ACPI TPM2 table's `start_method` identifies the interface:

- **CRB (Command/Response Buffer)** — MMIO command/response buffers + control registers. Modern, simplest; QEMU's `tpm-crb` uses it.
- **TIS (TPM Interface Specification, FIFO)** — older MMIO FIFO; QEMU also offers `tpm-tis`.

Decision: CRB first (QEMU default with `-tpmdev emulator` + `-device tpm-crb`), TIS as a follow-up. The driver exposes a synchronous `transmit(command_bytes) -> response_bytes`. We only need a small command subset.

### Minimal command subset

- `TPM2_GetCapability` — probe properties / PCR banks
- `TPM2_PCR_Extend` / `TPM2_PCR_Read` — measured boot
- `TPM2_GetRandom` — hardware entropy source (also strengthens `SecureVault`)
- `TPM2_CreatePrimary` (endorsement/storage hierarchy) — root key
- `TPM2_Create` / `TPM2_Load` — wrap the disk volume key under the primary
- `TPM2_StartAuthSession` + `TPM2_PolicyPCR` + `TPM2_Unseal` — release the volume key under the right PCR policy

### Measured boot

Limine measures the early chain into PCRs and exposes the TCG event log. Innigkeit's job: consume the event log and extend our own measurements (kernel config, initfs hash, codesign public key) into PCR 11 (OS-controlled) before launching userspace.

### Disk encryption

- **Cipher**: AES-XTS-256 for block/sector encryption (length-preserving, per-sector tweak). XChaCha20-Poly1305 (used by SecureVault) is authenticated but not length-preserving — good for file/blob layers, not raw sectors.
- **Layer**: a transparent `EncryptedBlockDevice` between `drivers/virtio/blk` and the filesystem, decrypting on read / encrypting on write per sector, keyed by the unsealed volume key.
- **Key custody**: sealed to the TPM under a PCR policy; fallback to a `SecureVault`-wrapped key when no TPM. This also closes the existing `SecureVault` TODO — derive the wrapping key from `TPM2_CreatePrimary` + `TPM2_GetRandom` when `tpm_backed`.

### Secure Boot chain

Mostly a build/provisioning task, not kernel code: sign the kernel image, enroll keys (PK/KEK/db) in firmware (or use Limine's secure-boot support), document the signing flow alongside the existing `codesign` tooling. The kernel's runtime role is small — read the Secure Boot state via an EFI variable, refuse to release sealed secrets if boot wasn't verified.

---

## Staging

Each step lands and tests independently.

**SB-1 — TPM CRB driver + command transport. DONE.** `drivers/tpm/crb.zig` maps the control area as uncached device MMIO (`memory.heap.allocateSpecial`; the direct map does not back device memory and faults), drives the PTP locality/cmdReady/start handshakes with wallclock-bounded polling, and exposes `transmit(cmd) -> resp`. `drivers/tpm/tpm.zig` builds `TPM2_GetCapability` + `TPM2_GetRandom`. `stage4` probes at boot. Validated against QEMU's `tpm-crb` + swtpm via the opt-in gate `zig build verify -Dtpm=true` (a build-managed `swtpm` instance, see `build/TpmHarness.zig`; tests skip when no TPM is present, so the default suite is unaffected). CRB buffers are assumed within the single mapped device page (true for QEMU); relocated buffers on real hardware are future work.

**SB-2 — Measured boot. DONE.** `drivers/tpm/tpm.zig` has `pcrExtend`/`pcrRead` (SHA-256 bank, empty-password `TPM_RS_PW` auth); `drivers/tpm/root.zig` `measure(label, data)` extends the codesign root key into PCR 11 at boot (`stage4`). Gated test extends a known value and asserts `PCR_new == SHA256(PCR_old ‖ measurement)`. **SB-2c (firmware event log): DONE.** `drivers/tpm/eventlog.zig` `capture()`s the Limine `TPMEventLog` request into kernel BSS early in stage1 (before bootloader-reclaimable memory is reused), and `replaySha256Pcr()` parses the TCG PC Client PFP crypto-agile log (legacy record 0 skipped, `TCG_PCR_EVENT2` records, SHA-256 bank, `EV_NO_ACTION` not extended) to reproduce the firmware-owned PCRs. Gated test: replaying the captured log reproduces live PCRs 0–7 exactly (PCR 5 reconciled with the two normative `EV_EFI_ACTION` "Exit Boot Services" measurements the firmware extends *inside* ExitBootServices, after Limine snapshots the log). The ACPI TPM2 LASA/LAML path is a dead end in this firmware — the 76-byte table doesn't expose a usable log pointer.

**SB-3 — TPM-backed `SecureVault`. DONE.** `SecureVault.create()` probes `drivers.tpm.device()` (a lock-guarded cached TPM singleton so the CRB MMIO is mapped once) and, when a TPM is present, derives the wrapping key as `SHA256(software_key ‖ TPM2_GetRandom)` and sets `tpm_backed = true`; software-only fallback otherwise. Gated test confirms a TPM-backed vault seals/unseals and reports `tpm_backed = true` under QEMU `tpm-crb`. `TPM2_CreatePrimary` is intentionally deferred to SB-4: for an ephemeral kernel-only key the primary's public area adds no secrecy; it is the tool for sealing a *persistent* disk key, validated there end-to-end.

**SB-4 — Seal data to a PCR policy. DONE.** `drivers/tpm/tpm.zig` adds `createPrimary` (ECC P-256 storage parent), `startAuthSession`/`policyPcr`/`policyGetDigest`, `create`/`load`/`unseal`, and the wrappers `sealToPcr(parent, pcr, data)` / `unsealWithPcr(parent, pcr, obj, out)`. A trial PolicyPCR session derives the object's authPolicy; unseal runs under a real PCR-bound policy session. Gated tests confirm a seal/unseal round-trip succeeds and that unseal FAILS once PCR 11 is extended (the evil-maid property). **Remaining for the disk path (SB-5 seam):** persist the sealed object in an on-disk volume header/keyslot and unseal the actual AES-XTS volume key at mount.

**SB-5 — Encrypted block device + sealed volume key. DONE.** `crypto/xts.zig` (AES-XTS, IEEE 1619 KAT) + `crypto/EncryptedBlockDevice.zig` (`EncryptedBlockDevice`, generic over a backing, host-tested: round-trip, ciphertext-on-disk, per-LBA tweak) + `filesystem/EncryptedVolume.zig`. `provision` generates the volume key from the TPM RNG, `sealToPcr`s it, writes a plaintext header (magic ‖ version ‖ sealed blobs) to sector 0, and returns the device; `open` re-reads the header at mount, `unsealWithPcr`s the key (only when the boot PCR matches), and rebuilds the device. Data lives in sectors `data_start_lba`.. ; `VirtioBacking` is the kernel adapter. Gated test: provision → write → fresh open re-reads the header and decrypts it back (header plaintext, data ciphertext). **Remaining for real boot:** call `open` on the actual data volume in `stage4` and route the filesystem through it — best done with SB-6 provisioning (first boot must `provision`).

**SB-6 — Secure Boot chain (build/provisioning). DONE, end-to-end verified.** Innigkeit boots under UEFI Secure Boot with its **own** root of trust. `zig build secureboot -- keygen` mints our PK/KEK/db (self-signed, `keys/secureboot/`, gitignored); `zig build verify -Dsecboot=true` (`build/Verify.zig`) enrolls them into an OVMF VARS store (`virt-fw-vars --no-microsoft` — only our keys), signs Limine's `BOOTX64.EFI` with our db key (`sbsign` on Linux / `osslsigncode` on macOS via `tools/secureboot`, into the ESP via mtools), and boots under `OVMF_CODE_4M.secboot.fd` + swtpm. Proven three ways: the signed image boots (all tests pass; with `-Dexpect_secure_boot=true` the PCR-7 SecureBoot test asserts SB *enabled*); an unsigned image is **rejected** by the firmware; and a **tampered-config** image (a copy of the *signed* image with `limine.conf` corrupted afterward — proving the config-hash binding independently catches tampering even when the .EFI signature is intact) is rejected by the (signed) bootloader.

**Full verified-boot chain (decision 1 — kernel verified boot, no gap):** the gate also `enroll-config`s the `limine.conf` BLAKE2B-512 into `BOOTX64.EFI` *before* signing, and Limine already pins the kernel via `kernel_path: .../kernel#<blake2b512>` (a tampered kernel is refused — verified by flipping one byte). So the chain is unbroken: **firmware verifies the signed `BOOTX64.EFI` → the enrolled config hash verifies `limine.conf` → the config's `#hash` verifies the kernel** (which by `@embedFile` also covers the initfs). No stage loads the next unverified. Enforcement half also done: the disk key is sealed to firmware/Secure-Boot PCRs 0–7 **and** OS PCR 11 (decision 2 — `tpm.sealToPcrs`, `drivers/tpm.seal_pcrs = {0..7,11}`), so a tampered or SB-disabled boot changes PCR 7 and the key won't unseal — the at-rest gate is cryptographic. Runtime SB state is read from the PCR-7 event log (see the SB-6a/SB-6d note above), not a live EFI runtime call. **Production signing (decision 3):** `zig build secureboot -- sign <image> <db.key> <db.crt>` (`tools/secureboot`) is the single sign operation (enroll-config + platform-dispatched signing), shared by `zig build verify -Dsecboot=true` (dev, throwaway keys) and `.github/workflows/release.yml`. The release workflow (tag `v*`) builds `image_x64`, signs BOOTX64.EFI with the `db` key from repo secrets (`SECUREBOOT_DB_KEY`/`SECUREBOOT_DB_CERT`), emits a SLSA build-provenance attestation, and attaches the signed image to the release; production keys live only in CI secrets.

**Kernel supply-chain signature — DONE (2026-07-13).** `tools/codesign` gained
`sign-artifact`/`verify-artifact` subcommands (a distinct, manifest-free format
from the app `.codesig`, since the kernel has no entitlements to carry) and
`build/Kernel.zig`'s `buildKernel` wires the release kernel binary through it,
installing `kernel.codesig` alongside `kernel` in `zig-out/<arch>/`. This is
**not** part of the boot-time verification chain — that's already unbroken
without it, per the "Full verified-boot chain" note below — it's a way to
verify a distributed kernel image (e.g. off a GitHub release) really came
from this project's own build, independent of ever booting it. Verified:
`zig build image_x64` produces a valid `kernel.codesig` that `verify-artifact`
accepts, and rejects a single flipped byte in the kernel binary.

Details in `.claude/rules/tpm-secure-boot.md`.

**The explicit "refuse to release the disk key when SB disabled" gate — DONE, verified 2026-07-13 (doc had gone stale, code was already there).** `filesystem/EncryptedVolume.zig`'s `mountAtBoot()` checks `tpm_drv.eventlog.secureBootEnabled(elog)` and skips straight past a candidate volume (key stays sealed, boot continues) when it reads back `false`; when the event log can't be located or the firmware doesn't expose the measurement (non-secboot test firmware) it falls through unaffected, so the plain `-Dtpm=true` test path is untouched, as required. This explicit check is defense-in-depth on top of the *real* enforcement: PCR 7 is already in `seal_pcrs` (decision 2's multi-PCR bind), so a Secure-Boot-disabled boot changes PCR 7 regardless, and `tpm.unsealWithPcrs` would cryptographically fail even without this check. Both layers hold.

QEMU setup: `swtpm` + `-tpmdev emulator,id=tpm0 -device tpm-crb,tpmdev=tpm0` for SB-1..SB-4; OVMF/AAVMF for SB-6.

---

## arm at-rest status (known blocker)

At-rest disk encryption (AES-XTS) is **verified on x86-64 but NOT yet trustworthy
on aarch64**. On the freestanding aarch64 kernel target, `std.crypto.core.aes`
(software impl) computes a self-consistent but non-standard permutation:
round-trips succeed, so `EncryptedBlockDevice` "works", but absolute known-answer
vectors (IEEE 1619) do **not** match - i.e. it is not real AES. The IEEE
1619 KAT in `crypto/xts.zig` is skipped on the freestanding-aarch64 kernel (with
a loud comment) so the suite stays actionable; it still runs on the host and x64
kernel. **Do not enable FDE on aarch64 until this is root-caused and the KAT
passes there.** (The mount scan and boot wiring are arch-neutral and fine.)

**Root-caused as far as: a genuine LLVM AArch64 codegen bug, not a kernel bug.**
Full investigation log lives in `.claude/rules/tpm-secure-boot.md`'s "[B]
Enforcement gate" section — summary: `code_model`, PIE, `optimize`, and
`side_channels_mitigations` were all ruled out one at a time; the same rodata
region reads back correct via a diagnostic probe while the AES arithmetic
using it is still wrong (rules out mapping/cache); a minimal repro harness
linked at a flat/low address was **correct**, isolating the trigger to the
kernel's actual high-half link address (`0xffffffff80000000`) specifically.
Conclusion at the time: file upstream (ziglang/zig, backend-llvm +
arch-aarch64 + miscompilation labels).

**2026-07-13 follow-up**, prompted by an unrelated but related-sounding
upstream report (Zig crypto maintainer `jedisct1`, in a thread about
freestanding-aarch64 `std.crypto.core.aes` codegen problems): tried the
maintainer's suggested `+strict-align` target feature
(`build/Bundle.zig`'s aarch64 `kernelTarget`) — confirmed via
`Target.Query.serializeCpu` that it actually lands in the resolved `-mcpu`
string, and independently re-derived the identical wrong output
(`e39bd32dfc008faf6f9f972a76f9b80e` for the zero-key/zero-block FIPS-197
vector, matching the prior investigation's own diagnostic byte-for-byte) —
**`+strict-align` does not fix it.** Also confirmed (matching a question
`jedisct1` asked in that thread) that it reproduces identically with
`side_channels_mitigations = .none`, consistent with the prior finding that
it's not mitigation-path-specific. `+strict-align` was kept anyway as
independent, low-cost hardening (a no-MMU freestanding target should never
rely on unaligned-access fixup a hosted OS would normally provide), but it
is **not the fix** for this bug — the KAT skip stays in place.

## Reference material

Specs to implement against (flag these when starting each step — local copies or Linux reference code would help):

- **TPM 2.0**: TCG Trusted Platform Module Library Parts 1/2/3 and the TCG PC Client Platform TPM Profile (PTP) for CRB/TIS register layout + `start_method` values. Linux `drivers/char/tpm/tpm_crb.c` / `tpm_tis_core.c` are good references.
- **UEFI**: Secure Boot + variable-services sections; TCG EFI Protocol + PC Client Platform Firmware Profile for event-log format and PCR usage. Linux `drivers/firmware/efi/` and `security/integrity/`.
- **Limine protocol**: Secure Boot module-hash mechanism + TPM-event-log request.
- **Disk encryption**: LUKS2 / `dm-crypt` for the AES-XTS sector scheme and header/keyslot design.

---

## Threat model

- **Evil-maid / tampered image**: Secure Boot refuses an unsigned/modified bootloader or kernel; measured boot makes any change visible in PCRs and prevents the disk key from unsealing.
- **Stolen disk**: AES-XTS keeps data confidential; the volume key is not in cleartext on disk.
- **Malicious userspace**: unchanged from today (capabilities + entitlements + fault-safe boundary).
- **Physical bus attacker (TPM sniffing, cold boot)**: out of scope for v1. Parameter encryption on TPM sessions and memory encryption are future hardening.
