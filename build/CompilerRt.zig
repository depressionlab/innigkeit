//! Workaround for Zig 0.17.0 regression ziglang/zig#37006: on x86-64 targets
//! with `soft_float` (every x64 target of this repo) the stock compiler_rt
//! sub-compilation fails, because it exports long-double math functions whose
//! C-ABI signatures use `c_longdouble`, which is not extern-compatible there.
//!
//! `tools/build_helper patch-compiler-rt` copies Zig's compiler_rt with
//! `c_longdouble` spelled `f64`; it is built as a static library here and
//! linked in place of the bundled one. Nothing can call the long-double
//! functions on such a target (no x87), so the changed signatures are inert.
//! The helper fails once the stock sources stop mentioning `c_longdouble`,
//! which is the cue to delete this file and its call sites.
const std = @import("std");

const Variant = struct {
    code_model: std.lang.CodeModel,
    red_zone: ?bool,
    library: *std.Build.Step.Compile,
};

var variants: std.ArrayList(Variant) = .empty;
/// Modules already linked against a patched library (check and real builds share one).
var linked: std.ArrayList(*std.Build.Module) = .empty;

/// Makes `compile` link the patched compiler_rt instead of the bundled one, if
/// its target is affected; otherwise does nothing.
///
/// Call after `compile`'s root module has its `code_model`/`red_zone` set.
pub fn apply(b: *std.Build, compile: *std.Build.Step.Compile) void {
    const module = compile.root_module;
    const resolved = module.resolved_target.?;
    if (resolved.result.cpu.arch != .x86_64 or !resolved.result.cpu.has(.x86, .soft_float)) return;

    compile.bundle_compiler_rt = false;
    for (linked.items) |seen| if (seen == module) return;
    module.linkLibrary(library(b, resolved, module.code_model, module.red_zone));
    linked.append(b.allocator, module) catch @panic("OOM");
}

fn library(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    code_model: std.lang.CodeModel,
    red_zone: ?bool,
) *std.Build.Step.Compile {
    for (variants.items) |variant| {
        if (variant.code_model == code_model and variant.red_zone == red_zone) return variant.library;
    }

    const helper = b.addExecutable(.{
        .name = "build_helper_compiler_rt",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/build_helper/main.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        }),
    });
    const patch = b.addRunArtifact(helper);
    patch.addArg("patch-compiler-rt");
    patch.addDirectoryArg2(.zig_lib, .{});
    const patched = patch.addOutputDirectoryArg2("compiler_rt", .{});

    const lib = b.addLibrary(.{
        .name = "compiler_rt",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = patched.path(b, "compiler_rt.zig"),
            .target = target,
            .optimize = .small,
            .code_model = code_model,
            .red_zone = red_zone,
            .pic = true, // linked into PIE (KASLR) kernels
            .sanitize_c = .off,
            .strip = true,
        }),
    });
    lib.bundle_compiler_rt = false;

    variants.append(b.allocator, .{ .code_model = code_model, .red_zone = red_zone, .library = lib }) catch @panic("OOM");
    return lib;
}
