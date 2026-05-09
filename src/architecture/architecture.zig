//! Defines the interface of the architecture specific code.

const core = @import("core");

pub const Arch = @TypeOf(current_arch);
pub const current_arch = @import("innigkeit_architecture").architecture;

/// Architecture specific per-executor data.
pub const PerExecutor = current_decls.PerExecutor;

/// Issues an architecture specific hint to the executor that we are spinning in a loop.
pub fn spinLoopHint() callconv(core.inline_in_non_debug) void {
    getFunction(
        current_functions,
        "spinLoopHint",
    )();
}

/// Halts the current executor.
pub fn halt() callconv(core.inline_in_non_debug) void {
    getFunction(
        current_functions,
        "halt",
    )();
}

pub const interrupts = @import("interrupts.zig");
pub const paging = @import("paging.zig");
pub const scheduling = @import("scheduling.zig");
pub const user = @import("user.zig");
pub const io = @import("io.zig");
pub const init = @import("init.zig");
pub const Functions = @import("Functions.zig");
pub const Decls = @import("Decls.zig");

const current_interface = switch (current_arch) {
    .arm => @import("arm/interface.zig"),
    .riscv => @import("riscv/interface.zig"),
    .x64 => @import("x64/interface.zig"),
};

// `Functions` and `Decls` must be seperate types to avoid dependency loops.
pub const current_functions: Functions = current_interface.functions;
pub const current_decls: Decls = current_interface.decls;

pub inline fn getFunction(comptime container: anytype, comptime name: []const u8) GetFunctionReturnType(container, name) {
    const T: type = @FieldType(@TypeOf(container), name);
    switch (@typeInfo(T)) {
        .@"fn" => return @field(container, name),
        .optional => {
            if (@field(container, name)) |func| return func;
            @panic(comptime "`" ++ @tagName(current_arch) ++ "` does not implement `" ++ name ++ "`!");
        },
        // TODO: the error here is not perfect as it does not gives the full path to the function
        else => @compileError("field `" ++ name ++ "` has unsupported type " ++ @typeName(T) ++ "!"),
    }
}

fn GetFunctionReturnType(comptime container: anytype, comptime name: []const u8) type {
    const T: type = @FieldType(@TypeOf(container), name);
    switch (@typeInfo(T)) {
        .@"fn" => return T,
        .optional => |opt| return opt.child,
        // TODO: the error here is not perfect as it does not gives the full path to the function
        else => @compileError("field `" ++ name ++ "` has unsupported type " ++ @typeName(T) ++ "!"),
    }
}
