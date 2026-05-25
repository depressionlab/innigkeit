//! Zig-side exports of Innigkeit syscalls with C calling convention.
//! These are declared in innigkeit_syscalls.h and called by C files.

const innigkeit = @import("innigkeit");

export fn innigkeit_write(buf: ?[*]const u8, len: usize) callconv(.c) i64 {
    if (buf == null or len == 0) return 0;
    innigkeit.io.stdout.print("{s}", .{buf.?[0..len]}) catch return -5;
    return @intCast(len);
}

export fn innigkeit_exit(code: c_int) callconv(.c) noreturn {
    _ = innigkeit.Syscall.invoke(.exit_process, .{@as(usize, @bitCast(@as(isize, @intCast(code))))});
    unreachable;
}

export fn innigkeit_mmap(size: usize) callconv(.c) ?*anyopaque {
    const result = innigkeit.Syscall.invoke(.mmap, .{ size, 0x3 }); // PROT_READ|WRITE
    const addr = innigkeit.Syscall.decode(result) catch return null;
    if (addr == 0) return null;
    return @ptrFromInt(addr);
}

export fn innigkeit_munmap(addr: ?*anyopaque, size: usize) callconv(.c) void {
    if (addr == null) return;
    _ = innigkeit.Syscall.invoke(.munmap, .{ @intFromPtr(addr), size });
}

const display = innigkeit.display;

export fn innigkeit_framebuffer_map(info_out: *display.FramebufferInfo) callconv(.c) ?*volatile anyopaque {
    const fb = display.framebufferMap() catch return null;
    info_out.* = fb.info;
    return @ptrCast(fb.pixels);
}

export fn innigkeit_uptime_ms() callconv(.c) u64 {
    return display.uptimeMs();
}

const BlkReadSpec = extern struct {
    byte_offset: u64,
    buf_ptr: usize,
    buf_len: usize,
};

export fn innigkeit_blk_read(byte_offset: u64, buf: *anyopaque, len: usize) callconv(.c) i64 {
    const spec = BlkReadSpec{
        .byte_offset = byte_offset,
        .buf_ptr = @intFromPtr(buf),
        .buf_len = len,
    };
    const result = innigkeit.Syscall.invoke(.blk_read, .{@intFromPtr(&spec)});
    const got = innigkeit.Syscall.decode(result) catch return -1;
    return @intCast(got);
}

const InitfsReadSpec = extern struct {
    name_ptr: usize,
    name_len: u32,
    _pad: u32 = 0,
    buf_ptr: usize,
    buf_len: usize,
};

export fn innigkeit_initfs_read(name: [*]const u8, name_len: usize, buf: ?*anyopaque, buf_len: usize) callconv(.c) i64 {
    const spec = InitfsReadSpec{
        .name_ptr = @intFromPtr(name),
        .name_len = @intCast(name_len),
        .buf_ptr = if (buf) |b| @intFromPtr(b) else 0,
        .buf_len = buf_len,
    };
    const result = innigkeit.Syscall.invoke(.initfs_read, .{@intFromPtr(&spec)});
    const got = innigkeit.Syscall.decode(result) catch return -2; // ENOENT
    return @intCast(got);
}

export fn innigkeit_kbd_read(buf: *anyopaque, len: usize) callconv(.c) i64 {
    const result = innigkeit.Syscall.invoke(.kbd_read, .{ @intFromPtr(buf), len });
    if (result < 0) return 0;
    return @intCast(result);
}
