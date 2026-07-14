//! Fails the build unless a QEMU debugcon/serial log contains the kernel
//! test runner's verdict line (and any additional required substrings
//! e.g. proof a specific opt-in suite, like TPM, actually ran rather than
//! being silently skipped).
//!
//! The QEMU exit code alone isn't sufficient ground truth: only x64's
//! isa-debug-exit convention is checked by `buildTestQemuStep`, arm has no
//! exit-code check at all (its semihosting exit is not routed through
//! QEMU's own process exit status the same way), and in general a crash
//! before the kernel reaches its verdict can still leave QEMU exiting 0.
const VerdictStep = @This();

const std = @import("std");
const Step = std.Build.Step;

step: Step,
log: std.Build.LazyPath,
required_substrings: []const []const u8,
/// true (the default): fail unless the log shows a passing verdict.
/// false: fail if the log shows ANY kernel output at all. Used for the
/// Secure Boot suite's unsigned/tampered-config cases, where firmware
/// rejecting the bootloader before it ever runs is the expected, correct
/// outcome.
expect_boot: bool = true,

pub fn create(
    owner: *std.Build,
    run: *Step.Run,
    log: std.Build.LazyPath,
    required_substrings: []const []const u8,
    expect_boot: bool,
) error{OutOfMemory}!*VerdictStep {
    const self = try owner.allocator.create(VerdictStep);
    self.* = .{
        .step = .init(.{
            .id = .custom,
            .name = "verdict",
            .owner = owner,
            .makeFn = make,
        }),
        .log = log,
        .required_substrings = owner.dupeStrings(required_substrings),
        .expect_boot = expect_boot,
    };

    self.step.dependOn(&run.step);
    log.addStepDependencies(&self.step);
    return self;
}

fn make(step: *Step, options: Step.MakeOptions) !void {
    const b = step.owner;
    const io = b.graph.io;
    const self: *VerdictStep = @fieldParentPtr("step", step);

    const node = options.progress_node.start("check test verdict", 1);
    defer node.end();

    const path_raw = try self.log.getPath4(b, step);
    const path = b.pathResolve(&.{ path_raw.root_dir.path orelse ".", path_raw.sub_path });
    const contents: []const u8 = std.Io.Dir.cwd().readFileAlloc(io, path, b.allocator, .limited(16 * 1024 * 1024)) catch |e| blk: {
        // QEMU's `-debugcon file:...` chardev is created lazily on first
        // guest write; firmware that rejects a boot before the guest ever
        // touches that I/O port means the file never gets created at all.
        // That's a valid (expected) signal for the rejection case, not an
        // error so we treat it as empty output. For the expect-a-pass case, a
        // missing log is still a real failure.
        if (!self.expect_boot and e == error.FileNotFound) break :blk "";
        return step.fail("unable to read QEMU log '{s}': {t}", .{ path, e });
    };

    if (!self.expect_boot) {
        if (hasPassedLine(contents) or std.mem.find(u8, contents, "test_runner") != null) {
            return step.fail(
                "expected firmware to REJECT this boot, but the kernel produced output " ++
                    "(Secure Boot bypass?)\n--- log ---\n{s}",
                .{contents},
            );
        }
        return;
    }

    if (!hasPassedLine(contents)) {
        return step.fail(
            "QEMU log '{s}' does not contain 'ALL <N> TEST(S) PASSED': boot likely " ++
                "crashed or the kernel hung before the test runner finished\n--- log tail ---\n{s}",
            .{ path, tail(contents, 4096) },
        );
    }

    for (self.required_substrings) |needle| {
        if (std.mem.find(u8, contents, needle) == null) {
            return step.fail("QEMU log '{s}' is missing required substring '{s}'", .{ path, needle });
        }
    }
}

/// Hand-scans for "ALL <digits> TEST(S) PASSED".
fn hasPassedLine(contents: []const u8) bool {
    const marker = "ALL ";
    var idx: usize = 0;
    while (std.mem.findPos(u8, contents, idx, marker)) |start| {
        var i = start + marker.len;
        var saw_digit = false;
        while (i < contents.len and std.ascii.isDigit(contents[i])) : (i += 1) saw_digit = true;
        if (saw_digit and std.mem.startsWith(u8, contents[i..], " TEST(S) PASSED")) return true;
        idx = start + marker.len;
    }
    return false;
}

fn tail(contents: []const u8, max: usize) []const u8 {
    if (contents.len <= max) return contents;
    return contents[contents.len - max ..];
}
