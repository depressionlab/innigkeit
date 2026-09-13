/// Minimal fixture spawned by `testing.integration.test.zig` via
/// `Process.spawnFromInitfs`. Deliberately jumps to an unmapped user
/// address so the test can assert the kernel isolates the resulting fault
/// to this process (exit-Notify fires with `Process.ExitStatus.sigsegv`).
/// On aarch64 this is an EL0 instruction abort, an `ESR.EC` value
/// `EsrEl1.ExceptionClass` does not name.
pub fn main() void {
    const unmapped: *const fn () callconv(.c) void = @ptrFromInt(0x10);
    unmapped();
    unreachable;
}
