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

    pub fn framebuffers(response: *const Response) []const *const LimineFramebuffer {
        return response._framebuffers[0..response._framebuffer_count];
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

    pub fn edid(limine_framebuffer: *const LimineFramebuffer) ?[]const u8 {
        if (limine_framebuffer._edid.equal(.zero)) return null;

        return innigkeit.KernelVirtualRange.from(
            limine_framebuffer._edid,
            limine_framebuffer._edid_size,
        ).byteSlice();
    }

    pub fn videoModes(
        limine_framebuffer: *const LimineFramebuffer,
        response_revision: u64,
    ) []const *const VideoMode {
        if (response_revision < 1) return &.{};
        return limine_framebuffer._video_modes[0..limine_framebuffer._video_mode_count];
    }

    pub fn print(limine_framebuffer: *const LimineFramebuffer, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("Framebuffer{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{limine_framebuffer.address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print(
            "resolution: {}x{}@{}\n",
            .{ limine_framebuffer.width, limine_framebuffer.height, limine_framebuffer.bpp },
        );

        try writer.splatByteAll(' ', new_indent);
        try writer.print("pitch: {}\n", .{limine_framebuffer.pitch});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("memory_model: {t}\n", .{limine_framebuffer.memory_model});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(
        limine_framebuffer: *const LimineFramebuffer,
        writer: *std.Io.Writer,
    ) !void {
        return limine_framebuffer.print(limine_framebuffer, writer, 0);
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

    pub fn print(video_mode: *const VideoMode, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("VideoMode{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print(
            "resolution: {}x{}@{}\n",
            .{ video_mode.width, video_mode.height, video_mode.bpp },
        );

        try writer.splatByteAll(' ', new_indent);
        try writer.print("pitch: {}\n", .{video_mode.pitch});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("memory_model: {t}\n", .{video_mode.memory_model});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(video_mode: *const VideoMode, writer: *std.Io.Writer) !void {
        return video_mode.print(writer, 0);
    }
};

pub const MemoryModel = enum(u8) {
    rgb = 1,
    _,
};
