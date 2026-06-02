//! Framebuffer display access.
//!
//! framebufferMap() maps the bootloader-provided linear framebuffer
//! (32-bit BGRX pixels) into the calling process's address space with
//! write-combining cache policy for maximum throughput.
//!
//! The returned pointer is a flat pixel array: pixel(x,y) is at
//! buf[y * info.pitch/4 + x] as a u32 (BGRX: blue=bits[7:0]).

const innigkeit = @import("innigkeit");

/// Metadata returned by framebufferMap.
pub const FramebufferInfo = extern struct {
    width: u32,
    height: u32,
    pitch: u32, // bytes per scan line
    bpp: u8, // bits per pixel (always 32 for BGRX)
    _pad: [3]u8 = .{0} ** 3,

    /// Pixels per row (stride in u32 units).
    pub fn stride(self: FramebufferInfo) u32 {
        return self.pitch / 4;
    }

    /// Total pixel buffer size in bytes.
    pub fn byteSize(self: FramebufferInfo) usize {
        return @as(usize, self.pitch) * @as(usize, self.height);
    }
};

/// Return milliseconds elapsed since kernel boot.
pub fn uptimeMs() u64 {
    const result = innigkeit.Syscall.invoke(.uptime_ms, .{});
    return @bitCast(result);
}

/// Non-blocking drain of raw PS/2 bytes. Returns count copied (0 if none pending).
pub fn kbdRead(buf: []u8) usize {
    const result = innigkeit.Syscall.invoke(.kbd_read, .{ @intFromPtr(buf.ptr), buf.len });
    if (result < 0) return 0;
    return @intCast(result);
}

/// Decoded PS/2 mouse event (matches kernel ABI exactly).
pub const MouseEvent = extern struct {
    /// Button state: bit 0=left, bit 1=right, bit 2=middle.
    buttons: u8,
    /// Signed X movement delta (positive = right).
    dx: i8,
    /// Signed Y movement delta (positive = up in PS/2 coords).
    dy: i8,
    _pad: u8 = 0,
};

/// Non-blocking drain of PS/2 mouse events. Returns count of events read.
pub fn mouseRead(events: []MouseEvent) usize {
    const result = innigkeit.Syscall.invoke(.mouse_read, .{ @intFromPtr(events.ptr), events.len });
    if (result < 0) return 0;
    return @intCast(result);
}

/// Flush the virtio-gpu backing store (w×h pixels) to the host display.
/// No-op if virtio-gpu is not present.
pub fn gpuFlush(w: u32, h: u32) void {
    _ = innigkeit.Syscall.invoke(.gpu_flush, .{ w, h });
}

/// Map the bootloader framebuffer into the calling process's address space.
///
/// Returns a pointer to the pixel buffer and metadata.
/// The pointer remains valid for the lifetime of the process.
/// Each pixel is 32-bit BGRX (blue in bits [7:0]).
pub fn framebufferMap() innigkeit.Syscall.Error!struct { pixels: [*]volatile u32, info: FramebufferInfo } {
    var info: FramebufferInfo = undefined;
    const result = innigkeit.Syscall.invoke(.framebuffer_map, .{@intFromPtr(&info)});
    const va = try innigkeit.Syscall.decode(result);
    return .{ .pixels = @ptrFromInt(va), .info = info };
}
