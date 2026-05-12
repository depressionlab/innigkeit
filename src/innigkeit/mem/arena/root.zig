// TODO: use `core.Size`
// TODO: return unused tags to the cache when they exceed a threshold
// TODO: stats
// TODO: next fit

const std = @import("std");

const innigkeit = @import("innigkeit");
const core = @import("core");

pub const Arena = @import("Arena.zig").Arena;
pub const init = @import("init.zig");
const globals = @import("globals.zig");

pub const InitOptions = struct {
    name: Name,
    quantum: usize,
    source: ?Source = null,
};

pub const Policy = enum {
    instant_fit,
    first_fit,
    best_fit,
};

pub const Allocation = struct {
    base: usize,
    len: usize,

    pub inline fn toVirtualRange(self: Allocation) innigkeit.KernelVirtualRange {
        return .{
            .address = .{ .value = self.base },
            .size = .from(self.len, .byte),
        };
    }

    pub inline fn fromVirtualRange(range: innigkeit.KernelVirtualRange) Allocation {
        return .{
            .base = range.address.value,
            .len = range.size.value,
        };
    }

    pub inline fn format(self: Allocation, writer: *std.Io.Writer) !void {
        try writer.print("Allocation{{ base: 0x{x}, len: 0x{x} }}", .{ self.base, self.len });
    }
};

pub const Source = struct {
    name: []const u8,

    arena_ptr: *anyopaque,

    import: *const fn (
        arena_ptr: *anyopaque,
        len: usize,
        policy: Policy,
    ) AllocateError!Allocation,

    release: *const fn (
        arena_ptr: *anyopaque,
        allocation: Allocation,
    ) void,

    pub fn callImport(self: *const Source, len: usize, policy: Policy) callconv(core.inline_in_non_debug) AllocateError!Allocation {
        return self.import(self.arena_ptr, len, policy);
    }

    pub fn callRelease(self: *const Source, allocation: Allocation) callconv(core.inline_in_non_debug) void {
        self.release(self.arena_ptr, allocation);
    }
};

pub const InitError = error{
    /// The `quantum` is not a power of two.
    InvalidQuantum,
};

pub const AddSpanError = error{
    ZeroLength,
    WouldWrap,
    Unaligned,
    Overlap,
} || EnsureBoundaryTagsError;

pub const AllocateError = error{
    ZeroLength,
    RequestedLengthUnavailable,
} || EnsureBoundaryTagsError;

pub const EnsureBoundaryTagsError = error{
    OutOfBoundaryTags,
};

pub const Name = core.containers.BoundedArray(u8, innigkeit.config.mem.resource_arena_name_length);
