//! Builds a Rust `no_std` crate from the repository workspace for
//! `x86_64-unknown-none` and returns the output ELF so it can be
//! embedded in the kernel's initfs archive.
const std = @import("std");

pub const RustApp = struct {
    name: []const u8,
    binary_path: []const u8,
    step: *std.Build.Step,
};

/// Build a workspace member by package name.
///
/// `name` is both the Cargo package name and the initfs entry name.
/// `crate_dir` is accepted for compatibility but unused (workspace controls the build).
pub fn build(b: *std.Build, name: []const u8, crate_dir: []const u8) RustApp {
    _ = crate_dir;
    const workspace_manifest = b.path("Cargo.toml").getPath(b);

    const cargo = b.addSystemCommand(&.{
        "cargo",           "build",            "--release",
        "--manifest-path", workspace_manifest, "--package",
        name,              "--target",         "x86_64-unknown-none",
    });
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
