//! Host-side UDP client configuration for `-Dfuzz_channel=true`.
//!
//! The client (`tools/kernel_fuzz`) is a foreground process that must already
//! be running (retrying against the hostfwd'd port) while the guest boots and
//! its net-poll task comes up. `tools/build_helper with-fuzz-client` wraps the
//! QEMU invocation: it starts the client, runs QEMU, then fails the run unless
//! the client reported a verified round trip.
const FuzzChannelHarness = @This();

const std = @import("std");

exe: *std.Build.Step.Compile,
corpus_dir: std.Build.LazyPath,
iterations: u32,
seed: ?u64,

pub fn create(exe: *std.Build.Step.Compile, iterations: u32, seed: ?u64) FuzzChannelHarness {
    return .{
        .exe = exe,
        .corpus_dir = .{ .relative = .{ .base = .install_prefix, .sub_path = "fuzz-corpus" } },
        .iterations = iterations,
        .seed = seed,
    };
}

/// Appends the `with-fuzz-client ... --` prefix to `run`'s arguments.
pub fn addWrapperArgs(self: FuzzChannelHarness, run: *std.Build.Step.Run) void {
    const b = run.step.owner;
    run.addArg("with-fuzz-client");
    run.addArtifactArg2(self.exe, .{});
    run.addDirectoryArg2(self.corpus_dir, .{});
    run.addArg(b.fmt("{d}", .{self.iterations}));
    run.addArg(if (self.seed) |seed| b.fmt("0x{x}", .{seed}) else "-");
    run.addArg("--");
}
