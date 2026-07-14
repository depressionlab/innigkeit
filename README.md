# innigkeit

a capability-based microkernel written in Zig (with Rust subsystems), targeting x86-64 (primary), AArch64 (secondary), and RISC-V64. it boots to a real test suite on both x64 and arm, backed by capability-based IPC, an innovative hybrid EEVDF scheduler with an augmented Red-black tree, a real filesystem stack, UEFI Secure Boot, TPM 2.0, and disk encryption.

## what's here

- **security-first kernel**: every resource is a typed capability handle, rights are monotonically decreasing, SMEP/SMAP enforced, every app is Ed25519-signed and entitlement-gated at spawn
- **two working architectures**: x86-64 and AArch64 both boot to the full kernel test suite (148 and 104+14-skipped tests respectively); RISC-V64 links but has no QEMU suite yet
- **EEVDF scheduler**: same algorithm as Linux 6.6+, cross-executor work stealing, adjustable and hybrid: real-time, eevdf, latency
- **real disk stack**: GPT/FAT/ext4, AES-XTS full-disk encryption, TPM-sealed volume keys, UEFI Secure Boot chain
- **userspace**: Zig and Rust apps (`calculator`, `doom`, a small window manager, a shell, `hello_world`, and more), a shared syscall-wrapper library, code-signed and entitlement-checked at load

## prerequisites

- Zig 0.16.0
- QEMU 8.0-11.0+
- Rust (`x86_64-unknown-none` target)

```sh
brew install zig qemu
rustup target add x86_64-unknown-none
```

Or `nix develop` (see `flake.nix`) for a shell with all of the above.

- `keys/codesign_{private,public}.key` aren't committed (gitignored), so generate them once with `zig build codesign -- keygen`.

## building and running

```sh
zig build --list-steps # see every build target
zig build run_x64 # boot in QEMU (x86-64)
zig build run_arm # boot in QEMU (AArch64)
zig build test_x64 # run the kernel test suite; exit 1 = all passed
zig build verify # the full local verification gate
zig build run_x64 -Ddisplay=true # boot with the framebuffer (DOOM, the WM, etc.)
```

## thanks

see [`ATTRIBUTION.md`](./ATTRIBUTION.md) for helpful projects and references.
