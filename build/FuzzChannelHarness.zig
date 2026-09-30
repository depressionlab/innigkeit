//! Host-side UDP client for `-Dfuzz_channel=true` attached to the
//! build graph.
//!
//! Unlike `TpmHarness.zig`'s daemon (which forks into the background
//! and exits, so waiting for the spawn is the readiness signal), the
//! client here (`tools/kernel_fuzz`) is a foreground process that must
//! still be running (retrying against the hostfwd'd port) while the
//! guest boots and its net-poll task comes up.
//!
//! `start` spawns it and returns immediately (does not wait).
//! `stop` is wired after the QEMU run step's verdict, so the guest has
//! already run the fuzz-channel test to completion or failed trying. It
//! does wait for the child and fails the build if it didn't report a
//! verified round trip.
const FuzzChannelHarness = @This();

const std = @import("std");
const Step = std.Build.Step;

exe: std.Build.LazyPath,
corpus_dir: []const u8,
child: ?std.process.Child = null,

start: Step,
stop: Step,

pub fn create(owner: *std.Build, exe: std.Build.LazyPath, corpus_dir: []const u8) error{OutOfMemory}!*FuzzChannelHarness {
    const self = try owner.allocator.create(FuzzChannelHarness);
    self.* = .{
        .exe = exe,
        .corpus_dir = corpus_dir,
        .start = .init(.{
            .id = .custom,
            .name = "fuzz-channel-client-start",
            .owner = owner,
            .makeFn = makeStart,
        }),
        .stop = .init(.{
            .id = .custom,
            .name = "fuzz-channel-client-stop",
            .owner = owner,
            .makeFn = makeStop,
        }),
    };

    exe.addStepDependencies(&self.start);
    return self;
}

fn makeStart(step: *Step, options: Step.MakeOptions) !void {
    const b = step.owner;
    const io = b.graph.io;
    const self: *FuzzChannelHarness = @fieldParentPtr("start", step);

    const node = options.progress_node.start("start fuzz-channel client", 1);
    defer node.end();

    const exe_path = try self.exe.getPath4(b, step);
    const exe_path_str = b.pathResolve(&.{ exe_path.root_dir.path orelse ".", exe_path.sub_path });

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(io, self.corpus_dir) catch |e|
        return step.fail("unable to create fuzz corpus directory '{s}': {t}", .{ self.corpus_dir, e });
    cwd.createDirPath(io, b.pathJoin(&.{ self.corpus_dir, "crashes" })) catch |e|
        return step.fail("unable to create fuzz corpus crashes subdirectory: {t}", .{e});
    cwd.createDirPath(io, b.pathJoin(&.{ self.corpus_dir, "interesting" })) catch |e|
        return step.fail("unable to create fuzz corpus interesting subdirectory: {t}", .{e});

    self.child = std.process.spawn(io, .{
        .argv = &.{ exe_path_str, self.corpus_dir },
        .stdin = .ignore,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| return step.fail("unable to spawn '{s}': {t}", .{ exe_path_str, e });
}

fn makeStop(step: *Step, options: Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const io = b.graph.io;
    const self: *FuzzChannelHarness = @fieldParentPtr("stop", step);

    const node = options.progress_node.start("check fuzz-channel client", 1);
    defer node.end();

    var child = self.child orelse return step.fail("fuzz-channel client was never started", .{});
    const term = child.wait(io) catch |e|
        return step.fail("failed waiting for the fuzz-channel client: {t}", .{e});
    self.child = null;

    switch (term) {
        .exited => |code| if (code != 0)
            return step.fail("fuzz-channel client exited with code {d} (see its stderr above for the reason)", .{code}),
        .signal, .stopped, .unknown => return step.fail("fuzz-channel client terminated abnormally: {any}", .{term}),
    }
}
