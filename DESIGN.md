# design

uhhhh hhh:

- all 64-bit: x64, arm, riscv (in priority order)
- limine bootloader first and foremost
  - then we can do like, multiboot or EFI stub
- focused on targeting modern and efficient standards

## issues/todo

- [ ] library dependency loops?
- [ ] interrupt handler generation
- [ ] panic stack overflow
- [ ] `x86` backend?
- [ ] power management: idle, battery support
- [ ] scheduling: better algorithim
- [ ] task management and execution: better algorithim
- [ ] image builder: support ext2
- [ ] improve disk image layout
- [ ] `inline for`
- [ ] library tests need to be run in innigkeit itself, not on the host
- [ ] include stdlib and other external dependencies in embedded files for stack trace
