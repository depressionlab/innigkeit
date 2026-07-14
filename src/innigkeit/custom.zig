const std = @import("std");

const Bundle = @import("../../build/Bundle.zig");
const Options = @import("../../build/Options.zig");

pub fn custom(
    b: *std.Build,
    architecture: Bundle.Architecture,
    module: *std.Build.Module,
    options: Options,
    is_check: bool,
) !void {
    // kernel options
    if (is_check) {
        module.addImport("kernel_options", options.debug_kernel_options);
    } else {
        module.addImport("kernel_options", options.kernel_options);
    }

    // Codesign public key: read from keys/codesign_public.key at build time.
    // Falls back to an all-zero key if the file is absent (acceptable in debug
    // builds where enforce_code_signing is off).
    {
        const io = b.graph.io;
        const codesign_opts = b.addOptions();
        const key_bytes = b.build_root.handle.readFileAlloc(
            io,
            "keys/codesign_public.key",
            b.allocator,
            .limited(64),
        ) catch |err| blk: {
            if (err != error.FileNotFound)
                std.debug.print("warning: could not read keys/codesign_public.key: {s}\n", .{@errorName(err)});
            break :blk try b.allocator.alloc(u8, 32);
        };
        defer b.allocator.free(key_bytes);
        const default_key: [32]u8 = if (key_bytes.len >= 32) key_bytes[0..32].* else [_]u8{0} ** 32;
        codesign_opts.addOption([32]u8, "default_public_key", default_key);
        module.addImport("codesign_key_options", codesign_opts.createModule());
    }

    // uacpi
    {
        // in uACPI DEBUG is more verbose than TRACE
        const uacpi_log_level: []const u8 = blk: {
            if (options.log_level) |log_level|
                break :blk switch (log_level) {
                    .debug => "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_TRACE",
                    .verbose => "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_DEBUG",
                };

            for (options.log_scopes) |scope| {
                if (std.mem.eql(u8, scope, "uacpi"))
                    break :blk "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_DEBUG";
            }

            break :blk "-DUACPI_DEFAULT_LOG_LEVEL=UACPI_LOG_WARN";
        };

        const uacpi_dep = b.dependency("uacpi", .{});

        module.addIncludePath(uacpi_dep.path("include"));
        module.addCSourceFiles(.{
            .root = uacpi_dep.path("source"),
            .files = &.{
                "default_handlers.c",
                "event.c",
                "interpreter.c",
                "io.c",
                "mutex.c",
                "namespace.c",
                "notify.c",
                "opcodes.c",
                "opregion.c",
                "osi.c",
                "registers.c",
                "resources.c",
                "shareable.c",
                "sleep.c",
                "stdlib.c",
                "tables.c",
                "types.c",
                "uacpi.c",
                "utilities.c",
            },
            .flags = &.{
                uacpi_log_level,
                "-DUACPI_SIZED_FREES=1",
            },
        });

        const translator = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("uacpi_api.h",
                \\#include <uacpi/event.h>
                \\#include <uacpi/io.h>
                \\#include <uacpi/namespace.h>
                \\#include <uacpi/notify.h>
                \\#include <uacpi/opregion.h>
                \\#include <uacpi/osi.h>
                \\#include <uacpi/registers.h>
                \\#include <uacpi/resources.h>
                \\#include <uacpi/sleep.h>
                \\#include <uacpi/status.h>
                \\#include <uacpi/tables.h>
                \\#include <uacpi/types.h>
                \\#include <uacpi/uacpi.h>
                \\#include <uacpi/utilities.h>
            ),
            .target = architecture.kernelTarget(b),
            .optimize = options.optimize,
            .link_libc = false,
        });
        translator.addIncludePath(uacpi_dep.path("include"));
        module.addImport("uacpi", translator.createModule());
    }

    // devicetree
    module.addImport("DeviceTree", b.dependency("devicetree", .{}).module("DeviceTree"));

    // flanterm
    {
        const flanterm_src = b.dependency("flanterm", .{}).path("src");

        module.addIncludePath(flanterm_src);
        module.addCSourceFiles(.{
            .root = flanterm_src,
            .files = &.{
                "flanterm.c",
                "flanterm_backends/fb.c",
            },
            // we use the kernel heap instead of the bump allocator
            .flags = &.{"-DFLANTERM_FB_DISABLE_BUMP_ALLOC=1"},
        });

        const translator = b.addTranslateC(.{
            .root_source_file = b.addWriteFiles().add("flanterm_api.h",
                \\#include <flanterm.h>
                \\#include <flanterm_backends/fb.h>
            ),
            .target = architecture.kernelTarget(b),
            .optimize = options.optimize,
            .link_libc = false,
        });
        translator.addIncludePath(flanterm_src);
        module.addImport("flanterm", translator.createModule());
    }
}
