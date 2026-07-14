//! pixels: framebuffer smoke test.
//!
//! Maps the bootloader framebuffer, draws a gradient + a white border,
//! then prints dimensions and exits.
// zlinter-disable no_swallow_error - every catch here is a console print
// with no meaningful recovery path in this smoke-test app.
const innigkeit = @import("innigkeit");

pub fn main() void {
    const fb = innigkeit.display.framebufferMap() catch |err| {
        innigkeit.io.stdout.print("pixels: framebuffer_map failed: {}\n", .{err}) catch {};
        return;
    };

    const info = fb.info;

    innigkeit.io.stdout.print(
        "pixels: framebuffer {}x{} pitch={} bpp={}\n",
        .{ info.width, info.height, info.pitch, info.bpp },
    ) catch {};

    const canvas: innigkeit.graphics.Canvas = .fromFb(fb.pixels, fb.info);

    // Draw a full-screen gradient: R increases left->right, G increases top->bottom.
    var y: u32 = 0;
    while (y < info.height) : (y += 1) {
        var x: u32 = 0;
        while (x < info.width) : (x += 1) {
            const r: u8 = @intCast(x * 255 / info.width);
            const g: u8 = @intCast(y * 255 / info.height);
            canvas.putPixel(x, y, .init(r, g, 128));
        }
    }

    // Draw a white 4-pixel border so we can see the display boundaries.
    const border = 4;
    canvas.fillRect(0, 0, info.width, border, .white);
    canvas.fillRect(0, info.height -| border, info.width, border, .white);
    canvas.fillRect(0, 0, border, info.height, .white);
    canvas.fillRect(info.width -| border, 0, border, info.height, .white);

    innigkeit.io.stdout.print("pixels: done gradient + border drawn\n", .{}) catch {};
}
