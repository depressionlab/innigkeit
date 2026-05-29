const std = @import("std");
const innigkeit = @import("innigkeit");
const Color = innigkeit.graphics.Color;

const DESKTOP: Color = .{ .r = 15, .g = 18, .b = 40 };
const GRID: Color = .{ .r = 20, .g = 23, .b = 50 };
const SB_BG: Color = .{ .r = 10, .g = 12, .b = 28 };
const SB_FG: Color = .{ .r = 175, .g = 185, .b = 215 };
const SB_BORDER: Color = .{ .r = 38, .g = 42, .b = 75 };

const TB_F_TOP: Color = .{ .r = 55, .g = 80, .b = 170 };
const TB_F_BOT: Color = .{ .r = 28, .g = 42, .b = 105 };
const TB_U_TOP: Color = .{ .r = 30, .g = 32, .b = 55 };
const TB_U_BOT: Color = .{ .r = 18, .g = 20, .b = 38 };
const TB_FG_F: Color = .{ .r = 228, .g = 232, .b = 255 };
const TB_FG_U: Color = .{ .r = 105, .g = 110, .b = 140 };

const WIN_F: Color = .{ .r = 17, .g = 19, .b = 38 };
const WIN_U: Color = .{ .r = 13, .g = 14, .b = 30 };
const BORDER_F: Color = .{ .r = 65, .g = 88, .b = 185 };
const BORDER_U: Color = .{ .r = 32, .g = 35, .b = 62 };

// Traffic lights: close / minimize / maximize (macOS-style)
const BT_CLOSE: Color = .{ .r = 255, .g = 95, .b = 86 };
const BT_MIN: Color = .{ .r = 255, .g = 189, .b = 46 };
const BT_MAX: Color = .{ .r = 40, .g = 205, .b = 65 };
const BT_IDLE: Color = .{ .r = 42, .g = 44, .b = 68 };

const SB_H: u32 = 24;
const TB_H: u32 = 28;
const CORNER: u32 = 5;
const BTN_R: i32 = 6;
const BTN_SPACING: u32 = 20;

const Window = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    title: []const u8,
    content: []const u8,
    focused: bool = false,
};

fn drawWindow(canvas: innigkeit.graphics.Canvas, window: Window) void {
    const x = window.x;
    const y = window.y;
    const w = window.w;
    const h = window.h;

    // Drop shadow
    canvas.drawShadow(x, y, w, h, 5, 5, 65);

    // Client area (below titlebar)
    const tb_bot = y + @as(i32, TB_H);
    const client_h = h -| TB_H;
    if (client_h > 0 and tb_bot >= 0) {
        const cx: u32 = @intCast(@max(0, x));
        const cy: u32 = @intCast(@max(0, tb_bot));
        canvas.fillRect(cx, cy, w, client_h, if (window.focused) WIN_F else WIN_U);
    }

    // Titlebar gradient
    if (y >= 0) {
        canvas.fillGradientV(
            @intCast(@max(0, x)),
            @intCast(y),
            w,
            TB_H,
            if (window.focused) TB_F_TOP else TB_U_TOP,
            if (window.focused) TB_F_BOT else TB_U_BOT,
        );
    }

    // Rounded border
    canvas.drawRoundRect(x, y, w, h, CORNER, if (window.focused) BORDER_F else BORDER_U);

    // Traffic light buttons centered vertically in titlebar
    const btn_y = y + @as(i32, TB_H / 2);
    const bc = if (window.focused) BT_CLOSE else BT_IDLE;
    const bm = if (window.focused) BT_MIN else BT_IDLE;
    const bx = if (window.focused) BT_MAX else BT_IDLE;
    canvas.fillCircle(x + 14, btn_y, BTN_R, bc);
    canvas.fillCircle(x + 14 + @as(i32, BTN_SPACING), btn_y, BTN_R, bm);
    canvas.fillCircle(x + 14 + @as(i32, BTN_SPACING) * 2, btn_y, BTN_R, bx);

    // Title text: horizontally centered in titlebar
    const fg = if (window.focused) TB_FG_F else TB_FG_U;
    const tw = innigkeit.graphics.Canvas.textWidth(window.title);
    const tx = x + @as(i32, @intCast(w / 2)) - @as(i32, @intCast(tw / 2));
    if (tx >= 0 and y + 10 >= 0 and tx < @as(i32, @intCast(canvas.width))) {
        canvas.drawText(@intCast(tx), @intCast(@max(0, y + 10)), window.title, fg, null);
    }

    // Content lines
    if (client_h > 0 and tb_bot >= 0) {
        const lx: u32 = @intCast(@max(0, x + 14));
        var ly: i32 = tb_bot + 10;
        var iter = std.mem.splitScalar(u8, window.content, '\n');
        while (iter.next()) |line| {
            if (ly < 0) {
                ly += 14;
                continue;
            }
            if (@as(u32, @intCast(ly)) + 8 > @as(u32, @intCast(@max(0, y))) + h) break;
            canvas.drawText(lx, @intCast(ly), line, Color.light_gray, null);
            ly += 14;
        }
    }

    // Focus hint pinned to bottom of client area
    if (window.focused and client_h > 50 and tb_bot >= 0) {
        const hx: u32 = @intCast(@max(0, x + 14));
        const hy: u32 = @intCast(@max(0, y + @as(i32, @intCast(h -| 18))));
        canvas.drawText(hx, hy, "Tab:next  Arrows:move  Esc:exit", Color{ .r = 52, .g = 62, .b = 105 }, null);
    }
}

