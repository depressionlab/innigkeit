/// Boot-time hardware security invariant tests.
///
/// These verify that the kernel's security-critical CPU features are active at
/// runtime. They run after all CPU initialisation (stage1–3 complete before the
/// test runner fires in stage4), so CR4 reflects the final configured state.
///
/// Architecture note: these tests use inline assembly that is only valid on x64.
/// The test binary is only built for x64, so the `comptime` guard below is a
/// belt-and-suspenders check rather than a functional branch.
const std = @import("std");
const builtin = @import("builtin");

test "x64: SMEP is enforced at runtime (CR4 bit 20)" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const cr4: u64 = asm ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    // CR4.SMEP (bit 20): prevents kernel from executing code on user-mode pages.
    try std.testing.expect(cr4 & (1 << 20) != 0);
}

test "x64: SMAP is enforced at runtime (CR4 bit 21)" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const cr4: u64 = asm ("mov %%cr4, %[value]"
        : [value] "=r" (-> u64),
    );
    // CR4.SMAP (bit 21): prevents kernel from accessing user-mode pages outside
    // stac/clac-guarded windows (enforced by incrementEnableAccessToUserMemory).
    try std.testing.expect(cr4 & (1 << 21) != 0);
}
