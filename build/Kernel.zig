//! Builds the Innigkeit kernel for each supported architecture.
//!
//! The kernel module graph is declared in `src/root.zig` as a `[]const KernelModule`.
//! Graph traversal starts from the component named `kernel_entry` (currently `"internal"`),
//! then transitively pulls in all reachable components.
const Kernel = @This();

const std = @import("std");
const Step = std.Build.Step;
const App = @import("App.zig");
const Bundle = @import("Bundle.zig");
const KernelModule = @import("KernelModule.zig");
const Library = @import("Library.zig");
const Options = @import("Options.zig");
const Wrapper = @import("Wrapper.zig");
const Tool = @import("Tool.zig");

pub const Collection = std.AutoHashMapUnmanaged(Bundle.Architecture, Kernel);

/// The name of the root component from which DAG traversal begins.
const kernel_entry = "innigkeit";

/// Path to the final kernel binary, used by `ImageStep` to embed the kernel.
kernel_binary: std.Build.LazyPath,

/// The install step that copies the binary to the output directory.
install_step: *Step,

pub fn getKernels(
    b: *std.Build,
    wrapper: Wrapper,
    libraries: Library.Collection,
    options: Options,
    architectures: []const Bundle.Architecture,
    apps: App.Collection,
    tools: Tool.Collection,
) !Kernel.Collection {
    var kernels: Kernel.Collection = .empty;
    try kernels.ensureTotalCapacity(
        b.allocator,
        @intCast(architectures.len),
    );

    for (architectures) |architecture| {
        kernels.putAssumeCapacityNoClobber(architecture, try buildKernel(
            b,
            wrapper,
            libraries,
            options,
            architecture,
            apps,
            tools,
        ));
    }

    return kernels;
}

fn buildKernel(
    b: *std.Build,
    wrapper: Wrapper,
    libraries: Library.Collection,
    options: Options,
    arch: Bundle.Architecture,
    apps: App.Collection,
    tools: Tool.Collection,
) !Kernel {
    // Build the initfs archive once; share between check and release modules.
    const initfs_archive = buildInitfs(b, arch, apps, tools);

    // Check compilation: verifies correctness without emitting a binary.
    wrapper.registerCheck(b.addExecutable(.{
        .name = "kernel_check",
        .root_module = try buildRootModule(
            b,
            libraries,
            options,
            arch,
            initfs_archive,
            .check,
        ),
    }));

    const kernel_exe = b.addExecutable(.{
        .name = "kernel",
        .root_module = try buildRootModule(
            b,
            libraries,
            options,
            arch,
            initfs_archive,
            .release,
        ),
    });

    // x64: the Zig x86 backend does not yet support disabling SSE; force LLVM.
    if (arch == .x64) kernel_exe.use_llvm = true;

    kernel_exe.entry = .disabled;
    kernel_exe.lto = .none;
    kernel_exe.pie = true; // required for KASLR
    kernel_exe.linkage = .static;
    kernel_exe.setLinkerScript(b.path(b.pathJoin(
        &.{ "src", "architecture", @tagName(arch), "linker.ld" },
    )));

    const install = b.addInstallFile(
        kernel_exe.getEmittedBin(),
        b.pathJoin(&.{ @tagName(arch), "kernel" }),
    );
    wrapper.registerKernel(arch, &install.step);

    return .{
        .kernel_binary = kernel_exe.getEmittedBin(),
        .install_step = &install.step,
    };
}

/// Build the initfs ustar archive for the given architecture.
///
/// The archive is produced by running the `initfs_builder` host tool which
/// packs the compiled hello_world ELF (and any future init binaries) into a
/// POSIX ustar archive that is later embedded in the kernel via @embedFile.
fn buildInitfs(
    b: *std.Build,
    arch: Bundle.Architecture,
    apps: App.Collection,
    tools: Tool.Collection,
) std.Build.LazyPath {
    const hello_world = apps.get("hello_world") orelse @panic("no hello_world app!");
    const hello_world_exe = hello_world.executables.get(.{
        .architecture = arch,
        .context = .internal,
    }).?;

    const initfs_builder = tools.get("initfs_builder").?.release_safe_exe;

    const run = b.addRunArtifact(initfs_builder);
    run.addArg("hello_world");
    run.addFileArg(hello_world_exe.getEmittedBin());
    return run.captureStdOut(.{});
}

