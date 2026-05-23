//! Resolved build-time options shared across all build graph construction.
//!
//! Construct once via `Options.get` and pass through to all subsystems.
const Options = @This();

const std = @import("std");
const Bundle = @import("Bundle.zig");
const EmulatorOptions = @import("options/EmulatorOptions.zig");
const FilesystemOptions = @import("options/FilesystemOptions.zig");

const ArchModules = std.AutoHashMapUnmanaged(Bundle.Architecture, *std.Build.Module);

/// Absolute path to the build root with a trailing separator.
root_path: []const u8,

/// Optimisation mode for all Zig compilations.
optimize: std.builtin.OptimizeMode,

/// Options for the QEMU emulator for testing.
emulator: EmulatorOptions,

/// Options for the filesystem
filesystem: FilesystemOptions,

/// Kernel log level, if overridden.
log_level: ?LogLevel,

/// Parsed comma-separated scope matchers. See `Options.get` for wildcard rules.
log_scopes: []const []const u8,

/// Kernel options module with the supplied kernel options availabe.
kernel_options: *std.Build.Module,

/// Kernel options module with all debug features enabled; used for the check step
/// in order to ensure that as many code paths as possible are hit.
///
/// This is mainly forcing debug and verbose log scopes to always be enabled but
/// may be used for more testing in the future.
debug_kernel_options: *std.Build.Module,

/// Per-architecture options modules exposing `arch` and CPU model.
arch_modules: ArchModules,

/// Options module exposing `is_internal = true`.
internal_detection_module: *std.Build.Module,

/// Options module exposing `is_internal = false`.
external_detection_module: *std.Build.Module,

pub const LogLevel = enum { debug, verbose };

pub fn get(b: *std.Build, version: std.SemanticVersion, architectures: []const Bundle.Architecture) !Options {
    const root_path = b.fmt("{s}" ++ std.fs.path.sep_str, .{
        b.build_root.path orelse @panic("build root has no filesystem path!"),
    });

    const log_level = b.option(LogLevel, "log_level", "Kernel log level");
    const log_scopes = try parseLogScopes(b);
    const version_string = buildVersionString(b, version, root_path);

    return .{
        .optimize = b.standardOptimizeOption(.{}),
        .emulator = EmulatorOptions.get(b),
        .filesystem = FilesystemOptions.get(b),
        .root_path = root_path,
        .log_level = log_level,
        .log_scopes = log_scopes,
        .arch_modules = try buildArchModules(b, architectures),
        .kernel_options = buildKernelOptionsModule(b, log_level, log_scopes, version_string),
        .debug_kernel_options = buildKernelOptionsModule(b, .verbose, &.{}, version_string),
        .internal_detection_module = detectionModule(b, .internal),
        .external_detection_module = detectionModule(b, .external),
    };
}

fn parseLogScopes(b: *std.Build) ![]const []const u8 {
    // Wildcard rules: `+scope+` contains, `+scope` ends with, `scope+` starts with, `scope` exact.
    const raw = b.option(
        []const u8,
        "log_scopes",
        "Comma-separated kernel log scope matchers ('+' as prefix/suffix wildcard)",
    ) orelse return &.{};

    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, ',');
    while (it.next()) |scope| {
        if (scope.len != 0)
            try list.append(b.allocator, scope);
    }

    return try list.toOwnedSlice(b.allocator);
}

fn detectionModule(b: *std.Build, context: Bundle.Context) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption(bool, "is_internal", context == .internal);

    return opts.createModule();
}

fn buildArchModules(b: *std.Build, architectures: []const Bundle.Architecture) !ArchModules {
    var map: ArchModules = .empty;
    try map.ensureTotalCapacity(b.allocator, @intCast(architectures.len));

    for (architectures) |architecture| {
        const opts = b.addOptions();
        opts.addOption(Bundle.Architecture, "architecture", architecture);
        map.putAssumeCapacityNoClobber(architecture, opts.createModule());
    }

    return map;
}

fn buildKernelOptionsModule(
    b: *std.Build,
    log_level: ?LogLevel,
    log_scopes: []const []const u8,
    version_string: []const u8,
) *std.Build.Module {
    const opts = b.addOptions();
    opts.addOption([]const u8, "innigkeit_version", version_string);
    if (log_level) |level| opts.addOption(LogLevel, "log_level", level);
    opts.addOption([]const []const u8, "log_scopes", log_scopes);
    return opts.createModule();
}

fn buildVersionString(b: *std.Build, version: std.SemanticVersion, root_path: []const u8) []const u8 {
    const base = b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
    var exit_code: u8 = undefined;
    const raw = b.runAllowFail(&.{
        "git",      "-C",      root_path, "--git-dir", ".git",
        "describe", "--match", "*.*.*",   "--tags",    "--abbrev=9",
    }, &exit_code, .ignore) catch return b.fmt("{s}-unknown", .{base});
    const desc = std.mem.trim(u8, raw, " \n\r");
    return switch (std.mem.count(u8, desc, "-")) {
        0 => blk: {
            if (!std.mem.eql(u8, desc, base))
                std.debug.panic("build version '{s}' does not match git tag '{s}'!", .{ base, desc });
            break :blk base;
        },
        2 => blk: {
            var it = std.mem.splitScalar(u8, desc, '-');
            const ancestor_str = it.next() orelse unreachable;
            const height = it.next() orelse unreachable;
            const id = it.next() orelse unreachable;
            const ancestor = std.SemanticVersion.parse(ancestor_str) catch
                std.debug.panic("could not parse ancestor version from git describe: {s}!", .{desc});
            if (version.order(ancestor) != .gt)
                std.debug.panic("build version '{}' must be greater than tagged ancestor '{}'!", .{ version, ancestor });
            if (id.len < 2 or id[0] != 'g')
                std.debug.panic("unexpected git describe output: {s}!", .{desc});
            break :blk b.fmt("{s}-dev.{s}+{s}", .{ base, height, id[1..] });
        },
        else => blk: {
            std.debug.print("warning: unexpected git describe output: {s}\n", .{desc});
            break :blk base;
        },
    };
}
