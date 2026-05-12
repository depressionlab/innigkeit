//! Framebuffer Feature

const root = @import("root.zig");
const innigkeit = @import("innigkeit");
const core = @import("core");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x9d5827dcd881dd75, 0xa3148604f6fab11b),
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
        return self.print(self, writer, 0);
    }
};

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
