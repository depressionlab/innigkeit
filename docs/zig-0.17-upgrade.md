# Zig 0.16.0 → 0.17.0 upgrade

Status log and decision record for the toolchain upgrade. Read `docs/roadmap.md`
first; this file owns the 0.17-specific detail.

## What 0.17 changed that mattered here

| Change | Where it hit | Resolution |
| --- | --- | --- |
| `build.zig` runs in its own *configurer* process; the *maker* runs the graph. Custom `Step.make` no longer exists (fixed `Step.Tag` set). | `LimineConfigStep`, `ImageManifestStep`, `ImageStep`, `VerdictStep`, `TpmHarness`, `FuzzChannelHarness`, the `help`/install/default steps in `build.zig` | Replaced by `Step.Run`s over host tools: `image_builder describe` and `tools/build_helper` (`verdict`, `with-swtpm`, `with-fuzz-client`, `print`, `patch-compiler-rt`). `Step.Fail` for the disabled `install`/`uninstall`. |
| No configure-time install prefix / `b.install_path` / `getInstallPath` | Rust app target dir, kernel `--store`, installed image path, fuzz corpus | `LazyPath` with `.relative = .{ .base = .install_prefix }` and `addOutputDirectoryArg2`. |
| `Step.Run.addArgs(b.args)` → `addPassthruArgs()`; `*Prefixed*` helpers → `*2` | `build/Tool.zig` | Fixed. |
| `b.findProgram` and any other untracked configure-time host probe **poisons the configuration cache** (each `zig build` then re-runs `build.zig`) | `build/Platform.zig`, `src/*/custom.zig`, `build/Kernel.zig`, `build/RustApp.zig`, `git describe` | `build/configure_deps.zig` records tracked dependencies instead (a missing path is tracked through its nearest existing ancestor directory, since the cache manifest cannot register a path that does not exist). QEMU is resolved on `PATH` at run time. See "Open: remaining cache poisoning". |
| Struct/enum/fn reflection is struct-of-arrays (`field_names`, `field_types`, `param_types`, `attrs.varargs`) | `entry.zig`, `TypeErasedCall.zig`, `ElfFile.zig`, `syscall.zig`, … | Fixed. |
| `a ** n` array repetition removed | 116 sites | Rewritten mechanically to `@splat` (`@as([N]T, @splat(v))` or bare `@splat(v)` where the result type is known). |
| `@bitCast` of `extern` structs/unions rejected; `@bitSizeOf` unavailable for them | `TypeErasedCall`, `TicketSpinLock`, `IA32_STAR`, `core.testing.expectSize`, bitjuggle tests | `packed struct` where the layout is padding-free, byte copy / union field init elsewhere. |
| `std.Io.VTable` reshaped (`processReplacePath`, `processSpawnPath`, `net{Read,Send,Write}` gone; `inheritParentDir/File` added; `Operation` gained `net_send/net_read/net_write`) | `library/innigkeit/stdio.zig`, `interop/debug_io.zig` | Stubs updated. |
| `std.hash.crc.Crc32IsoHdlc` → `std.hash.Crc32`; `std.elf.AT_*` → `std.elf.AT.*` | gpt, ElfFile, Thread, entry | Fixed. |
| `evex512` target feature removed; `@splat` result-type changes | `build/Bundle.zig`, `graphics.zig` | Fixed. |
| `fetch`: `zig fetch <file>` caches the tarball with its wrapper directory still nested, so `zig build` later reports a hash mismatch for every dependency | `.claude/hooks/session-start.sh` (this broke the cloud Setup script) | Tarballs are flattened before `zig fetch`. |
| **Regression ziglang/zig#37006**: on x86-64 with `soft_float`, `compiler_rt` fails to build (`c_longdouble` is not extern-compatible, but compiler_rt exports `cosl`, `expl`, … unconditionally). Listed under 0.17.0's known regressions. | every x64 app, the kernel and the test kernel | `build/CompilerRt.zig` builds a patched copy of Zig's own compiler_rt (`c_longdouble` → `f64`, via `build_helper patch-compiler-rt`) and links it in place of the bundled one. The helper fails loudly once stock sources stop mentioning `c_longdouble`, which is the cue to delete the workaround. |

## Dependencies

| Dependency | Change |
| --- | --- |
| `zlinter` | `0.16.x` → `0.17.x` branch (pinned commit). |
| `toml` | → `zig-0.17` branch. |
| `devicetree` | → `main`. |
| `sbi` | **Vendored** at `library/sbi` (one line removed). Upstream `main` still sets `b.enable_qemu`, removed in 0.17. Delete the vendored copy and restore the git dependency once upstream drops that line. |

Zig's own HTTP client cannot traverse the cloud proxy, so hashes for the new
revisions were computed from `git archive` tarballs fetched with plain `git`.

## Judgment calls worth a second look

