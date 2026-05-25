const boot = @import("boot");
const c = @import("flanterm");
const innigkeit = @import("innigkeit");
const Output = @import("Output.zig");

/// Physical layout of the bootloader framebuffer.
/// Filled on first successful framebuffer init; null if no framebuffer.
pub const PhysInfo = struct {
    phys_base: innigkeit.PhysicalAddress,
    width: u32,
    height: u32,
    pitch: u32, // bytes per row
    bpp: u8, // bits per pixel (always 32 for BGRX)
};

var phys_info: ?PhysInfo = null;

/// Return the physical framebuffer info, or null if not initialised.
pub fn getPhysInfo() ?PhysInfo {
    return phys_info;
}

const init_log = innigkeit.debug.log.scoped(.output_init);

pub fn tryGetFramebufferOutput(memory_system_available: bool) ?Output {
    return tryGetFramebufferOutputInner(memory_system_available) catch |err| {
        init_log.err("failed to initialize serial output: {}", .{err});
        return null;
    };
}

pub fn tryGetExtendedFramebuffer(memory_system_available: bool) !?boot.Framebuffer {
    if (!memory_system_available) return null;
    const framebuffer = boot.framebuffer() orelse return null;
    const virtual_range = try innigkeit.mem.heap.allocateSpecial(
        .{
            .physical_range = .from(
                .fromDirectMap(.fromPtr(framebuffer.ptr)),
                .from(framebuffer.height * framebuffer.pitch, .byte),
            ),
            .protection = .{ .write = true },
            .cache = .write_combining,
        },
    );
    errdefer innigkeit.mem.heap.deallocateSpecial(virtual_range);

    var y: usize = 0;

    while (y < framebuffer.height) : (y += 1) {
        var x: usize = 0;
        while (x < framebuffer.width) : (x += 1) {
            const nX: u32 = @intCast(x * 255 / framebuffer.width);
            const nY: u32 = @intCast(y * 255 / framebuffer.height);
            framebuffer.ptr[y * (framebuffer.pitch / 4) + x] = (nY << 8) | nX;
        }
        x += 1;
    }

    return framebuffer;
}

fn tryGetFramebufferOutputInner(memory_system_available: bool) !?Output {
    if (!memory_system_available) return null;

    const framebuffer = boot.framebuffer() orelse return null;

    // Store physical info for the vmem_framebuffer_map syscall.
    phys_info = .{
        .phys_base = .fromDirectMap(.fromPtr(framebuffer.ptr)),
        .width = @intCast(framebuffer.width),
        .height = @intCast(framebuffer.height),
        .pitch = @intCast(framebuffer.pitch),
        .bpp = 32,
    };

    const virtual_range = try innigkeit.mem.heap.allocateSpecial(
        .{
            .physical_range = .from(
                .fromDirectMap(.fromPtr(framebuffer.ptr)),
                .from(framebuffer.height * framebuffer.pitch, .byte),
            ),
            .protection = .{ .write = true },
            .cache = .write_combining,
        },
    );
    errdefer innigkeit.mem.heap.deallocateSpecial(virtual_range);

    const flanterm_context = c.flanterm_fb_init(
        struct {
            fn flantermMalloc(size: usize) callconv(.c) ?*anyopaque {
                return innigkeit.mem.heap.c.mallocWithSizedFree(size);
            }
        }.flantermMalloc,
        struct {
            fn flantermFree(raw_ptr: ?*anyopaque, size: usize) callconv(.c) void {
                innigkeit.mem.heap.c.sizedFree(@ptrCast(raw_ptr), size);
            }
        }.flantermFree,
        virtual_range.address.toPtr([*]u32),
        framebuffer.width,
        framebuffer.height,
        framebuffer.pitch,
        framebuffer.red_mask_size,
        framebuffer.red_mask_shift,
        framebuffer.green_mask_size,
        framebuffer.green_mask_shift,
        framebuffer.blue_mask_size,
        framebuffer.blue_mask_shift,
        null,
        null,
        null,
        null,
        null,
        null,
        null,
        @constCast(font),
        8,
        16,
        1,
        1,
        1,
        0,
        0,
    ) orelse return error.FailedToInitializeFramebuffer;

    return .{
        .name = Output.Name.fromSlice("flanterm framebuffer") catch unreachable,
        .writeFn = struct {
            fn writeFn(con: *anyopaque, str: []const u8) void {
                const context: *c.flanterm_context = @ptrCast(@alignCast(con));
                Output.writeWithCarridgeReturns(context, flantermWrite, str);
            }
        }.writeFn,
        .splatFn = struct {
            fn splatFn(con: *anyopaque, str: []const u8, splat: usize) void {
                const context: *c.flanterm_context = @ptrCast(@alignCast(con));
                for (0..splat) |_| c.flanterm_write(context, str.ptr, str.len);
            }
        }.splatFn,
        .state = flanterm_context,
    };
}

fn flantermWrite(context: *c.flanterm_context, str: []const u8) void {
    c.flanterm_write(context, str.ptr, str.len);
}

const font = @embedFile("simple.font");
