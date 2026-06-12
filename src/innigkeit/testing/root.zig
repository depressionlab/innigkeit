pub const runner = @import("runner.zig");

comptime {
    // Reference test-only files so the test build collects their test blocks.
    _ = @import("syscall_frame.test.zig");
    _ = @import("smp.test.zig");
}
