const std = @import("std");
const innigkeit = @import("innigkeit");
const Color = innigkeit.graphics.Color;
const Canvas = innigkeit.graphics.Canvas;
const MouseEvent = innigkeit.display.MouseEvent;

const C_BG_TOP: Color = .{ .r = 10, .g = 13, .b = 28 };
const C_BG_BOT: Color = .{ .r = 5, .g = 7, .b = 16 };
const C_MB_BG: Color = .{ .r = 16, .g = 18, .b = 28 };
const C_MB_SEP: Color = .{ .r = 45, .g = 48, .b = 65 };
const C_MB_FG: Color = .{ .r = 205, .g = 208, .b = 218 };
const C_MB_DIM: Color = .{ .r = 95, .g = 98, .b = 115 };
const C_DOCK_BG: Color = .{ .r = 20, .g = 22, .b = 35 };
const C_DOCK_SEP: Color = .{ .r = 45, .g = 48, .b = 65 };
const C_SEL: Color = .{ .r = 55, .g = 110, .b = 215 };
const C_SEL_RIM: Color = .{ .r = 80, .g = 140, .b = 240 };
const C_LABEL: Color = .{ .r = 190, .g = 192, .b = 205 };
const C_RUN_DOT: Color = .{ .r = 75, .g = 185, .b = 255 };
const C_WHITE: Color = .{ .r = 245, .g = 246, .b = 252 };
const C_CURSOR: Color = .{ .r = 255, .g = 255, .b = 255 };
const C_CURSOR_SH: Color = .{ .r = 0, .g = 0, .b = 0 };

const AppEntry = struct {
    name: [:0]const u8,
    label: []const u8,
    abbrev: []const u8,
    bg: Color, // icon fill color
};

const APPS = [_]AppEntry{
    .{ .name = "shader_demo", .label = "Shader Demo", .abbrev = "SD", .bg = .{ .r = 32, .g = 72, .b = 148 } },
    .{ .name = "gfx_demo", .label = "Graphics", .abbrev = "GX", .bg = .{ .r = 28, .g = 90, .b = 45 } },
    .{ .name = "pixels", .label = "Pixels", .abbrev = "PX", .bg = .{ .r = 80, .g = 32, .b = 110 } },
    .{ .name = "calculator", .label = "Calculator", .abbrev = "CA", .bg = .{ .r = 105, .g = 72, .b = 12 } },
    .{ .name = "doom", .label = "Doom", .abbrev = "DM", .bg = .{ .r = 110, .g = 18, .b = 18 } },
    .{ .name = "shell", .label = "Terminal", .abbrev = "SH", .bg = .{ .r = 18, .g = 80, .b = 100 } },
};

const MB_H: u32 = 28; // menu bar height
const DOCK_H: u32 = 74; // dock strip height
const DOCK_ICON: u32 = 52; // dock icon size
const DOCK_GAP: u32 = 16; // gap between dock icons
const DOCK_R: u32 = 10; // dock icon corner radius

const GRID_ICON: u32 = 108; // desktop icon size
const GRID_ICON_R: u32 = 16; // desktop icon corner radius
const GRID_CELL_W: u32 = 156; // grid cell width
const GRID_CELL_H: u32 = 138; // grid cell height (icon + label)
const GRID_COLS: u32 = 3;
const GRID_ROWS: u32 = 2;

fn deskTop() u32 {
    return MB_H;
}
fn deskBot(H: u32) u32 {
    return H -| DOCK_H;
}
fn deskH(H: u32) u32 {
    return deskBot(H) -| deskTop();
}

fn gridW() u32 {
    return GRID_COLS * GRID_CELL_W;
}
fn gridH() u32 {
    return GRID_ROWS * GRID_CELL_H;
}
fn gridOriginX(W: u32) u32 {
    return (W -| gridW()) / 2;
}
fn gridOriginY(H: u32) u32 {
    return deskTop() + (deskH(H) -| gridH()) / 2;
}

fn iconX(W: u32, i: usize) u32 {
    const col: u32 = @intCast(i % @as(usize, GRID_COLS));
    return gridOriginX(W) + col * GRID_CELL_W + (GRID_CELL_W -| GRID_ICON) / 2;
}
fn iconY(W: u32, H: u32, i: usize) u32 {
    _ = W;
    const row: u32 = @intCast(i / @as(usize, GRID_COLS));
    // center icon+label block vertically in cell (label = 2 rows of 8px + 4px gap = 20px)
    const block_h = GRID_ICON + 20;
    return gridOriginY(H) + row * GRID_CELL_H + (GRID_CELL_H -| block_h) / 2;
}

