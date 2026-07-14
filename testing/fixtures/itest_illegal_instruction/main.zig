const builtin = @import("builtin");

/// Minimal fixture spawned by `testing.integration.test.zig` via
/// `Process.spawnFromInitfs`. Deliberately executes an illegal instruction
/// so the test can assert the kernel isolates the resulting exception to
/// this process (exit-Notify fires with `Process.ExitStatus.sigill`)
/// instead of panicking the whole kernel.
pub fn main() void {
    switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("ud2"),
        .aarch64 => asm volatile ("udf #0"),
        .riscv64 => asm volatile ("unimp"),
        else => @compileError("no illegal-instruction encoding for this target!"),
    }
    unreachable;
}
