//! Host-platform detection for the emulator/signing build steps: locating
//! the QEMU binary and firmware blobs that actually work on this host,
//! independent of (and preferred over) the vendored `edk2` zig-package
//! firmware and any bundled `.tools/qemu` build.

const Bundle = @import("Bundle.zig");
const configure_deps = @import("configure_deps.zig");
const std = @import("std");

/// Resolve the QEMU binary for `arch`: a locally built copy in
/// `.tools/qemu/bin/` if one exists, otherwise the bare name, which the run
/// step resolves on the host PATH when it executes. Deliberately not a
/// configure-time PATH search: that would poison the configuration cache.
pub fn findQemuBinary(b: *std.Build, arch: Bundle.Architecture) []const u8 {
    const name = switch (arch) {
        .arm => "qemu-system-aarch64",
        .riscv => "qemu-system-riscv64",
        .x64 => "qemu-system-x86_64",
    };
    const bundled = b.pathJoin(&.{ ".tools", "qemu", "bin", name });
    return if (pathExists(b, bundled)) bundled else name;
}

pub const FirmwarePaths = struct {
    code: []const u8,
    vars: []const u8,
};

/// Host-distro UEFI firmware for arm: the vendored `edk2` zig-package
/// aarch64 firmware wedges in SEC on real QEMU (see docs/arm-port.md),
/// while host-packaged AAVMF boots correctly. Returns null if not found,
/// in which case the caller falls back to the vendored dependency (with a
/// printed warning) rather than hard-failing.
pub fn hostFirmware(b: *std.Build, arch: Bundle.Architecture) ?FirmwarePaths {
    if (arch != .arm) return null;
    return switch (b.graph.host.result.os.tag) {
        .linux => found: {
            const code = "/usr/share/AAVMF/AAVMF_CODE.fd";
            const vars = "/usr/share/AAVMF/AAVMF_VARS.fd";
            if (!pathExists(b, code) or !pathExists(b, vars)) break :found null;
            break :found .{ .code = code, .vars = vars };
        },
        .macos => found: {
            const qemu_bin = b.findProgram(.{ .names = &.{"qemu-system-aarch64"} }) orelse break :found null;
            const bin_dir = std.Io.Dir.path.dirname(qemu_bin) orelse break :found null;
            const prefix = std.Io.Dir.path.dirname(bin_dir) orelse break :found null;
            const code = b.pathJoin(&.{ prefix, "share", "qemu", "edk2-aarch64-code.fd" });
            const vars = b.pathJoin(&.{ prefix, "share", "qemu", "edk2-arm-vars.fd" });
            if (!pathExists(b, code) or !pathExists(b, vars)) break :found null;
            break :found .{ .code = code, .vars = vars };
        },
        else => null,
    };
}

/// UEFI Secure Boot-capable firmware (own PK/KEK/db enrollment) for the
/// `-Dsecboot=true` verify path.
pub fn secbootFirmware(b: *std.Build) ?FirmwarePaths {
    return switch (b.graph.host.result.os.tag) {
        .linux => found: {
            const code = "/usr/share/OVMF/OVMF_CODE_4M.secboot.fd";
            const vars = "/usr/share/OVMF/OVMF_VARS_4M.fd";
            if (!pathExists(b, code) or !pathExists(b, vars)) return null;
            break :found .{ .code = code, .vars = vars };
        },
        .macos => found: {
            const qemu_bin = b.findProgram(.{ .names = &.{"qemu-system-aarch64"} }) orelse break :found null;
            const bin_dir = std.Io.Dir.path.dirname(qemu_bin) orelse break :found null;
            const prefix = std.Io.Dir.path.dirname(bin_dir) orelse break :found null;
            const code = b.pathJoin(&.{ prefix, "share", "qemu", "edk2-x86_64-secure-code.fd" });
            const vars = b.pathJoin(&.{ prefix, "share", "qemu", "edk2-i386-vars.fd" });
            if (!pathExists(b, code) or !pathExists(b, vars)) break :found null;
            break :found .{ .code = code, .vars = vars };
        },
        else => null,
    };
}

/// Whether `name` resolves on the host PATH (or common install prefixes).
/// Used to gate `-Dtpm=true`/`-Dsecboot=true` with a clear message instead
/// of a cryptic subprocess failure when a required tool is missing.
pub fn hasTool(b: *std.Build, name: []const u8) bool {
    return b.findProgram(.{ .names = &.{name} }) != null;
}

/// Configure-time existence probe, tracked as a configuration dependency
/// rather than poisoning the cache.
fn pathExists(b: *std.Build, path: []const u8) bool {
    return configure_deps.track(b, path, .file_metadata);
}
