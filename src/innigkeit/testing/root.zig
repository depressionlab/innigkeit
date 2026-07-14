pub const runner = @import("runner.zig");

// Reference test-only files so the test build collects their test blocks.
comptime {
    _ = @import("SyscallFrame.test.zig");
    _ = @import("smp.test.zig");
    _ = @import("efi.test.zig");
    _ = @import("EncryptedVolume.test.zig");
    _ = @import("security.test.zig");
    _ = @import("integration.test.zig");
    if (@import("kernel_options").tpm_test)
        _ = @import("tpm.test.zig");
}