- **Rust apps now rebuild from scratch every build.** Cargo's target dir is a `Run` output directory (the configure phase can no longer name `{install_prefix}/cargo-target`), so cargo's incremental cache is gone. The three apps are tiny `no_std` binaries; if it ever hurts, a fixed cache-relative `--target-dir` is the alternative.
- **Bare `zig build` now prints the menu as the `install` step's failure message** (a default step must be reachable from a top-level step).
- **The secboot suite starts a fresh swtpm per boot** (the wrapper owns the daemon) instead of sharing one across the three boots; boots stay serialized because they share the socket path.
- **`.cargo/config.toml`** had been pinned to a `/nix/store/…/ld.lld` path; restored to the portable `ld.lld`. Nix users who need the pin should set it in their own `~/.cargo/config.toml`.
- `findQemuBinary` prefers a locally built `.tools/qemu/bin/<name>` when present, otherwise the bare name on `PATH`. (The old code searched the bundled directory *first* too, contrary to what CLAUDE.md says about host QEMU winning.)

## Verification status (Zig 0.17.0)

| Gate | Result |
| --- | --- |
| `zig build check`, `build_all`, `test_native` | pass |
| `zig build test_x64` | 187 passed, 4 skipped (≈44 s end to end) |
| `zig build test_arm` | 187 passed, 15 skipped (≈53 s) |
| `-Dtpm=true` (x64) | 206 passed, 6 skipped (17 TPM tests) |
| `verify -Dsecboot=true` | 371/371 steps; signed boot passes, unsigned and tampered-config boots are rejected by firmware |
| `zig build lint` | runs (custom rules ported to the zlinter 0.17.x API); 2 errors + 616 warnings, see below |
| `-Dcheckpoint_test`, `-Dfault_inject_block_test`, arm `-Dtpm`/`-Dsecboot` | not run on 0.17 yet |

Two bugs found on the way were not 0.17 changes but latent: the `AddressSpace`
wrappers from the pre-session port that logged an error and then returned
success (this made the first x64 run double-fault in "repeated spawn/wait
cycles"), and the Secure Boot suite's three boots never being ordered (only
their verdict steps were), which the old shared swtpm hid.

Lint: the two *errors* are `if (true) return error.SkipZigTest;` in
`integration.test.zig` (two integration tests disabled in `6bcba9b` on
2026-09-13, "testing harness rework"; they are not run by any suite today).

## Configuration cache

`build.zig` is pure: `zig build check --cache-poison=disallowed` passes, and
repeat invocations report `configuration cache hit`. What it took:

- zlinter moved out of the main build into the separate `lint/` project (its
  `build.zig` calls `findProgram("kcov")` unconditionally). `zig build lint`
  runs `lint/build.zig` as a subprocess and forwards arguments after `--`;
  `zig build --build-file lint/build.zig lint` works directly too.
- Every configure-time probe of the host is tracked (`build/configure_deps.zig`).
- `git describe` for the version string declares its inputs (`.git/HEAD`, the
  branch ref, `packed-refs`, the tags directory), so a new commit invalidates
  the cached configuration; verified for branch switches and for same-branch
  commits. A `.git` that is not a plain directory (worktree/submodule) falls
  back to poisoning.

Measured on this container, no-op `zig build check`: ≈1.1 s with a poisoned
configuration vs ≈0.9 s with it cached; the rest is traversing ~370 steps.

## Audit notes

Done:

- **F4 (socket ownership) fixed** with no ABI change; see
  `.claude/rules/user-boundary.md` and `docs/security-audit.md`. Three new
  kernel tests; the fuzz-channel suite still passes.
- **Error propagation.** The `AddressSpace` wrappers from the pre-session port
  returned success after logging (fixed earlier); now also private
  (`handlePageFaultInner`) and covered by a regression test. Those were the only
  four `errdefer |err|` conversions in that commit. Other `catch {}`/`catch return`
  sites in kernel code were reviewed: the rest are `catch unreachable` on
  provably infallible calls or diagnostics-only paths.
- **0.17 semantic changes with no compile error.** `@bitCast` of arrays/vectors
  (little-endian targets only here, so unchanged); `@hasDecl` now public-only
  (all five uses target declarations that must be public anyway); `@bitCast` to
  an enum is now safety-checked (no syscall path bit-casts to an enum; the one
  integer-to-enum conversion, `thread_set_qos`, range-checks first).

Open / judgment calls:

- `address_space.unmap(...) catch {}` rollbacks in `user/handlers/{vmem,framebuffer}.zig`
  drop a failure silently; low severity (the mapping was being granted anyway,
  or is an unbacked reservation that faults) but they should at least log.
- `ext4.zig:1197` `freeBlock(...) catch {}` leaks a block on failure.
- `socket.zig`'s `handleIp()` does not compare the packet's destination IP with
  the host's (flagged in `.claude/rules/network.md`; needs a decision on
  broadcast/multicast).
- Sockets as typed capability handles remains the better end state for F4.
- Two integration tests are disabled with `if (true)` (see Verification status).
- Not yet audited this pass: scheduler, capability table, syscall entry
  (all covered by the 2026-06 audit and Phase 2/3 reviews; nothing in the 0.17
  changes touched their logic).

## Beyond the upgrade

Planned follow-ups, in order:

1. Make the configuration pure (version string at make time; decide on zlinter).
2. Finish the audit of the critical paths named in `docs/DESIGN.md` Part 5
   (syscall entry, user-memory validation, capability table, scheduler,
   page-fault path), including `docs/security-audit.md` F4 (socket ownership).
3. Run the opt-in suites not yet exercised on 0.17.
