//! Innigkeit SDK: Zig build helper for out-of-tree apps.
//!
//! # Usage
//!
//! In your app's `build.zig.zon`:
//! ```zig
//! .dependencies = .{
//!     .innigkeit_sdk = .{
//!         .url = "git+https://github.com/depressionlab/innigkeit#<commit>",
//!         .hash = "<hash>",
//!     },
//! },
//! ```
//!
//! In your app's `build.zig`:
//! ```zig
//! const std = @import("std");
//! const sdk = @import("innigkeit_sdk");
//!
//! pub fn build(b: *std.Build) void {
//!     const app = sdk.createApp(b, .{
//!         .name = "my_app",
//!         .root = b.path("src/main.zig"),
//!         .manifest = b.path("manifest.toml"),
//!     });
//!     b.installArtifact(app.exe);
//! }
//! ```
//!
//! The `manifest.toml` in your project declares your app's entitlements.
//! Run `zig build codesign -- keygen` in the Innigkeit monorepo to generate
//! a signing keypair, then place `keys/codesign_private.key` at the root of
//! your project before building.

const std = @import("std");

/// Options for `createApp`.
pub const CreateOptions = struct {
    /// Application binary name (becomes the ELF file name).
    name: []const u8,
    /// Path to the root source file (`main.zig`).
    root: std.Build.LazyPath,
    /// Path to the `manifest.toml` file declaring entitlements.
    manifest: std.Build.LazyPath,
    /// Target CPU architecture (default: `.x64`).
    arch: Arch = .x64,
    /// Optimize mode (default: `.Debug`).
    optimize: std.builtin.OptimizeMode = .Debug,

    pub const Arch = enum { x64, arm, riscv };
};

/// The result of `createApp`: the compiled ELF and its signed sidecar.
pub const CreatedApp = struct {
    /// Compiled freestanding ELF binary.
    exe: *std.Build.Step.Compile,
    /// Signed `.codesig` sidecar produced by the codesign tool.
    /// Install alongside `exe` so the kernel can verify the binary at spawn.
    codesig: std.Build.LazyPath,
};

/// Wire up an Innigkeit app from an external project's `build.zig`.
///
/// Sets up:
/// - Correct freestanding target (CPU arch, features, ABI)
/// - The `innigkeit` runtime module (syscalls, IPC, net, etc.)
/// - Entry-point boilerplate via the innigkeit prelude
/// - A codesign step that signs the ELF with `manifest.toml`
///
/// Requires:
/// - `innigkeit_sdk` declared as a dependency in the caller's `build.zig.zon`
/// - `keys/codesign_private.key` present in the caller's working directory
pub fn createApp(b: *std.Build, opts: CreateOptions) CreatedApp {
    const sdk = b.dependency("innigkeit_sdk", .{});
    const repo = sdk.builder.dependency("innigkeit", .{});
    const target = resolveTarget(b, opts.arch);

    // Detection module: signals to the innigkeit library that this is a real
    // freestanding build (not a host-side test).
    const is_internal_opts = b.addOptions();
    is_internal_opts.addOption(bool, "is_internal", true);
    const is_internal_mod = is_internal_opts.createModule();

    // innigkeit runtime module: syscall wrappers, threading, IPC, networking...
    const innigkeit_mod = b.createModule(.{
        .root_source_file = repo.path("library/innigkeit/root.zig"),
        .target = target,
        .optimize = opts.optimize,
    });
    innigkeit_mod.addImport("innigkeit", innigkeit_mod);
    innigkeit_mod.addImport("is_internal", is_internal_mod);

    // App module (the developer's own main.zig).
    const app_mod = b.createModule(.{
        .root_source_file = opts.root,
        .target = target,
        .optimize = opts.optimize,
    });
    app_mod.addImport("innigkeit", innigkeit_mod);
    app_mod.addImport(opts.name, app_mod);
    app_mod.addImport("is_internal", is_internal_mod);

    // Prelude wrapper, provides `_start`, default `std_options`, and `panic`.
    // This is the actual `root_source_file`; it imports the developer's code as "app".
    const prelude_mod = b.createModule(.{
        .root_source_file = repo.path("library/innigkeit/prelude.zig"),
        .target = target,
        .optimize = opts.optimize,
    });
    prelude_mod.addImport("app", app_mod);
    prelude_mod.addImport("innigkeit", innigkeit_mod);
    prelude_mod.addImport("is_internal", is_internal_mod);

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = prelude_mod,
    });

    // Codesign step: hash the ELF, parse manifest.toml, sign with the private key.
    const codesign_exe = sdk.artifact("codesign");
    const sign = b.addRunArtifact(codesign_exe);
    sign.addArg("sign");
    sign.addFileArg(exe.getEmittedBin());
    sign.addFileArg(opts.manifest);
    const codesig = sign.addOutputFileArg(b.fmt("{s}.codesig", .{opts.name}));

    return .{ .exe = exe, .codesig = codesig };
}

/// Register the SDK's own artifacts and modules.
pub fn build(b: *std.Build) void {
    const repo = b.dependency("innigkeit", .{});
    const toml_dep = b.dependency("toml", .{});

    // Build the codesign signing tool from the bundled source.
    const codesign = b.addExecutable(.{
        .name = "codesign",
        .root_module = b.createModule(.{
            .root_source_file = b.path("codesign/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    codesign.root_module.addImport("toml", toml_dep.module("toml"));
    // installArtifact registers it so createApp() can find it via sdk.artifact("codesign").
    b.installArtifact(codesign);

    // Expose the innigkeit userspace library as a named module.
    // Consumers get it via: sdk.module("innigkeit")
    _ = b.addModule("innigkeit", .{
        .root_source_file = repo.path("library/innigkeit/root.zig"),
    });
}

fn resolveTarget(b: *std.Build, arch: CreateOptions.Arch) std.Build.ResolvedTarget {
    return switch (arch) {
        .x64 => b.resolveTargetQuery(.{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v2 },
            .cpu_features_sub = std.Target.x86.featureSet(&.{
                .x87,      .mmx,     .sse,      .f16c,     .fma,      .fxsr,
                .sse2,     .sse3,    .sse4_1,   .sse4_2,   .ssse3,    .vzeroupper,
                .avx,      .avx2,    .avx512bw, .avx512cd, .avx512dq, .avx512f,
                .avx512vl, .evex512,
            }),
            .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
        }),
        .arm => b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.generic },
            .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .neon, .fp_armv8 }),
        }),
        .riscv => b.resolveTargetQuery(.{
            .cpu_arch = .riscv64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_model = .{ .explicit = &std.Target.riscv.cpu.baseline_rv64 },
            .cpu_features_add = std.Target.riscv.featureSet(&.{ .zicsr, .zihintpause }),
        }),
    };
}
