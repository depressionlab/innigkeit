//! Resolved library, ready to be imported by apps, tools, and kernel components.
//!
//! Libraries are constructed by `Library.getLibraries`, which topologically
//! sorts the dependency graph declared in `library/root.zig` and panics on
//! cycles or missing names.
// zlinter-disable require_errdefer_dealloc - every allocation here goes through b.allocator, an arena for the whole build graph's lifetime; there is no per-allocation free to add.
const Library = @This();

const Bundle = @import("Bundle.zig");
const LibraryDescription = @import("LibraryDescription.zig");
const Options = @import("Options.zig");
const std = @import("std");
const Wrapper = @import("Wrapper.zig");

const Modules = std.AutoHashMapUnmanaged(Bundle.Architecture, *std.Build.Module);
pub const Collection = std.array_hash_map.String(*Library);

/// The library's canonical name; used as `@import` key and in step names.
name: []const u8,

/// Path to the directory containing this library's source (`lib/{name}`).
directory_path: []const u8,

/// Resolved direct dependencies (not transitive).
dependencies: []const *const Library,

/// One module per supported architecture, built for freestanding internal targets.
internal_modules: Modules,

/// One module per supported architecture, built for host OS external targets.
external_modules: Modules,

/// The external module for the host architecture, if the host is a supported target.
/// `null` when the library's `ArchitectureFilter` excludes the host.
external_module_for_host: ?*std.Build.Module,

/// Resolves library names to pointers from `libraries`. Panics on any missing name.
/// The returned slice is owned by `b.allocator`.
pub fn resolveDeps(
    b: *std.Build,
    libraries: Library.Collection,
    owner_name: []const u8,
    dep_names: []const []const u8,
) ![]const *const Library {
    var deps: std.ArrayList(*const Library) =
        try .initCapacity(b.allocator, dep_names.len);

    for (dep_names) |name| {
        deps.appendAssumeCapacity(libraries.get(name) orelse std.debug.panic(
            "'{s}' has unresolvable dependency: '{s}'!",
            .{ owner_name, name },
        ));
    }

    return try deps.toOwnedSlice(b.allocator);
}

/// Resolves all libraries declared in `library/root.zig` and their dependencies.
///
/// Resolution is iterative: each pass attempts to resolve any library whose
/// dependencies are already resolved. Panics if a full pass resolves nothing
/// (indicating a cycle or a missing dependency).
pub fn getLibraries(
    b: *std.Build,
    wrapper: Wrapper,
    options: Options,
    architectures: []const Bundle.Architecture,
) !Library.Collection {
    const descriptions: []const LibraryDescription = @import("../library/root.zig").libraries;

    var libraries: Library.Collection = .empty;
    try libraries.ensureTotalCapacity(b.allocator, descriptions.len);

    var pending: std.ArrayList(LibraryDescription) =
        try .initCapacity(b.allocator, descriptions.len);
    defer pending.deinit(b.allocator);

    pending.appendSliceAssumeCapacity(descriptions);

    while (pending.items.len != 0) {
        var resolved_any = false;
        var i: usize = 0;

        while (i < pending.items.len) {
            if (try resolveLibrary(
                b,
                pending.items[i],
                libraries,
                wrapper,
                options,
                architectures,
                descriptions,
            )) |lib| {
                libraries.putAssumeCapacityNoClobber(pending.items[i].name, lib);
                _ = pending.orderedRemove(i);
                resolved_any = true;
            } else {
                i += 1;
            }
        }
        if (!resolved_any)
            @panic("cycle or missing library in dependency graph!");
    }

    return libraries;
}

