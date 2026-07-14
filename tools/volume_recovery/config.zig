const std = @import("std");
const ToolDescription = @import("../../build/ToolDescription.zig");

/// Wire the std-only volume-header codec and passphrase keyslot (from the kernel
/// source tree) into the host recovery tool as named imports.
pub fn config(b: *std.Build, _: *const ToolDescription, module: *std.Build.Module) void {
    module.addImport("VolumeHeader", b.createModule(.{
        .root_source_file = b.path("src/innigkeit/filesystem/VolumeHeader.zig"),
    }));
    module.addImport("PassphraseKeyslot", b.createModule(.{
        .root_source_file = b.path("src/innigkeit/crypto/PassphraseKeyslot.zig"),
    }));
}
