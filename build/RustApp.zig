//! Builds a Rust `no_std` crate from the repository workspace for
//! `x86_64-unknown-none` and returns the output ELF so it can be
//! embedded in the kernel's initfs archive.
const std = @import("std");

name: []const u8,
binary: std.Build.LazyPath,
step: *std.Build.Step,

/// Build a workspace member by package name.
///
/// Cargo writes into a fixed directory in the local cache (not a `Run` output
/// directory, which would be fresh every time) so its incremental state
/// survives between builds. The step has side effects, so it always runs;
/// cargo itself no-ops when nothing changed.
pub fn build(b: *std.Build, build_helper: *std.Build.Step.Compile, name: []const u8) !@This() {
    const cargo = b.addSystemCommand(&.{ "cargo", "build" });
    cargo.addArg("--release");

    const manifest_path = b.pathResolve(&.{try b.root.joinString(b.allocator, "Cargo.toml")});
    cargo.addArgs(&.{ "--manifest-path", manifest_path });
    cargo.addArgs(&.{ "--package", name });
    cargo.addArgs(&.{ "--target", target });
    cargo.has_side_effects = true;
    cargo.step.dependOn(&targetCheck(b, build_helper).step);

    const target_dir = std.Build.LazyPath.cache_root.path(b, "cargo-target");
    cargo.addDirectoryArg2(target_dir, .{ .prefix = "--target-dir=" });

    return .{
        .name = name,
        .binary = target_dir.path(b, b.fmt("{s}/release/{s}", .{ target, name })),
        .step = &cargo.step,
    };
}

const target = "x86_64-unknown-none";

/// One check per build invocation, shared by every cargo step. Runs at make
/// time so the configuration stays pure and the answer is never stale.
fn targetCheck(b: *std.Build, build_helper: *std.Build.Step.Compile) *std.Build.Step.Run {
    const Cache = struct {
        var run: ?*std.Build.Step.Run = null;
    };
    if (Cache.run) |run| return run;
    const run = b.addRunArtifact(build_helper);
    run.setName("check rust target");
    run.addArgs(&.{ "require-rust-target", target });
    run.has_side_effects = true;
    Cache.run = run;
    return run;
}