const BuildMode = enum { check, release };

fn buildRootModule(
    b: *std.Build,
    libraries: Library.Collection,
    options: Options,
    arch: Bundle.Architecture,
    initfs_archive: std.Build.LazyPath,
    mode: BuildMode,
) !*std.Build.Module {
    const graph = try resolveComponentGraph(b);
    const required_libs = try collectRequiredLibraries(b, libraries, graph);

    try configureComponents(
        b,
        arch,
        graph,
        required_libs,
        options,
        mode == .check,
    );

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = arch.kernelTarget(b),
        .optimize = options.optimize,
        .strip = false,
        .sanitize_c = switch (options.optimize) {
            .Debug => .full,
            .ReleaseSafe => .trap,
            .ReleaseFast, .ReleaseSmall => .off,
        },
        .omit_frame_pointer = false,
    });

    // Embed the initfs archive so the kernel can look up files by name at runtime.
    graph.entry.module.addImport(
        "initfs",
        b.createModule(.{ .root_source_file = initfs_archive }),
    );

    root.addImport("architecture", graph.nodes.get("architecture").?.module);
    root.addImport("boot", graph.nodes.get("boot").?.module);
    root.addImport("innigkeit", graph.nodes.get("innigkeit").?.module);

    switch (arch) {
        .arm, .riscv => {},
        .x64 => {
            root.code_model = .kernel;
            root.red_zone = false;
        },
    }

    return root;
}

/// A resolved kernel component node in the module dependency graph.
const ComponentNode = struct {
    /// The static declaration from `src/root.zig`.
    description: *const KernelModule,

    /// Path to the directory containing this component's source (`kernel/{name}`).
    source_dir: []const u8,

    /// The `*std.Build.Module` being constructed for this component.
    module: *std.Build.Module,

    /// The resolved DAG: all reachable nodes plus a direct pointer to the entry node.
    const Graph = struct {
        nodes: std.array_hash_map.String(ComponentNode),

        /// The component named by `kernel_entry`.
        entry: *ComponentNode,
    };
};

/// Walks the `KernelModule` DAG starting from `kernel_entry` and returns all
/// reachable nodes. Panics if any referenced component is missing.
fn resolveComponentGraph(b: *std.Build) !ComponentNode.Graph {
    var pending: std.array_hash_map.String(void) = .empty;
    try pending.putNoClobber(b.allocator, kernel_entry, {});

    var nodes: std.array_hash_map.String(ComponentNode) = .empty;

    while (pending.pop()) |kv| {
        const name = kv.key;
        if (nodes.contains(name)) continue;

        const desc = allKernelModules.get(name) orelse std.debug.panic(
            "kernel component graph references non-existent component '{s}'!",
            .{name},
        );

        for (desc.component_dependencies) |dep| try pending.put(b.allocator, dep, {});

        try nodes.putNoClobber(b.allocator, name, .{
            .description = desc,
            .source_dir = b.pathJoin(&.{ "src", desc.name }),
            .module = b.createModule(.{}),
        });
    }

    return .{
        .nodes = nodes,
        .entry = nodes.getPtr(kernel_entry).?,
    };
}

/// Collects the union of all library dependencies across all component nodes.
fn collectRequiredLibraries(
    b: *std.Build,
    libraries: Library.Collection,
    graph: ComponentNode.Graph,
) !Library.Collection {
    var result: Library.Collection = .empty;

    for (graph.nodes.values()) |node| {
        for (node.description.library_dependencies) |dep| {
            if (result.contains(dep.name)) continue;
            try result.putNoClobber(
                b.allocator,
                dep.name,
                libraries.get(dep.name) orelse std.debug.panic(
                    "kernel component '{s}' depends on non-existent library '{s}'!",
                    .{ node.description.name, dep.name },
                ),
            );
        }
    }

    return result;
}

