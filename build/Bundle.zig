//! A build target: which architecture to compile for, and whether the binary
//! runs inside Innigkeit (`internal`) or on the host OS (`external`).
//!
//! The `internal`/`external` distinction drives both target selection
//! (bare-metal vs native/cross) and test-runner behaviour (emulated vs direct).
const Bundle = @This();

const std = @import("std");

architecture: Architecture,
context: Context,

/// Returns a host-native external bundle, or panics if the host CPU is unsupported.
pub fn forHost(b: *std.Build) Bundle {
    return .{ .architecture = Architecture.fromHost(b), .context = .external };
}

/// Resolves this bundle to a Zig build target.
///
/// `.internal` targets freestanding with an explicit CPU model.
/// `.external` targets the host natively when the architecture matches,
/// or cross-compiles otherwise.
pub fn resolveTarget(self: Bundle, b: *std.Build) std.Build.ResolvedTarget {
    return switch (self.context) {
        .internal => self.architecture.kernelTarget(b),
        .external => if (self.architecture.isNative(b))
            b.resolveTargetQuery(.{})
        else switch (self.architecture) {
            .arm => b.resolveTargetQuery(.{ .cpu_arch = .aarch64 }),
            .riscv => b.resolveTargetQuery(.{ .cpu_arch = .riscv64 }),
            .x64 => b.resolveTargetQuery(.{ .cpu_arch = .x86_64 }),
        },
    };
}

pub const Context = enum { internal, external };

pub const Architecture = enum {
    arm,
    riscv,
    x64,

    /// Returns the host architecture, or panics if it is not a supported target.
    pub fn fromHost(b: *std.Build) Architecture {
        return switch (b.graph.host.result.cpu.arch) {
            .aarch64 => .arm,
            .riscv64 => .riscv,
            .x86_64 => .x64,
            else => |arch| std.debug.panic(
                "unsupported host architecture: {}!",
                .{arch},
            ),
        };
    }

    /// Returns true if this architecture matches the host CPU.
    pub fn isNative(self: Architecture, b: *std.Build) bool {
        return self == fromHost(b);
    }

    /// Returns the freestanding cross-compilation target used for kernel builds.
    pub fn kernelTarget(self: Architecture, b: *std.Build) std.Build.ResolvedTarget {
        return switch (self) {
            .arm => b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.generic },
                .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .neon, .fp_armv8 }),
                .cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align}),
            }),
            .riscv => b.resolveTargetQuery(.{
                .cpu_arch = .riscv64,
                .os_tag = .freestanding,
                .abi = .none,
                .cpu_model = .{ .explicit = &std.Target.riscv.cpu.baseline_rv64 },
                .cpu_features_add = std.Target.riscv.featureSet(&.{ .zicsr, .zihintpause }),
            }),
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
        };
    }
};
