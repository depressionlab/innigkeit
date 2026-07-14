pub const EncryptedVolume = @import("EncryptedVolume.zig");
pub const ext4 = @import("ext4.zig");
pub const initfs = @import("initfs.zig");
pub const simple_fs = @import("simple_fs.zig");
pub const vfs = @import("vfs.zig");
pub const VolumeHeader = @import("VolumeHeader.zig");

comptime {
    // TODO: use vfs so we don't have to do this
    if (@import("builtin").is_test) {
        _ = ext4;
    }
}