/// Configures every node in the graph: sets the root source file, wires
/// dependency imports, adds sourcemap modules, and calls any custom callback.
fn configureComponents(
    b: *std.Build,
    arch: Bundle.Architecture,
    graph: ComponentNode.Graph,
    libraries: Library.Collection,
    options: Options,
    is_check: bool,
) !void {
    for (graph.nodes.values()) |node| {
        const desc = node.description;
        const module = node.module;

        module.root_source_file = b.path(b.pathJoin(&.{
            node.source_dir,
            b.fmt("{s}.zig", .{desc.name}),
        }));

        for (desc.library_dependencies) |dep| {
            module.addImport(
                dep.import_name orelse dep.name,
                libraries.get(dep.name).?.internal_modules.get(arch) orelse unreachable,
            );
        }

        for (desc.component_dependencies) |dep| {
            module.addImport(dep, graph.nodes.get(dep).?.module);
        }

        // Self-import allows a component to reference its own public API by name.
        module.addImport(desc.name, module);

        if (desc.sourcemaps) {
            for (try collectSourceFileModules(b, libraries, options)) |sfm| {
                module.addImport(sfm.import_name, sfm.module);
            }
        }

        if (desc.configuration) |f| try f(b, arch, module, options, is_check);
    }
}

/// A Zig source file exposed as a named build module so the kernel can `@embedFile` it by path.
///
/// A companion `embedded_source_files` index module lists all paths for use
/// with `ComptimeStringHashMap` to look up source content by file path at runtime.
const SourceFileModule = struct {
    import_name: []const u8,
    module: *std.Build.Module,
};

/// Collects all `.zig` source files reachable from `kernel/` and all required
/// library source directories, returning one `SourceFileModule` per file plus
/// the `embedded_source_files` index module.
fn collectSourceFileModules(
    b: *std.Build,
    required_libraries: Library.Collection,
    options: Options,
) ![]const SourceFileModule {
    var modules: std.ArrayList(SourceFileModule) = .empty;
    var file_paths: std.ArrayList([]const u8) = .empty;
    defer file_paths.deinit(b.allocator);

    try collectFilesRecursive(b, &modules, &file_paths, "src");

    var visited: std.AutoHashMapUnmanaged(*const Library, void) = .empty;
    defer visited.deinit(b.allocator);
    for (required_libraries.values()) |lib| {
        try collectFilesFromLibrary(b, &modules, &file_paths, lib, &visited);
    }

    const index = b.addOptions();
    index.addOption([]const u8, "build_prefix", options.root_path);
    index.addOption([]const []const u8, "file_paths", file_paths.items);
    try modules.append(b.allocator, .{
        .import_name = "embedded_source_files",
        .module = index.createModule(),
    });

    return try modules.toOwnedSlice(b.allocator);
}

fn collectFilesFromLibrary(
    b: *std.Build,
    modules: *std.ArrayList(SourceFileModule),
    file_paths: *std.ArrayList([]const u8),
    library: *const Library,
    visited: *std.AutoHashMapUnmanaged(*const Library, void),
) !void {
    if (visited.contains(library)) return;
    try collectFilesRecursive(b, modules, file_paths, library.directory_path);
    try visited.put(b.allocator, library, {});
    for (library.dependencies) |dependency|
        try collectFilesFromLibrary(
            b,
            modules,
            file_paths,
            dependency,
            visited,
        );
}

fn collectFilesRecursive(
    b: *std.Build,
    modules: *std.ArrayList(SourceFileModule),
    file_paths: *std.ArrayList([]const u8),
    dir_path: []const u8,
) !void {
    var dir = try b.build_root.handle.openDir(
        b.graph.io,
        dir_path,
        .{ .iterate = true },
    );
    defer dir.close(b.graph.io);

    var it = dir.iterate();
    while (try it.next(b.graph.io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.eql(u8, std.fs.path.extension(entry.name), ".zig")) continue;
                const path = b.pathJoin(&.{ dir_path, entry.name });
                try file_paths.append(b.allocator, path);
                try modules.append(b.allocator, .{
                    .import_name = path,
                    .module = b.createModule(.{ .root_source_file = b.path(path) }),
                });
            },
            .directory => {
                if (entry.name[0] == '.') continue;
                try collectFilesRecursive(b, modules, file_paths, b.pathJoin(&.{ dir_path, entry.name }));
            },
            else => {},
        }
    }
}

/// Compile-time map from component name to its `KernelModule` declaration.
const allKernelModules: std.StaticStringMap(*const KernelModule) = .initComptime(blk: {
    const listing = @import("../src/root.zig").modules;
    var entries: [listing.len]struct { []const u8, *const KernelModule } = undefined;
    for (listing, 0..) |km, i| entries[i] = .{ km.name, &km };
    break :blk entries;
});
