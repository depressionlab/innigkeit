//! gfx_demo: Visual showcase of the Innigkeit graphics library.
//!
//! Draws color bands, circles, rectangles, diagonal lines, text, and a
//! gradient. Waits up to 30 seconds for any keypress, then exits.

const std = @import("std");
const innigkeit = @import("innigkeit");
const gfx = innigkeit.graphics;

pub fn main() void {
    const fb = innigkeit.display.framebufferMap() catch |err| {
        innigkeit.io.stdout.print("gfx_demo: framebuffer_map failed: {}\n", .{err}) catch {};
        return;
    };
    const canvas: innigkeit.graphics.Canvas = .fromFb(fb.pixels, fb.info);
    const W = canvas.width;
    const H = canvas.height;

    // 1. Fill screen black
    canvas.fill(.black);

    // 2. Six color bands across top quarter
    const band_h = H / 4 / 6;
    const bands: [6]innigkeit.graphics.Color = .{ .red, .green, .blue, .yellow, .cyan, .magenta };
    const band_w = W / 6;
    for (&bands, 0..) |color, i| {
        canvas.fillRect(@intCast(i * band_w), 0, band_w, H / 4, color);
        _ = band_h;
    }

    // 3. Filled circles
    const circle_y: i32 = @intCast(H / 4 + 60);
    canvas.fillCircle(80, circle_y, 50, .red);
    canvas.fillCircle(200, circle_y, 40, .green);
    canvas.fillCircle(310, circle_y, 45, .blue);
    canvas.fillCircle(420, circle_y, 35, .yellow);
    canvas.fillCircle(520, circle_y, 50, .cyan);
    canvas.fillCircle(630, circle_y, 40, .purple);

    // 4. Outlined rectangles
    const rect_y = H / 4 + 140;
    canvas.drawRect(20, rect_y, 120, 60, .red);
    canvas.drawRect(160, rect_y, 120, 60, .green);
    canvas.drawRect(300, rect_y, 120, 60, .blue);
    canvas.drawRect(440, rect_y, 120, 60, .yellow);
    canvas.drawRect(580, rect_y, 120, 60, .cyan);
    canvas.drawRect(720, rect_y, 120, 60, .orange);

    // 5. Diagonal lines corner-to-corner
    const mid_y: u32 = H / 2;
    canvas.drawLine(0, @intCast(mid_y), @intCast(W), @intCast(mid_y + 80), .white);
    canvas.drawLine(0, @intCast(mid_y + 80), @intCast(W), @intCast(mid_y), .white);
    canvas.drawLine(0, @intCast(mid_y + 40), @intCast(W), @intCast(mid_y + 40), .light_gray);

    // 6. Text at top
    const title = "Innigkeit OS";
    const title_x = (W -| innigkeit.graphics.Canvas.textWidth(title)) / 2;
    canvas.drawText(title_x, H / 4 + 10, title, .white, .black);
    const sub = "Graphics Demo v0.1";
    const sub_x = (W -| innigkeit.graphics.Canvas.textWidth(sub)) / 2;
    canvas.drawText(sub_x, H / 4 + 22, sub, .light_gray, .black);

    // 7. Gradient in bottom quarter
    const grad_y = H * 3 / 4;
    var x: u32 = 0;
    while (x < W) : (x += 1) {
        const r: u8 = @intCast(x * 255 / W);
        const b: u8 = @intCast(255 - r);
        canvas.vline(x, grad_y, H / 4, .init(r, 80, b));
    }
    canvas.drawText(4, grad_y + 4, "Gradient", .white, null);

    // Instructions
    canvas.drawText(4, H -| 16, "Press any key to exit...", .light_gray, null);

    // 8. Poll for keypress up to 30 seconds
    const start = innigkeit.display.uptimeMs();
    var kbd_buf: [16]u8 = undefined;
    var exiting = false;
    while (!exiting) {
        const now = innigkeit.display.uptimeMs();
        if (now -| start >= 30_000) break;

        const n = innigkeit.display.kbdRead(kbd_buf[0..]);
        if (n > 0) {
            // Any non-release scancode triggers exit
            for (kbd_buf[0..n]) |sc| {
                if (sc != 0 and sc & 0x80 == 0) {
                    exiting = true;
                    break;
                }
            }
        }

        if (!exiting) {
            innigkeit.sleep(16 * std.time.ns_per_ms);
        }
    }

    // 9. On keypress: fill white, print exiting message
    canvas.fill(.white);
    canvas.drawText(40, 40, "Exiting...", .dark_gray, null);
}