/// Attempts to resolve one library. Returns `null` if any dependency is not yet resolved.
///
/// Panics if a dependency name does not exist in any known description.
fn resolveLibrary(
    b: *std.Build,
    description: LibraryDescription,
    libraries: Library.Collection,
    wrapper: Wrapper,
    options: Options,
    architectures: []const Bundle.Architecture,
    descriptions: []const LibraryDescription,
) !?*Library {
    // Check all deps are resolved; return null if any aren't yet.
    for (description.dependencies) |dep_name| {
        if (libraries.contains(dep_name)) continue;
        const known = for (descriptions) |d| {
            if (std.mem.eql(u8, d.name, dep_name)) break true;
        } else false;
        if (!known) std.debug.panic(
            "library '{s}' depends on non-existent library '{s}'!",
            .{ description.name, dep_name },
        );
        return null;
    }

    const owned_deps = try resolveDeps(b, libraries, description.name, description.dependencies);
    const dir = b.pathJoin(&.{ "library", description.name });
    const lazy_path = b.path(b.pathJoin(&.{ dir, "root.zig" }));
    const target_archs = description.architectures.resolve(architectures);

    var internal_modules: Modules = .empty;
    var external_modules: Modules = .empty;
    var host_module: ?*std.Build.Module = null;

    const all_tests_step = b.step(
        description.name,
        if (description.freestanding_only)
            b.fmt("Build tests for {s} for every supported architecture", .{description.name})
        else
            b.fmt("Build and run tests for {s} for every supported architecture", .{description.name}),
    );

    for (target_archs) |arch| {
        const internal_bundle: Bundle = .{ .architecture = arch, .context = .internal };
        const external_bundle: Bundle = .{ .architecture = arch, .context = .external };

        try internal_modules.putNoClobber(
            b.allocator,
            arch,
            createModule(
                b,
                description,
                lazy_path,
                options,
                internal_bundle,
                .dependency,
                owned_deps,
            ),
        );

        const ext_module = createModule(
            b,
            description,
            lazy_path,
            options,
            external_bundle,
            .dependency,
            owned_deps,
        );
        try external_modules.putNoClobber(b.allocator, arch, ext_module);
        if (arch.isNative(b)) host_module = ext_module;

        // Check exe: verify the library compiles for the host without emitting a binary.
        wrapper.registerCheck(b.addTest(.{
            .name = b.fmt("{s}_check", .{description.name}),
            .root_module = createModule(
                b,
                description,
                lazy_path,
                options,
                external_bundle,
                .exe_root,
                owned_deps,
            ),
        }));

        if (!description.freestanding_only) {
            // Host test exe: build, install, and (where native) run the test binary.
            const test_module = createModule(
                b,
                description,
                lazy_path,
                options,
                external_bundle,
                .exe_root,
                owned_deps,
            );
            test_module.optimize = options.optimize;

            const test_exe = b.addTest(.{
                .name = description.name,
                .root_module = test_module,
            });
            const install = b.addInstallArtifact(test_exe, .{
                .dest_dir = .{ .override = .{ .custom = b.pathJoin(&.{
                    @tagName(arch), "library", "tests", "external",
                }) } },
            });

            const run = b.addRunArtifact(test_exe);
            run.skip_foreign_checks = true;
            run.failing_to_execute_foreign_is_an_error = false;
            run.step.dependOn(&install.step);

            const test_step = b.step(
                b.fmt("{s}_host_{s}", .{ description.name, @tagName(arch) }),
                b.fmt("Build and run tests for {s} on {s} targeting the host os", .{ description.name, @tagName(arch) }),
            );
            test_step.dependOn(&run.step);
            all_tests_step.dependOn(test_step);
            wrapper.registerLibraryTest(arch, test_step);
        }
    }

    const library = try b.allocator.create(Library);
    library.* = .{
        .name = description.name,
        .directory_path = dir,
        .dependencies = owned_deps,
        .internal_modules = internal_modules,
        .external_modules = external_modules,
        .external_module_for_host = host_module,
    };
    return library;
}

const ModulePurpose = enum {
    /// Used as a dependency import; target is inherited from the consumer.
    dependency,

    /// Root of a test or check exe; target must be set explicitly.
    exe_root,
};

fn createModule(
    b: *std.Build,
    description: LibraryDescription,
    lazy_path: std.Build.LazyPath,
    options: Options,
    bundle: Bundle,
    purpose: ModulePurpose,
    dependencies: []const *const Library,
) *std.Build.Module {
    const module = b.createModule(.{ .root_source_file = lazy_path });

    if (purpose == .exe_root) module.resolved_target = bundle.resolveTarget(b);

    module.addImport(description.name, module);
    module.addImport("is_internal", switch (bundle.context) {
        .internal => options.internal_detection_module,
        .external => options.external_detection_module,
    });

    for (dependencies) |dep| {
        module.addImport(dep.name, switch (bundle.context) {
            .internal => dep.internal_modules.get(bundle.architecture).?,
            .external => dep.external_modules.get(bundle.architecture).?,
        });
    }

    return module;
}
