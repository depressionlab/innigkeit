//! Builds a Rust `no_std` crate from the repository workspace for
//! `x86_64-unknown-none` and returns the output ELF so it can be
//! embedded in the kernel's initfs archive.
const std = @import("std");

name: []const u8,
binary_path: []const u8,
step: *std.Build.Step,

/// Build a workspace member by package name.
pub fn build(b: *std.Build, name: []const u8) !@This() {
    checkTargetInstallation(b); // TODO: cache this result

    const cargo = b.addSystemCommand(&.{ "cargo", "build" });
    cargo.addArg("--release");

    const manifest_path_raw = try b.path("Cargo.toml").getPath4(b, b.default_step);
    const manifest_path = b.pathResolve(&.{ manifest_path_raw.root_dir.path orelse ".", manifest_path_raw.sub_path });
    cargo.addArgs(&.{ "--manifest-path", manifest_path });
    cargo.addArgs(&.{ "--package", name });
    cargo.addArgs(&.{ "--target", "x86_64-unknown-none" });
    cargo.has_side_effects = true;

    cargo.setEnvironmentVariable(
        "CARGO_TARGET_DIR",
        b.fmt("{s}/cargo-target", .{b.install_path}),
    );

    const binary_path = b.fmt(
        "{s}/cargo-target/x86_64-unknown-none/release/{s}",
        .{ b.install_path, name },
    );

    return .{
        .name = name,
        .binary_path = binary_path,
        .step = &cargo.step,
    };
}

/// Checked once per build invocation.
var checked_target_installation = false;

fn checkTargetInstallation(b: *std.Build) void {
    if (checked_target_installation) return;
    checked_target_installation = true;

    var exit_code: u8 = undefined;
    const sysroot_raw = b.runAllowFail(
        &.{ "rustc", "--print", "sysroot" },
        &exit_code,
        .ignore,
    ) catch return;
    const sysroot = std.mem.trim(u8, sysroot_raw, " \n\r");
    const rustlib_dir = b.pathJoin(&.{ sysroot, "lib", "rustlib", "x86_64-unknown-none", "lib" });
    std.Io.Dir.accessAbsolute(b.graph.io, rustlib_dir, .{}) catch std.debug.panic(
        "the 'x86_64-unknown-none' Rust target is not installed (checked '{s}'). run `rustup target add x86_64-unknown-none` before building Rust apps",
        .{rustlib_dir},
    );
}
