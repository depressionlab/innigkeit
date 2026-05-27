//! pixels: framebuffer smoke test.
//!
//! Maps the bootloader framebuffer, draws a gradient + a white border,
//! then prints dimensions and exits.
const innigkeit = @import("innigkeit");

pub fn main() void {
    const fb = innigkeit.display.framebufferMap() catch |err| {
        innigkeit.io.stdout.print("pixels: framebuffer_map failed: {}\n", .{err}) catch {};
        return;
    };

    const info = fb.info;
    const pixels = fb.pixels;
    const stride = info.stride();

    innigkeit.io.stdout.print(
        "pixels: framebuffer {}x{} pitch={} bpp={}\n",
        .{ info.width, info.height, info.pitch, info.bpp },
    ) catch {};

    // Draw a full-screen gradient: R increases left->right, G increases top->bottom.
    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        var x: u32 = 0;
        while (x < info.width) : (x += 1) {
            const r: u32 = x * 255 / info.width;
            const g: u32 = y * 255 / info.height;
            const b: u32 = 128;
            pixels[y * stride + x] = (r << 16) | (g << 8) | b;
        }
    }

    // Draw a white 4-pixel border so we can see the display boundaries.
    const border = 4;
    var i: u32 = 0;
    while (i < info.width) : (i += 1) {
        var j: u32 = 0;
        while (j < border) : (j += 1) {
            pixels[j * stride + i] = 0xFFFFFF;
            pixels[(info.height - 1 - j) * stride + i] = 0xFFFFFF;
        }
    }
    i = 0;
    while (i < info.height) : (i += 1) {
        var j: u32 = 0;
        while (j < border) : (j += 1) {
            pixels[i * stride + j] = 0xFFFFFF;
            pixels[i * stride + (info.width - 1 - j)] = 0xFFFFFF;
        }
    }

    innigkeit.io.stdout.print("pixels: done gradient + border drawn\n", .{}) catch {};
}
