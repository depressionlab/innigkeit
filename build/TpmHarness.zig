//! `swtpm` lifecycle configuration for `-Dtpm=true` and the Secure Boot suite.
//!
//! The daemon is owned by `tools/build_helper with-swtpm`, which wraps the
//! QEMU invocation itself (see `QEMU.buildQemuCommand`): it starts swtpm,
//! runs QEMU, and kills swtpm afterwards.
const TpmHarness = @This();

const std = @import("std");

state_dir: std.Build.LazyPath,
socket: std.Build.LazyPath,

/// `name` picks the state directory under the local cache's `tmp/`; give
/// concurrent users distinct names.
pub fn create(b: *std.Build, name: []const u8) TpmHarness {
    const state_dir = std.Build.LazyPath.cache_root.path(b, b.pathJoin(&.{ "tmp", name }));
    return .{ .state_dir = state_dir, .socket = state_dir.path(b, "sock") };
}

/// Appends the `with-swtpm ... --` prefix to `run`'s arguments.
pub fn addWrapperArgs(self: TpmHarness, run: *std.Build.Step.Run) void {
    run.addArg("with-swtpm");
    run.addDirectoryArg2(self.state_dir, .{});
    run.addDirectoryArg2(self.socket, .{});
    run.addArg("--");
}