fn drawDesktop(canvas: innigkeit.graphics.Canvas, windows: []const Window, fi: usize) void {
    canvas.fill(DESKTOP);

    // Subtle grid overlay
    var gx: u32 = 0;
    while (gx < canvas.width) : (gx += 80)
        canvas.vline(gx, SB_H, canvas.height -| SB_H, GRID);
    var gy: u32 = SB_H + 80;
    while (gy < canvas.height) : (gy += 80)
        canvas.hline(0, gy, canvas.width, GRID);

    // Unfocused windows drawn first, focused window on top
    for (windows, 0..) |win, i| {
        if (i != fi) drawWindow(canvas, win);
    }
    drawWindow(canvas, windows[fi]);

    // Status bar
    canvas.fillRect(0, 0, canvas.width, SB_H, SB_BG);
    canvas.hline(0, SB_H, canvas.width, SB_BORDER);
    canvas.drawText(10, 8, "Innigkeit OS", SB_FG, null);
    // Focused window title, centered
    const ftw = innigkeit.graphics.Canvas.textWidth(windows[fi].title);
    canvas.drawText(canvas.width / 2 -| ftw / 2, 8, windows[fi].title, SB_FG, null);
    // Uptime, right-aligned
    const ms = innigkeit.display.uptimeMs();
    const s = ms / 1000;
    canvas.drawFmt(canvas.width -| 90, 8, SB_FG, null, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, (s / 60) % 60, s % 60 });
}

pub fn main() void {
    const framebuffer = innigkeit.display.framebufferMap() catch return;
    const canvas: innigkeit.graphics.Canvas = .fromFb(framebuffer.pixels, framebuffer.info);
    const W = canvas.width;
    const H = canvas.height;

    // Allocate off-screen back buffer
    const buf_bytes = innigkeit.mem.mmap(
        @as(usize, W) * @as(usize, H) * 4,
        .{ .read = true, .write = true },
    ) catch return;
    defer innigkeit.mem.munmap(buf_bytes) catch {};

    const buf_u32 = @as([*]u32, @ptrCast(@alignCast(buf_bytes.ptr)))[0 .. @as(usize, W) * @as(usize, H)];
    var back: innigkeit.graphics.Buffer = .{ .pixels = buf_u32, .width = W, .height = H, .stride = W };

    // Place windows relative to screen center
    const cx: i32 = @intCast(W / 2);
    const cy: i32 = @intCast(H / 2);

    var windows = [_]Window{
        .{
            .x = cx - 430,
            .y = cy - 260,
            .w = 420,
            .h = 300,
            .title = "Terminal",
            .content =
            \\$ ls /
            \\bin  dev  etc  home  lib
            \\proc  sys  tmp  usr  var
            \\
            \\$ uname -a
            \\Innigkeit 0.1.0 x86_64
            \\
            \\$ _
            ,
            .focused = true,
        },
        .{
            .x = cx - 80,
            .y = cy - 190,
            .w = 380,
            .h = 270,
            .title = "File Manager",
            .content = "  /\n    apps/\n      shell  wm  pixels\n      gfx_demo  shader_demo\n    library/\n      innigkeit/\n    src/\n      innigkeit/\n\n  8 items",
        },
        .{
            .x = cx + 110,
            .y = cy - 60,
            .w = 300,
            .h = 210,
            .title = "System Info",
            .content =
            \\OS: Innigkeit 0.1.0
            \\Kernel: microkernel
            \\Arch: x86_64
            \\Lang: Zig 0.16.0
            \\Boot: Limine / UEFI
            \\
            \\Capabilities: yes
            \\Double-buf: yes
            ,
        },
    };

    var focused: usize = 0;
    var kbd: [16]u8 = undefined;
    var e0 = false;
    var dirty = true;
    var last_second: u64 = std.math.maxInt(u64);
    var adaptive: innigkeit.graphics.AdaptiveSync = .{};

    while (true) {
        const t0 = innigkeit.display.uptimeMs();
        const n = innigkeit.display.kbdRead(&kbd);

        for (kbd[0..n]) |sc| {
            if (sc & 0x80 != 0 and sc != 0xE0) {
                e0 = false;
                continue;
            }

            if (sc == 0xE0) {
                e0 = true;
                continue;
            }

            if (e0) {
                e0 = false;
                const step: i32 = 12;
                switch (sc) {
                    0x48 => {
                        windows[focused].y -= step;
                        dirty = true;
                    }, // up
                    0x50 => {
                        windows[focused].y += step;
                        dirty = true;
                    }, // down
                    0x4B => {
                        windows[focused].x -= step;
                        dirty = true;
                    }, // left
                    0x4D => {
                        windows[focused].x += step;
                        dirty = true;
                    }, // right
                    else => {},
                }
                continue;
            }

            switch (sc) {
                0x01 => return, // Escape
                0x0F => { // Tab: cycle focus
                    windows[focused].focused = false;
                    focused = (focused + 1) % windows.len;
                    windows[focused].focused = true;
                    dirty = true;
                },
                else => {},
            }
        }

        // Redraw once per second to keep the uptime clock fresh.
        const cur_second = innigkeit.display.uptimeMs() / 1000;
        if (cur_second != last_second) {
            last_second = cur_second;
            dirty = true;
        }

        if (dirty) {
            drawDesktop(back.canvas(), &windows, focused);
            back.blitTo(canvas);
            dirty = false;
        }

        const elapsed = innigkeit.display.uptimeMs() - t0;
        adaptive.recordFrame(elapsed);
        _ = adaptive.sleepForBudget(t0);
    }
}
