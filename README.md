# innigkeit

## goals

- it boots
  - [x] works on my machine
- learn [Jujutsu VCS](https://www.jj-vcs.dev)
  - [x] first commit!
- target architecture (64-bit only)
  - [x] x64
  - [ ] arm (next priority)
  - [ ] riscv
  - [ ] good cross-architecture abi
- target bootloader
  - [x] limine
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
