//! Resolved userspace application, ready to be embedded in the kernel or run on the host.
//!
//! Applications are constructed by `App.getApps` from declarations in `apps/root.zig`.
//! Each app produces two sets of executables per architecture: one targeting Innigkeit
//! (`internal`) and one targeting the host OS (`external`).
const App = @This();

const std = @import("std");
const AppDescription = @import("AppDescription.zig");
const Bundle = @import("Bundle.zig");
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const Wrapper = @import("Wrapper.zig");

/// Map from `Bundle` (architecture + context) to compiled executable.
const Executables = std.AutoHashMapUnmanaged(Bundle, *std.Build.Step.Compile);
pub const Collection = std.array_hash_map.String(App);

name: []const u8,

/// Executables for each suported Innigkeit bundle target.
executables: Executables,

/// Resolves all registered applications and their dependencies.
pub fn getApps(
    b: *std.Build,
    wrapper: Wrapper,
    libraries: Library.Collection,
    options: Options,
    architectures: []const Bundle.Architecture,
) !App.Collection {
    const descriptions: []const AppDescription = @import("../apps/root.zig").apps;

    var apps: App.Collection = .empty;
    try apps.ensureTotalCapacity(b.allocator, descriptions.len);

    for (descriptions) |description| {
        const app = try resolveApp(
            b,
            wrapper,
            libraries,
            description,
            options,
            architectures,
        );
        apps.putAssumeCapacityNoClobber(app.name, app);
    }

    return apps;
}

fn resolveApp(
    b: *std.Build,
    wrapper: Wrapper,
    libraries: Library.Collection,
    description: AppDescription,
    options: Options,
    architectures: []const Bundle.Architecture,
) !App {
    const deps = try Library.resolveDeps(
        b,
        libraries,
        description.name,
        description.dependencies,
    );
    const lazy_path = b.path(b.pathJoin(&.{ "apps", description.name, "main.zig" }));

    const all_tests_step = b.step(
        b.fmt("{s}_test", .{description.name}),
        b.fmt("Build and run tests for {s} on all architectures", .{description.name}),
    );

    var executables: Executables = .empty;

    for (architectures) |architecture| {
        // External (host-targeting) executable and tests.
        {
            const bundle: Bundle = .{
                .architecture = architecture,
                .context = .external,
            };
            const module = try createModule(
                b,
                description,
                lazy_path,
                options,
                bundle,
                deps,
            );
            const exe = b.addExecutable(.{
                .name = description.name,
                .root_module = module,
            });
            if (description.use_llvm) exe.use_llvm = true;
            try executables.putNoClobber(b.allocator, bundle, exe);

            const install = b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{
                    @tagName(architecture), "application", "external",
                }) } },
            });
            b.step(
                b.fmt("{s}_build_host_{s}", .{ description.name, @tagName(architecture) }),
                b.fmt("Build {s} for {s} targeting the host os", .{ description.name, @tagName(architecture) }),
            ).dependOn(&install.step);

            wrapper.registerCheck(b.addExecutable(.{
                .name = b.fmt("{s}_host_check", .{description.name}),
                .root_module = module,
            }));

            const test_exe = b.addTest(.{
                .name = description.name,
                .root_module = try createModule(
                    b,
                    description,
                    lazy_path,
                    options,
                    bundle,
                    deps,
                ),
            });
            if (description.use_llvm) test_exe.use_llvm = true;
            const test_install = b.addInstallArtifact(test_exe, .{
                .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{
                    @tagName(architecture), "application", "tests", "external",
                }) } },
            });
            const run_test = b.addRunArtifact(test_exe);
            run_test.skip_foreign_checks = true;
            run_test.failing_to_execute_foreign_is_an_error = false;
            run_test.step.dependOn(&test_install.step);

            const test_step = b.step(
                b.fmt("{s}_test_host_{s}", .{ description.name, @tagName(architecture) }),
                b.fmt("Run tests for {s} on {s} targeting the host os", .{ description.name, @tagName(architecture) }),
            );
            test_step.dependOn(&run_test.step);
            all_tests_step.dependOn(test_step);
            wrapper.registerExternalApp(architecture, test_step);
        }

        // Internal (Innigkeit-targeting) executable.
        {
            const bundle: Bundle = .{
                .architecture = architecture,
                .context = .internal,
            };
            const module = try createModule(
                b,
                description,
                lazy_path,
                options,
                bundle,
                deps,
            );
            const exe = b.addExecutable(.{
                .name = description.name,
                .root_module = module,
            });
            if (description.use_llvm) exe.use_llvm = true;
            try executables.putNoClobber(b.allocator, bundle, exe);

            const install = b.addInstallArtifact(exe, .{ .dest_dir = .{
                .override = .{ .custom = b.pathJoin(&.{
                    @tagName(architecture), "application",
                }) },
            } });
            const build_step = b.step(
                b.fmt("{s}_build_{s}", .{ description.name, @tagName(architecture) }),
                b.fmt("Build {s} for {s} targeting Innigkeit", .{ description.name, @tagName(architecture) }),
            );
            build_step.dependOn(&install.step);
            wrapper.registerInternalApp(architecture, build_step);

            wrapper.registerCheck(b.addExecutable(.{
                .name = b.fmt("{s}_innigkeit_check", .{description.name}),
                .root_module = module,
            }));

            all_tests_step.dependOn(&exe.step);
        }
    }

    // Top-level run step for the host-native architecture.
    const native_bundle = Bundle.forHost(b);
    if (executables.get(native_bundle)) |host_exe| {
        const install = b.addInstallArtifact(host_exe, .{
            .dest_dir = .{ .override = .{
                .custom = b.pathJoin(&.{
                    @tagName(native_bundle.architecture), "application", "external",
                }),
            } },
        });
        if (description.use_llvm) host_exe.use_llvm = true;
        const run = b.addRunArtifact(host_exe);
        run.step.dependOn(&install.step);
        b.step(description.name, b.fmt(
            "Run {s} targeting the host os",
            .{description.name},
        )).dependOn(&run.step);
    }

    return .{
        .name = description.name,
        .executables = executables,
    };
}

fn createModule(
    b: *std.Build,
    desc: AppDescription,
    root_source_file: std.Build.LazyPath,
    options: Options,
    bundle: Bundle,
    dependencies: []const *const Library,
) !*std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = root_source_file,
        .target = bundle.resolveTarget(b),
        .optimize = options.optimize,
        .sanitize_c = .off, // TODO: enable based on whether any C is linked
    });

    module.addImport(desc.name, module);
    module.addImport("is_internal", switch (bundle.context) {
        .internal => options.internal_detection_module,
        .external => options.external_detection_module,
    });

    for (dependencies) |dep| {
        module.addImport(dep.name, switch (bundle.context) {
            .internal => dep.internal_modules.get(bundle.architecture) orelse unreachable,
            .external => dep.external_modules.get(bundle.architecture) orelse unreachable,
        });
    }

    switch (desc.configuration) {
        .simple => {},
        .link_c => module.link_libc = true,
        .custom => |f| try f(b, bundle, module),
    }

    return module;
}
