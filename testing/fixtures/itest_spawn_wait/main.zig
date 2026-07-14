const innigkeit = @import("innigkeit");

/// Minimal fixture spawned by `testing.integration.test.zig` via
/// `Process.spawnFromInitfs`. Exits immediately with a fixed status so the
/// test can assert the exit-Notify fires with the expected value.
pub fn main() void {
    innigkeit.process.exit(42);
}
