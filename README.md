# innigkeit

<!-- TOC start (generated with https://github.com/derlin/bitdowntoc) -->
<!-- markdownlint-disable MD004 MD007 -->
- [27-05-2026 reflection](#27-05-2026-reflection)
   * [important functions & types](#important-functions--types)
   * [most recent failure example](#most-recent-failure-example)
- [goals](#goals)
- [q & a](#q--a)
- [instructions](#instructions)
   * [prerequesites](#prerequesites)
      + [download it](#download-it)
   * [doit](#doit)
   * [options](#options)
   * [running in UTM](#running-in-utm)
<!-- markdownlint-enable MD004 MD007 -->
<!-- TOC end -->

## 27-05-2026 reflection

- it went well! i think i learned a lot of how Zig works internally
- See [ATTRIBUTION.md](./ATTRIBUTION.md)

### important functions & types

| name | file | role |
| --- | --- | --- |
| `InnigkeitThreadImpl` | `library/innigkeit/thread.zig` | `std.Thread` backend with 3-state atomic join/detach, futex-based blocking |
| `Thread.startProcess` | `src/innigkeit/user/Thread.zig` | Writes full ELF-ABI initial stack (argc/argv/envp/auxv) into userspace |
| `spawnFull` | `library/innigkeit/process.zig` | Syscall wrapper that passes argv + envp via `SpawnSpec` |
| `callMainAndExit` | `library/innigkeit/entry.zig` | Parses ELF initial stack, populates `innigkeit.process._argv/_envp` globals |
| `App.createModule` | `build/App.zig` | Build-system function; now creates a two-module tree (wrapper root + app sub-module) |

### most recent failure example

```zig
// Missing the leading argc word: was (argc + envc + 2) instead of (argc + envc + 3)
const metadata_size = (argc + envc + 2) * S + 4 * @sizeOf(std.elf.Auxv);
```

This caused the envp pointer table to overlap the string data region, corrupting the first environment string. The correct count is `argc + envc + 3` (one for argc, one for argv null, one for envp null).

## goals

- it boots
  - [x] works on my machine
- learn [Jujutsu VCS](https://www.jj-vcs.dev)
  - [x] first commit!
  - [x] i'm pretty good at it i guess and i like it a lot!
- target architecture (64-bit only)
  - [x] x64
    - [ ] good interrupts
    - [ ] good syscall
  - [ ] arm (next priority)
  - [ ] riscv
- target bootloader
  - [x] limine
    - [x] it boots!
    - [ ] blake2b hash
    - [ ] track `limine.conf` as a build input
    - [ ] programmatic `limine.conf`
  - [ ] EFI stub?
  - [ ] multiboot for grub support, mayb (ew)
- target bios
  - [x] uefi
- disk layout
  - [x] `ext2` + NVMe
  - [x] `gpt`
  - [ ] `mbr`
    - [x] only for gpt protective mbr
  - [x] fat
  - [ ] other types of `ext`
- output
  - [x] basic display output
  - [x] basic serial support
  - [x] io terminal support + colors
  - [ ] better display support
  - [ ] some sort of graphics library (basicgl)
  - [ ] window manager and maybe some cool tuis as well
  - [ ] physics engine???
  - [ ] make it run DOOM
- userspace support
  - [ ] export libraries needed so that all the apps aren't in the same repo
  - [ ] good, fast syscalls
  - [ ] good standard library support
  - [ ] good Zig support
  - [ ] print hello world from the user level
  - [ ] make a small CLI
  - [ ] re-implement a small CLI
  - [ ] create a target to build existing apps for innigkeit

## q & a

- q: why in Zig?
  - a: mostly a mix of masochism because I love having to reimplement everything every version bump and i wanted to learn the language.
- q: why create a new OS isnt that like reinventing the wheel?
  - a: sort of, it's more like reinventing the wheel but there's thousands of pages of PDF documentation on the exact specifications of the wheel and it has been worked on and iterated upon for decades so if you mess up one tiny measurement for some 25 year old chip that was created in a basement in New Mexico everything falls apart and no one really knows what they're doing or why they're doing it
- q: that... sounds terrible
  - a: its actually kinda fun also that's not a question

## instructions

### prerequesites

- zig 0.16.0
- qemu 11.0.0 (used for running and testing)

#### download it

```sh
brew install zig qemu
```

good job!!! :D

### doit

see all build targets:

```sh
zig build --list-steps
```

see all steps and options:

```sh
zig build --help
```

build and run x64:

```sh
zig build run_x64 -Dlog_level=debug
```

If you want to see display output (pretty colors, framebuffer, DOOM), use [options](#options)

### options

- run with display: `zig build run_x64 -Ddisplay=true`

### running in [UTM](https://mac.getutm.app/)

note: this is no longer entirely necessary; you can use `zig build run_x64 -Ddisplay=true` on macOS and it works with display. if you need graphics acceleration, use UTM.

- download [UTM](https://mac.getutm.app/): `brew install --cask utm`
- run `zig build image_x64`
- create a new virtual machine -> emulate -> Other
- Hardware: keep defaults
- Boot Device: Drive Image -> Import Disk Image -> "Browse"
  - find `zig-out/x64/innigkeit_x64.hdd` and import it
- Shared Directory: keep defaults
- Summary: Check "Open VM Settings" -> Click "Save"
- QEMU -> QEMU Machine Properties: input `hpet=on`
- Devices -> Display -> Emulated Display Card: `virtio-vga-gl`
- Devices -> New... -> Serial
- Innigkeit doesn't support Network or Sound right now, so you can safely remove those devices.
- Click "Save"
- Run the VM!
- profit!