// Dock icon positions (centered horizontally)
fn dockTotalW() u32 {
    return @as(u32, APPS.len) * DOCK_ICON + (@as(u32, APPS.len) - 1) * DOCK_GAP;
}
fn dockStartX(W: u32) u32 {
    return (W -| dockTotalW()) / 2;
}
fn dockIconX(W: u32, i: usize) u32 {
    return dockStartX(W) + @as(u32, @intCast(i)) * (DOCK_ICON + DOCK_GAP);
}
fn dockIconY(H: u32) u32 {
    return deskBot(H) + (DOCK_H -| DOCK_ICON) / 2;
}

const CURSOR_MAP: [12]u8 = .{
    0b10000000, 0b11000000, 0b10100000, 0b10010000,
    0b10001000, 0b10000100, 0b10011100, 0b10100000,
    0b11000000, 0b10000000, 0b00000000, 0b00000000,
};

fn drawCursor(c: Canvas, mx: i32, my: i32) void {
    const W: i32 = @intCast(c.width);
    const H: i32 = @intCast(c.height);
    for (CURSOR_MAP, 0..) |bits, row| {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            if (bits & (@as(u8, 0x80) >> @as(u3, @intCast(col))) == 0) continue;
            const px: i32 = mx + @as(i32, @intCast(col));
            const py: i32 = my + @as(i32, @intCast(row));
            var dy: i32 = -1;
            while (dy <= 1) : (dy += 1) {
                var dx: i32 = -1;
                while (dx <= 1) : (dx += 1) {
                    const x = px + dx;
                    const y = py + dy;
                    if (x >= 0 and y >= 0 and x < W and y < H)
                        c.putPixel(@intCast(x), @intCast(y), C_CURSOR_SH);
                }
            }
        }
    }
    for (CURSOR_MAP, 0..) |bits, row| {
        var col: usize = 0;
        while (col < 8) : (col += 1) {
            if (bits & (@as(u8, 0x80) >> @as(u3, @intCast(col))) == 0) continue;
            const x: i32 = mx + @as(i32, @intCast(col));
            const y: i32 = my + @as(i32, @intCast(row));
            if (x >= 0 and y >= 0 and x < W and y < H)
                c.putPixel(@intCast(x), @intCast(y), C_CURSOR);
        }
    }
}

fn drawMenuBar(c: Canvas, label: ?[]const u8) void {
    c.fillRect(0, 0, c.width, MB_H, C_MB_BG);
    c.hline(0, MB_H - 1, c.width, C_MB_SEP);
    c.drawTextScaled(12, (MB_H -| 16) / 2, "Innigkeit", 2, C_MB_FG, null);
    if (label) |lbl| {
        const tw = Canvas.textWidth(lbl) * 2;
        c.drawTextScaled((c.width -| tw) / 2, (MB_H -| 16) / 2, lbl, 2, C_MB_FG, null);
    }
    const s = innigkeit.display.uptimeMs() / 1000;
    var buf: [9]u8 = undefined;
    const clk = std.fmt.bufPrint(&buf, "{d:0>2}:{d:0>2}:{d:0>2}", .{ s / 3600, (s / 60) % 60, s % 60 }) catch buf[0..8];
    const cw = @as(u32, @intCast(clk.len)) * 16;
    c.drawTextScaled(c.width -| cw -| 12, (MB_H -| 16) / 2, clk, 2, C_MB_DIM, null);
}

// Draw a single flat icon.
fn drawAppIcon(c: Canvas, x: u32, y: u32, size: u32, radius: u32, app: AppEntry, txt_scale: u32, selected: bool) void {
    if (selected) {
        // 2px selection rim
        c.fillRect(x -| 3, y -| 3, size + 6, size + 6, C_SEL_RIM);
    }
    // Body
    c.fillRoundRect(@intCast(x), @intCast(y), size, size, radius, app.bg);
    // Top sheen: subtle lighter strip (~25% of height)
    c.fillRectAlpha(x, y, size, size / 4, Color.white, 30);
    // Abbreviation centered
    const aw = @as(u32, @intCast(app.abbrev.len)) * 8 * txt_scale;
    const ah = 8 * txt_scale;
    c.drawTextScaled(
        x + (size -| aw) / 2,
        y + (size -| ah) / 2,
        app.abbrev,
        txt_scale,
        C_WHITE,
        null,
    );
}

