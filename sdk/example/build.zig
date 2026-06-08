//! Build script for an out-of-tree Innigkeit application.
//!
//! This is the complete build file for an app that lives outside the Innigkeit
//! monorepo. The SDK handles target setup, library imports, and signing.
//!
//! To build:
//!   1. Generate a keypair (once):
//!        cd /path/to/innigkeit && zig build codesign -- keygen
//!        cp keys/codesign_private.key /path/to/this/project/keys/
//!   2. Build:
//!        zig build

const std = @import("std");
const sdk = @import("innigkeit_sdk");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const app = sdk.createApp(b, .{
        .name = "innigkeit_hello",
        .root = b.path("src/main.zig"),
        .manifest = b.path("manifest.toml"),
        .optimize = optimize,
    });

    // Install the ELF and its signed sidecar.
    b.installArtifact(app.exe);
    const install_sig = b.addInstallFile(app.codesig, "bin/innigkeit_hello.codesig");
    b.getInstallStep().dependOn(&install_sig.step);
}
