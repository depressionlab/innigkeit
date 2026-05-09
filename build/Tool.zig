//! Resolved host build tool, ready to be run as part of the build graph.
//!
//! Tools are host-native executables invoked during the build. They are
//! constructed by `Tool.getTools` from declarations in `tools/root.zig`.
const Tool = @This();

const std = @import("std");
const Step = std.Build.Step;
const Library = @import("Library.zig");
const ToolDescription = @import("ToolDescription.zig");
const Wrapper = @import("Wrapper.zig");

pub const Collection = std.array_hash_map.String(Tool);

name: []const u8,

/// Compiled with the user-requested optimize mode.
normal_exe: *Step.Compile,

/// Compiled with `.ReleaseSafe`. Equal to `normal_exe` when the user already requested `.ReleaseSafe`.
release_safe_exe: *Step.Compile,

test_exe: *Step.Compile,

/// Installs the artifact produced by `normal_exe`
exe_install_step: *Step,

/// Resolves all tools and their dependencies.
pub fn getTools(
    b: *std.Build,
    wrapper: Wrapper,
    libraries: Library.Collection,
    optimize: std.builtin.OptimizeMode,
) !Tool.Collection {
    const descriptions: []const ToolDescription = @import("../tools/root.zig").tools;

    var tools: Tool.Collection = .empty;
    try tools.ensureTotalCapacity(b.allocator, descriptions.len);

    for (descriptions) |description| {
        tools.putAssumeCapacityNoClobber(description.name, try resolveTool(
            b,
            wrapper,
            libraries,
            description,
            optimize,
        ));
    }

    return tools;
}

fn resolveTool(
    b: *std.Build,
    wrapper: Wrapper,
    libraries: Library.Collection,
    description: ToolDescription,
    optimize: std.builtin.OptimizeMode,
) !Tool {
    const dependencies = try Library.resolveDeps(
        b,
        libraries,
        description.name,
        description.dependencies,
    );
    const lazy_path = b.path(b.pathJoin(&.{
        "tools",
        description.name,
        b.fmt("{s}.zig", .{description.name}),
    }));

    const normal_module = createModule(
        b,
        &description,
        lazy_path,
        optimize,
        dependencies,
    );
    const normal_exe = b.addExecutable(.{
        .name = description.name,
        .root_module = normal_module,
    });

    wrapper.registerCheck(b.addExecutable(.{
        .name = b.fmt("{s}_check", .{description.name}),
        .root_module = normal_module,
    }));

    const release_safe_exe = if (optimize == .ReleaseSafe)
        normal_exe
    else
        b.addExecutable(.{
            .name = description.name,
            .root_module = createModule(
                b,
                &description,
                lazy_path,
                .ReleaseSafe,
                dependencies,
            ),
        });

    const install = b.addInstallArtifact(normal_exe, .{
        .dest_dir = .{ .override = .{
            .custom = b.pathJoin(&.{ "tools", description.name }),
        } },
    });

    const build_step = b.step(
        b.fmt("{s}_build", .{description.name}),
        b.fmt("Build the {s} tool", .{description.name}),
    );
    build_step.dependOn(&install.step);

    const test_exe = b.addTest(.{
        .name = b.fmt("{s}_test", .{description.name}),
        .root_module = normal_module,
    });

    wrapper.registerCheck(b.addTest(.{
        .name = b.fmt("{s}_test_check", .{description.name}),
        .root_module = normal_module,
    }));

    const test_install = b.addInstallArtifact(test_exe, .{
        .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{ "tools", description.name }) } },
    });

    const run_test = b.addRunArtifact(test_exe);
    run_test.step.dependOn(&test_install.step);

    const test_step = b.step(
        b.fmt("{s}_test", .{description.name}),
        b.fmt("Run tests for {s}", .{description.name}),
    );
    test_step.dependOn(&run_test.step);

    wrapper.registerTool(build_step, test_step);

    // Top-level run step: `zig build {name} -- <args>`.
    const run = b.addRunArtifact(normal_exe);
    run.step.dependOn(&install.step);
    if (b.args) |args| run.addArgs(args);
    b.step(
        description.name,
        b.fmt("Run {s}", .{description.name}),
    ).dependOn(&run.step);

    return .{
        .name = description.name,
        .normal_exe = normal_exe,
        .release_safe_exe = release_safe_exe,
        .test_exe = test_exe,
        .exe_install_step = &install.step,
    };
}

fn createModule(
    b: *std.Build,
    desc: *const ToolDescription,
    root_source_file: std.Build.LazyPath,
    optimize: std.builtin.OptimizeMode,
    dependencies: []const *const Library,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = b.graph.host,
        .optimize = optimize,
        .sanitize_c = switch (optimize) {
            .Debug => .full,
            .ReleaseSafe, .ReleaseSmall => .trap,
            .ReleaseFast => .off,
        },
    });

    module.addImport(desc.name, module);

    for (dependencies) |dep| {
        module.addImport(dep.name, dep.external_module_for_host orelse std.debug.panic(
            "tool '{s}' depends on '{s}' which does not support the host architecture!",
            .{ desc.name, dep.name },
        ));
    }

    switch (desc.configuration) {
        .simple => {},
        .link_c => module.link_libc = true,
        .custom => |f| f(b, desc, module),
    }

    return module;
}
