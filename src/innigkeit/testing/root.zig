pub const runner = @import("runner.zig");
pub const fuzz_coverage = @import("fuzz_coverage.zig");
pub const checkpoint = @import("checkpoint.zig");
pub const fault_inject_block = @import("fault_inject_block.zig");

// Reference test-only files so the test build collects their test blocks.
comptime {
    _ = @import("SyscallFrame.test.zig");
    _ = @import("FlushRequest.test.zig");
    _ = @import("smp.test.zig");
    _ = @import("efi.test.zig");
    _ = @import("EncryptedVolume.test.zig");
    _ = @import("security.test.zig");
    _ = @import("integration.test.zig");
    _ = @import("fault_injection.test.zig");
    if (@import("kernel_options").tpm_test)
        _ = @import("tpm.test.zig");
    if (@import("kernel_options").fuzz_channel_test) {
        _ = @import("fuzz_channel.test.zig");
        _ = @import("fuzz_target.test.zig");
    }
    if (@import("kernel_options").checkpoint_test)
        _ = @import("checkpoint.test.zig");
    if (@import("kernel_options").fault_inject_block_test)
        _ = @import("fault_injection_block.test.zig");
}