fn drawDock(c: Canvas, W: u32, H: u32, sel: ?usize, running_idx: ?usize) void {
    c.fillRect(0, deskBot(H), W, DOCK_H, C_DOCK_BG);
    c.hline(0, deskBot(H), W, C_DOCK_SEP);

    for (APPS, 0..) |app, i| {
        const ix = dockIconX(W, i);
        const iy = dockIconY(H);
        const is_sel = if (sel) |s| s == i else false;
        drawAppIcon(c, ix, iy, DOCK_ICON, DOCK_R, app, 1, is_sel);

        // Running indicator: small dot below icon
        if (running_idx) |ri| {
            if (ri == i)
                c.fillCircle(@intCast(ix + DOCK_ICON / 2), @intCast(iy + DOCK_ICON + 6), 3, C_RUN_DOT);
        }
    }
}

fn drawDesktop(c: Canvas, W: u32, H: u32, sel: ?usize) void {
    // Background
    c.fillGradientV(0, deskTop(), W, deskH(H), C_BG_TOP, C_BG_BOT);

    // Grid icons
    for (APPS, 0..) |app, i| {
        const ix = iconX(W, i);
        const iy = iconY(W, H, i);
        const is_sel = if (sel) |s| s == i else false;
        drawAppIcon(c, ix, iy, GRID_ICON, GRID_ICON_R, app, 2, is_sel);
        // Label below icon (1× scale, centered)
        const lw = Canvas.textWidth(app.label);
        c.drawText(ix + (GRID_ICON -| lw) / 2, iy + GRID_ICON + 8, app.label, C_LABEL, null);
    }
}

// Draw a full-screen "launching <name>…" splash to give immediate feedback.
fn drawLaunchSplash(c: Canvas, W: u32, H: u32, app: *const AppEntry) void {
    c.fillRect(0, 0, W, H, C_BG_BOT);
    // Large icon in center
    const ic: u32 = 120;
    const ix: u32 = (W -| ic) / 2;
    const iy: u32 = (H -| ic) / 2 -| 20;
    drawAppIcon(c, ix, iy, ic, 18, app.*, 3, false);
    // "Launching…" label
    const msg = "Launching...";
    const mw = Canvas.textWidth(msg) * 2;
    c.drawTextScaled((W -| mw) / 2, iy + ic + 16, msg, 2, C_LABEL, null);
    const hint = "Esc to cancel";
    const hw = Canvas.textWidth(hint);
    c.drawText((W -| hw) / 2, iy + ic + 36, hint, C_MB_DIM, null);
}

fn gridHit(mx: i32, my: i32, W: u32, H: u32) ?usize {
    for (APPS, 0..) |_, i| {
        const ix: i32 = @intCast(iconX(W, i));
        const iy: i32 = @intCast(iconY(W, H, i));
        if (mx >= ix and mx < ix + GRID_ICON and my >= iy and my < iy + GRID_ICON)
            return i;
    }
    return null;
}

fn dockHit(mx: i32, my: i32, W: u32, H: u32) ?usize {
    if (my < @as(i32, @intCast(deskBot(H)))) return null;
    for (APPS, 0..) |_, i| {
        const ix: i32 = @intCast(dockIconX(W, i));
        const iy: i32 = @intCast(dockIconY(H));
        if (mx >= ix and mx < ix + DOCK_ICON and my >= iy and my < iy + DOCK_ICON)
            return i;
    }
    return null;
}

