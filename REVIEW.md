# Review checklist

Flag as blocking:

- **Slab reuse.** Any new or changed field on a slab-cached type (`Process`, `Thread`, `Task`, `Entry`, `AnonMap`, `AnonPage`, ...) must be reset by the allocating function or documented `slab-reuse-ok:`. See `.claude/rules/slab-reuse.md`. Check the reset itself, not just that the lint is quiet.
- **User memory.** Any user pointer touched outside `user/validate.zig` helpers; any `UserAccess` window held across a blocking call.
- **Capability rights.** Any path that adds rights, skips `.grant` on cross-process transfer, or uses a slot without `getAndRefLocked`.
- **Arch boundary.** Physical register names (`rax`, `x0`) in generic code.
- **Docs.** Do not add "found and fixed" narratives to `.claude/rules/`; bug history belongs in `docs/bug-archive.md`.
