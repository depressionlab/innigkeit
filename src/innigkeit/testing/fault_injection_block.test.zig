//! Fault-injection tests for the block-device seam.

const innigkeit = @import("innigkeit");
const std = @import("std");

const fault_inject_block = innigkeit.testing.fault_inject_block;
const log = innigkeit.debug.log.scoped(.fault_inj_blk);

test "fault injection (block): simple_fs.open returns IoError when the directory read fails" {
    if (!innigkeit.drivers.virtio.blk.isDataReady()) return error.SkipZigTest;
    const dev_idx = innigkeit.drivers.virtio.blk.dataDeviceIndex();

    fault_inject_block.armRead(dev_idx, 0);
    defer fault_inject_block.disarm(dev_idx);

    if (innigkeit.filesystem.simple_fs.open("fi_probe", .{ .create = true })) |_| {
        return error.OpenUnexpectedlySucceeded;
    } else |err| if (err != error.IoError) {
        log.err("expected error.IoError, got {t}", .{err});
        return error.WrongErrorReturned;
    }
}

test "fault injection (block): mountAtBoot treats a header-read device error like an absent volume" {
    // Same precondition as `EncryptedVolume.test.zig`'s sibling test: the
    // default test image's only disk is the plaintext GPT boot disk, so a
    // real (non-injected) re-scan would also leave `bootVolume()` null.
    // This test's job is proving the *read failure itself* (the `catch
    // continue` branch, never otherwise exercised) reaches the same safe
    // outcome, not just the "wrong magic" branch the sibling test covers.
    if (innigkeit.drivers.virtio.blk.deviceCount() == 0) return error.SkipZigTest;

    fault_inject_block.armRead(0, 0);
    defer fault_inject_block.disarm(0);

    innigkeit.filesystem.EncryptedVolume.mountAtBoot();

    try std.testing.expect(innigkeit.filesystem.EncryptedVolume.bootVolume() == null);
}