pub fn main() void {
    const fb = innigkeit.display.framebufferMap() catch return;
    const canvas: Canvas = .fromFb(fb.pixels, fb.info);
    const W = canvas.width;
    const H = canvas.height;

    const buf_bytes = innigkeit.mem.mmap(
        @as(usize, W) * @as(usize, H) * 4,
        .{ .read = true, .write = true },
    ) catch return;
    defer innigkeit.mem.munmap(buf_bytes) catch {};

    const buf_u32 = @as([*]u32, @ptrCast(@alignCast(buf_bytes.ptr)))[0 .. @as(usize, W) * @as(usize, H)];
    var back: innigkeit.graphics.Buffer = .{ .pixels = buf_u32, .width = W, .height = H, .stride = W };

    var running_handle: ?u32 = null;
    var running_idx: ?usize = null;

    var sel: ?usize = null;
    var kbd: [16]u8 = undefined;
    var mouse_evts: [16]MouseEvent = undefined;
    var e0 = false;
    var dirty = true;
    var last_second: u64 = std.math.maxInt(u64);
    var adaptive: innigkeit.graphics.AdaptiveSync = .{};
    var mx: i32 = @intCast(W / 2);
    var my: i32 = @intCast(H / 2);
    var prev_buttons: u8 = 0;

    while (true) {
        if (running_handle) |h| {
            if (innigkeit.process.waitProcessNb(h)) |_| {
                innigkeit.capabilities.delete(h) catch {};
                running_handle = null;
                running_idx = null;
                dirty = true;
                e0 = false;
                // Drain any keyboard input that accumulated while the app ran
                // so stale scancodes (e.g. Esc used to kill the app) don't
                // immediately affect the WM desktop loop.
                var drain: [16]u8 = undefined;
                while (innigkeit.display.kbdRead(&drain) > 0) {}
            } else |_| {
                var kbuf: [4]u8 = undefined;
                const kn = innigkeit.display.kbdRead(&kbuf);
                for (kbuf[0..kn]) |sc| {
                    if (sc == 0x01) innigkeit.process.killProcess(h) catch {};
                }
                innigkeit.sleep(200 * std.time.ns_per_ms);
            }
            continue;
        }

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
                switch (sc) {
                    0x4B, 0x48 => {
                        sel = if (sel) |s| (if (s > 0) s - 1 else s) else 0;
                        dirty = true;
                    },
                    0x4D, 0x50 => {
                        sel = if (sel) |s| (if (s + 1 < APPS.len) s + 1 else s) else 0;
                        dirty = true;
                    },
                    else => {},
                }
                continue;
            }
            e0 = false;
            switch (sc) {
                0x01 => {
                    sel = null;
                    dirty = true;
                }, // Esc: deselect (not exit)
                0x1C => {
                    if (sel) |s| {
                        launch(s, &back, canvas, W, H, &running_handle, &running_idx);
                        dirty = true;
                    }
                },
                else => {},
            }
        }

        const nm = innigkeit.display.mouseRead(&mouse_evts);
        for (mouse_evts[0..nm]) |ev| {
            mx = std.math.clamp(mx + ev.dx, 0, @as(i32, @intCast(W)) - 1);
            my = std.math.clamp(my - ev.dy, 0, @as(i32, @intCast(H)) - 1);
            dirty = true;
            const hovered = dockHit(mx, my, W, H) orelse gridHit(mx, my, W, H);
            if (hovered != sel) sel = hovered;
            const just_pressed = ev.buttons & ~prev_buttons & 0x01;
            if (just_pressed != 0) {
                if (dockHit(mx, my, W, H) orelse gridHit(mx, my, W, H)) |c| {
                    sel = c;
                    launch(c, &back, canvas, W, H, &running_handle, &running_idx);
                }
            }
            prev_buttons = ev.buttons;
        }

        const cur_sec = innigkeit.display.uptimeMs() / 1000;
        if (cur_sec != last_second) {
            last_second = cur_sec;
            dirty = true;
        }

        // Skip render if an app was just launched, the splash drawn in launch()
        // stays visible until the app exits and running_handle returns to null.
        if (dirty and running_handle == null) {
            const bc = back.canvas();
            drawDesktop(bc, W, H, sel);
            drawMenuBar(bc, null);
            drawDock(bc, W, H, sel, running_idx);
            back.blitTo(canvas);
            drawCursor(canvas, mx, my);
            innigkeit.display.gpuFlush(W, H);
            dirty = false;
        }

        const elapsed = innigkeit.display.uptimeMs() - t0;
        adaptive.recordFrame(elapsed);
        _ = adaptive.sleepForBudget(t0);
    }
}

// Show a launch splash immediately (so the user gets instant feedback),
// then spawn the app. If spawn fails the desktop will redraw on the next
// frame (dirty stays true).
fn launch(idx: usize, back: *innigkeit.graphics.Buffer, canvas: Canvas, W: u32, H: u32, handle_out: *?u32, idx_out: *?usize) void {
    // Splash: render to back buffer, blit, flush visible within one frame.
    const bc = back.canvas();
    drawLaunchSplash(bc, W, H, &APPS[idx]);
    back.blitTo(canvas);
    innigkeit.display.gpuFlush(W, H);

    const h = innigkeit.process.spawnArgs(APPS[idx].name, &.{}) catch return;
    handle_out.* = h;
    idx_out.* = idx;
}
