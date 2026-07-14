---
paths:
  - "src/innigkeit/capabilities/**"
  - "src/innigkeit/user/codesign/**"
---

# Capability system invariants

- **Rights monotonicity**: `CapabilityTable.copyLocked` rejects any `new_rights` not a strict subset of the source slot's rights. A capability copy can only restrict, never add rights.
- **Generation counters**: revocation increments an atomic generation counter. All existing slots fail `getAndRefLocked` after revocation — the snapshot taken before unlock is still valid because the ref is held, but a revoked cap is dead to new callers.
- **Slab reuse**: the slab constructor runs once per slot at initial allocation, NOT on each reuse. Always re-initialise all mutable state in the caller of `cache.allocate()`. This is a hard invariant — process slots silently carry stale state if you don't.
- **`getAndRefLocked`**: validates generation and takes a ref before the table lock drops. The ref is held across the operation, so the object cannot be freed. This makes "rights not re-checked after unlock" false positives — the snapshot is sound.
- **`SecureVault`**: wrapping keys are zeroed on `unref`. Keys never cross the kernel/user boundary. `create()` probes the TPM (`drivers.tpm.device()`); when a TPM 2.0 device is present the wrapping key is `SHA256(software_key ‖ TPM2_GetRandom)` and `tpm_backed = true` (SB-3), else CSPRNG-software-only. Persisting a key by sealing under a TPM primary + PCR policy is SB-4.
- **Code signing enforcement**: `config.zig` — `enforce_code_signing` and `enforce_entitlements` are both `builtin.mode != .Debug`. Debug builds skip all enforcement. Never assume enforcement is active in a Debug build.
- **`Process.create()`** (stage4 initial shell): resets entitlements to all-true before returning. Safe because `spawn` syscall **always overwrites** entitlements from the verified codesig before the new process runs.
