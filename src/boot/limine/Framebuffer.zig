//! Framebuffer Feature

const core = @import("core");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x9D5827DCD881DD75, 0xA3148604F6FAB11B),
    revision: u64 = 0,

    /// If no framebuffer is available, no response will be provided.
    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,

    _framebuffer_count: u64,

    _framebuffers: [*]const *const LimineFramebuffer,

    pub fn framebuffers(self: *const Response) []const *const LimineFramebuffer {
        return self._framebuffers[0..self._framebuffer_count];
    }
};

pub const LimineFramebuffer = extern struct {
    address: innigkeit.KernelVirtualAddress,
    /// Width and height of the framebuffer in pixels
    width: u64,
    height: u64,
    /// Pitch in bytes
    pitch: u64,
    /// Bits per pixel
    bpp: u16,
    memory_model: MemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    unused: [7]u8,

    _edid_size: core.Size,

    /// Points to the screen's EDID blob, if available, else zero.
    _edid: innigkeit.KernelVirtualAddress,

    /// Response revision 1 required
    _video_mode_count: u64,

    /// Response revision 1 required
    _video_modes: [*]const *const VideoMode,

    pub fn edid(self: *const LimineFramebuffer) ?[]const u8 {
        if (self._edid.equal(.zero)) return null;

        return innigkeit.KernelVirtualRange.from(
            self._edid,
            self._edid_size,
        ).byteSlice();
    }

    pub fn videoModes(self: *const LimineFramebuffer, response_revision: u64) []const *const VideoMode {
        if (response_revision < 1) return &.{};
        return self._video_modes[0..self._video_mode_count];
    }

    pub fn print(self: *const LimineFramebuffer, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("Framebuffer{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{self.address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print(
            "resolution: {}x{}@{}\n",
            .{ self.width, self.height, self.bpp },
        );

        try writer.splatByteAll(' ', new_indent);
        try writer.print("pitch: {}\n", .{self.pitch});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("memory_model: {t}\n", .{self.memory_model});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const LimineFramebuffer, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

test "LimineFramebuffer.format compiles and runs" {
    // format() is never called by anything in the kernel itself; calling it
    // here is what forces Zig to analyze its body (see the identical note
    // in MP.zig's test). This file had the same self.print(self, ...)
    // double-self-argument bug MP.zig and EFIMemoryMap.zig also had.
    const fb: LimineFramebuffer = .{
        .address = .{ .value = 0 },
        .width = 0,
        .height = 0,
        .pitch = 0,
        .bpp = 32,
        .memory_model = .rgb,
        .red_mask_size = 0,
        .red_mask_shift = 0,
        .green_mask_size = 0,
        .green_mask_shift = 0,
        .blue_mask_size = 0,
        .blue_mask_shift = 0,
        .unused = @splat(0),
        ._edid_size = .{ .value = 0 },
        ._edid = .{ .value = 0 },
        ._video_mode_count = 0,
        ._video_modes = &.{},
    };

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("{f}", .{fb});
}

pub const VideoMode = extern struct {
    /// Pitch in bytes
    pitch: u64,
    /// Width and height of the framebuffer in pixels
    width: u64,
    height: u64,
    /// Bits per pixel
    bpp: u16,
    memory_model: MemoryModel,
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,

    pub fn print(self: *const VideoMode, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("VideoMode{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print(
            "resolution: {}x{}@{}\n",
            .{ self.width, self.height, self.bpp },
        );

        try writer.splatByteAll(' ', new_indent);
        try writer.print("pitch: {}\n", .{self.pitch});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("memory_model: {t}\n", .{self.memory_model});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const VideoMode, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

pub const MemoryModel = enum(u8) {
    rgb = 1,
    _,
};
