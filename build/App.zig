//! Resolved userspace application, ready to be embedded in the kernel or run on the host.
//!
//! Applications are constructed by `App.getApps` from declarations in `apps/root.zig`.
//! Each app produces two sets of executables per architecture: one targeting Innigkeit
//! (`internal`) and one targeting the host OS (`external`).
// zlinter-disable require_errdefer_dealloc - every allocation here goes through b.allocator, an arena for the whole build graph's lifetime; there is no per-allocation free to add.
const App = @This();

const AppDescription = @import("AppDescription.zig");
const Bundle = @import("Bundle.zig");
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const std = @import("std");
const Wrapper = @import("Wrapper.zig");

/// Map from `Bundle` (architecture + context) to compiled executable.
const Executables = std.AutoHashMapUnmanaged(Bundle, *std.Build.Step.Compile);
/// A collection of `App`s, mapped by their names as Strings.
pub const Collection = std.array_hash_map.String(App);

/// The name of the application
name: []const u8,

/// Mirrors `AppDescription.root_dir`: the directory containing this
/// app's source and manifest, e.g. `apps` or `testing/fixtures`.
root_dir: []const u8,

/// Executables for each suported Innigkeit bundle target.
executables: Executables,

/// Mirrors `AppDescription.test_only`: if true, `Kernel.buildInitfs` only
/// includes this app when building the test kernel.
test_only: bool,

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

/// Resolve a specific app by its `AppDescription`.
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
    const lazy_path = b.path(b.pathJoin(&.{ description.root_dir, description.name, "main.zig" }));

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
        .root_dir = description.root_dir,
        .executables = executables,
        .test_only = description.test_only,
    };
}

/// Create an `std.Build.Module` based on an `AppDescription`.
fn createModule(
    b: *std.Build,
    description: AppDescription,
    root_source_file: std.Build.LazyPath,
    options: Options,
    bundle: Bundle,
    dependencies: []const *const Library,
) !*std.Build.Module {
    // Sub-module: the app developer's main.zig. All library dependencies and
    // the self-import live here so the app source is unchanged.
    const app_module = b.createModule(.{
        .root_source_file = root_source_file,
        // .target = bundle.resolveTarget(b),
        .optimize = options.optimize,
    });

    app_module.addImport(description.name, app_module);
    app_module.addImport("is_internal", switch (bundle.context) {
        .internal => options.internal_detection_module,
        .external => options.external_detection_module,
    });

    for (dependencies) |dep| {
        app_module.addImport(dep.name, switch (bundle.context) {
            .internal => dep.internal_modules.get(bundle.architecture).?,
            .external => dep.external_modules.get(bundle.architecture).?,
        });
    }

    switch (description.configuration) {
        .simple => {},
        .link_c => app_module.link_libc = true,
        .custom => |f| try f(b, bundle, app_module),
    }

    // UBSan only instruments C source this module actually compiles:
    // `.link_c`'s precompiled libc can't be instrumented either way, so the
    // only apps that benefit are ones whose `.custom` configuration (like
    // doom's) added real C sources via `addCSourceFile[s]`.
    //
    // Every `std.Build.Module` reaching the freestanding soft-float x64 target
    // (this one and `wrapper` below) must set `sanitize_c` explicitly. Otherwise,
    // left unset it takes Zig's implicit Debug-mode default (.full), which breaks
    // compilation there (ubsan_rt.zig's f128 path has no backend support without
    // SSE).
    const app_has_c_sources = for (app_module.link_objects.items) |obj| {
        switch (obj) {
            .c_source_file, .c_source_files => break true,
            else => {},
        }
    } else false;
    app_module.sanitize_c = if (app_has_c_sources) switch (options.optimize) {
        .Debug => .full,
        .ReleaseSafe, .ReleaseSmall => .trap,
        .ReleaseFast => .off,
    } else .off;

    // Root wrapper module: injects entry boilerplate and std_options defaults.
    // The app sub-module is imported as "app"; innigkeit is forwarded for the
    // wrapper's own use.
    const wrapper = b.createModule(.{
        .root_source_file = b.path("library/innigkeit/prelude.zig"),
        .target = bundle.resolveTarget(b),
        .optimize = options.optimize,
    });
    // The wrapper itself compiles no C source so it never benefits from UBSan
    // instrumentation. Left unset, it falls back to Zig's implicit Debug-mode
    // default (.full), which pulls in ubsan_rt.zig's f128 float-reporting path.
    // The freestanding soft-float x86-64 backend can't select `fpext f128` there
    // due to a Zig 0.16.0 backend limitation.
    wrapper.sanitize_c = .off;
    wrapper.addImport("app", app_module);
    wrapper.addImport("is_internal", switch (bundle.context) {
        .internal => options.internal_detection_module,
        .external => options.external_detection_module,
    });
    for (dependencies) |dep| {
        if (std.mem.eql(u8, dep.name, "innigkeit")) {
            wrapper.addImport("innigkeit", switch (bundle.context) {
                .internal => dep.internal_modules.get(bundle.architecture).?,
                .external => dep.external_modules.get(bundle.architecture).?,
            });
            break;
        }
    }

    return wrapper;
}
