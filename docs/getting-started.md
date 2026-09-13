# Getting started

A first-time walkthrough from a fresh clone to a passing verification gate.
This doc doesn't duplicate `CLAUDE.md`'s command table or
`docs/verification-and-ci.md`'s build-step hierarchy — it's the "what do I
actually type, in what order" path through both. Bare `zig build` (or
`zig build help`) prints a shorter version of this same menu from inside
the build itself.

## 1. Prerequisites

You need, on `PATH`:

- **Zig 0.16.0** exactly — the version is enforced at build time (`build.zig`
  checks `build.zig.zon`'s `minimum_zig_version` and fails with a clear
  message rather than miscompiling against a mismatched compiler).
- **QEMU 8.2+** for both architectures: `qemu-system-x86_64` and
  `qemu-system-aarch64`. AArch64 additionally needs host-packaged AAVMF
  firmware (`/usr/share/AAVMF/` on Debian/Ubuntu; see CLAUDE.md's "QEMU
  gotcha" for the macOS/Homebrew and Nix equivalents).
- **Rust's bare-metal target**, for the three Rust sample apps embedded in
  the initfs: `rustup target add x86_64-unknown-none`.

On Claude Code on the web, all of this is provisioned automatically — see
CLAUDE.md's Setup section for how (`scripts/cloud-setup.sh` as the
environment's Setup script, or the in-repo SessionStart hook once you've
accepted the workspace-trust dialog once).

## 2. Two prerequisites that bite on the very first build

Neither is a bug — both are deliberate (a codesigning private key and a
package-fetcher cache aren't things to commit), but they trip up a fresh
clone identically:

1. **No codesign keypair is committed** (`keys/codesign_{public,private}.key`
   are both gitignored). Generate them once:

   ```sh
   zig build codesign -- keygen
   ```

   Skipping this doesn't fail loudly at the `keygen` step — it fails later,
   the first time anything tries to sign an app, with a `FileNotFound`
   pointing back at this same command.

2. **Zig's package fetcher can't traverse a CONNECT proxy** in some sandboxed
   environments (cloud sessions see `HttpConnectionClosing`, an empty global
   cache). If `zig build` fails fetching a `build.zig.zon` dependency this
   way, pre-populate the cache by `curl`-ing each dependency's tarball
   directly (its release URL, or `codeload.github.com/<owner>/<repo>/tar.gz/<sha>`
   for a `git+https` dependency) and running `zig fetch <local-tarball>` —
   the hash it prints must match the one already in `build.zig.zon`.

## 3. The fastest signal: `zig build check`

Compiles everything with `-fno-emit-bin` — no linking, no QEMU, just "does
this parse and typecheck." This is the first thing to run after any change,
and the thing to re-run in a tight loop while iterating.

**What it does *not* catch**: inline assembly. `check` never validates
`asm` blocks (`-fno-emit-bin` skips codegen entirely), so after touching
anything under `src/architecture/` or another file with raw `asm`, follow
up with a real build (`zig build build_all`, or boot the affected arch)
before trusting the change.

## 4. See it actually boot

```sh
zig build run_x64   # boots to a shell, x86-64
zig build run_arm   # boots to a shell, AArch64 (single-core)
```

Both use host QEMU + host firmware automatically (`build/Platform.zig`
prefers these over the vendored/bundled fallbacks — see CLAUDE.md's "QEMU
gotcha" if a boot hangs or firmware misbehaves on your specific host).

## 5. Run the test suites

```sh
zig build test_x64    # build the test kernel, run its suite in QEMU, judged by exit code
zig build test_arm    # same, AArch64 -- judged by the serial verdict line, not exit code
zig build test_native # host-only unit tests (pure logic: TCP parsing, codecs, wm_core, fuzz targets) -- no QEMU at all
```

`test_arm`'s pass/fail comes from `build/VerdictStep.zig` scanning the
serial log for `ALL N TEST(S) PASSED` — a real build-graph dependency, not
a script grepping after the fact.

## 6. The verification gate

This is what CI runs, and what to run before calling anything "done":

```sh
zig build verify                  # check + test_native + x64 suite
zig build verify -Darm=true       # also the arm suite
zig build verify -Dtpm=true       # also the opt-in TPM 2.0 suite (build-managed swtpm)
zig build verify -Dsecboot=true   # also the opt-in UEFI Secure Boot suite (own PK/KEK/db)
zig build verify -Dcpus=1         # single-core run of any of the above
```

The opt-in suites degrade gracefully (skip with a printed note) if a
required tool or firmware file is missing, rather than hard-failing —
useful when iterating on a host that doesn't have `swtpm`/`sbsign`/etc.
installed.

## 7. Everything else

`zig build -l` prints every step this build graph defines — apps,
libraries, and tools each get their own (`zig build core` builds and runs
just the `core` library's host tests, for instance). That list is long
(~100+ entries) by design: it's the exhaustive reference, not the starting
point. Start from this doc, `CLAUDE.md`'s command table, or `zig build
help`, and drop into `-l` only once you know the specific step name you
want.

## 8. Where to go next

- `CLAUDE.md` — the standing reference: layout, security model, key
  invariants, the full command table.
- `docs/DESIGN.md` — binding style/craft guide; read before writing any
  new code in this repo, not just when stuck.
- `docs/roadmap.md` — single entry point for "what's the current state of
  the project and what's next," read after any context reset.
- `docs/verification-and-ci.md` — the build-step hierarchy and how CI/
  release actually wire into it.
- `.claude/rules/*.md` — durable, dated findings about specific
  subsystems (arm, build, memory, x64) that didn't fit anywhere else.
