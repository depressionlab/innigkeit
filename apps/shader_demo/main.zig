const std = @import("std");
const innigkeit = @import("innigkeit");

// TODO: implement better rng via `std.Random` and `architecture`
var rng: u32 = 0o33653337357;
inline fn xrand() u32 {
    rng ^= rng << 0xd;
    rng ^= rng >> 0o21;
    rng ^= rng << 0o5;
    return rng;
}

fn renderPlasma(buf: []u32, W: u32, H: u32, t: u32) void {
    const t8: u8 = @truncate(t);
    const cx: i32 = @intCast(W / 2);
    const cy: i32 = @intCast(H / 2);
    const scale: u32 = W / 2 + H / 2; // used to normalise Manhattan distance

    var y: u32 = 0;
    while (y < H) : (y += 1) {
        const y8: u8 = @truncate(y * 256 / H);
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            const x8: u8 = @truncate(x * 256 / W);

            const v1 = innigkeit.graphics.sin8(x8 *% 3 +% t8);
            const v2 = innigkeit.graphics.sin8(y8 *% 2 +% (t8 *% 2));
            const v3 = innigkeit.graphics.sin8((x8 +% y8) +% (t8 *% 3));

            // Distance-based wave: cheap L1 norm avoids isqrt
            const adx: u32 = @abs(@as(i32, @intCast(x)) - cx);
            const ady: u32 = @abs(@as(i32, @intCast(y)) - cy);
            const d8: u8 = @truncate((adx + ady) * 256 / scale);
            const v4 = innigkeit.graphics.sin8(d8 +% (t8 *% 4));

            const sum: u8 = @as(u8, @bitCast(v1)) +% @as(u8, @bitCast(v2)) +%
                @as(u8, @bitCast(v3)) +% @as(u8, @bitCast(v4));
            buf[y * W + x] = innigkeit.graphics.rainbow[sum].toPixel();
        }
    }
}

const TunnelPx = extern struct { tu_base: u8, ang: u8 };

fn buildTunnelTable(tbl: []TunnelPx, W: u32, H: u32) void {
    const cx: i32 = @intCast(W / 2);
    const cy: i32 = @intCast(H / 2);

    var y: u32 = 0;
    while (y < H) : (y += 1) {
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            const dx: i32 = @as(i32, @intCast(x)) - cx;
            const dy: i32 = @as(i32, @intCast(y)) - cy;
            const adx: u32 = @abs(dx);
            const ady: u32 = @abs(dy);
            const dist = innigkeit.graphics.isqrt(adx * adx + ady * ady);
            const dist_inv: u32 = if (dist > 0) 2048 / dist else 0;
            tbl[y * W + x] = .{
                .tu_base = @truncate(dist_inv),
                .ang = innigkeit.graphics.atan2u(dy, dx),
            };
        }
    }
}

fn renderTunnel(buf: []u32, W: u32, H: u32, t: u32, tbl: ?[]const TunnelPx) void {
    const t8: u8 = @truncate(t);

    if (tbl) |table| {
        // Fast path: precomputed per-pixel values, no isqrt/atan2 per pixel.
        var i: u32 = 0;
        const n = W * H;
        while (i < n) : (i += 1) {
            const e = table[i];
            const tu: u8 = e.tu_base -% (t8 *% 3);
            const tv: u8 = e.ang +% (t8 *% 1);
            buf[i] = innigkeit.graphics.rainbow[tu +% tv].toPixel();
        }
        return;
    }

    // Fallback: compute per pixel (used when mmap failed).
    const cx: i32 = @intCast(W / 2);
    const cy: i32 = @intCast(H / 2);
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        var x: u32 = 0;
        while (x < W) : (x += 1) {
            const dx: i32 = @as(i32, @intCast(x)) - cx;
            const dy: i32 = @as(i32, @intCast(y)) - cy;
            const adx: u32 = @abs(dx);
            const ady: u32 = @abs(dy);

            const dist = innigkeit.graphics.isqrt(adx * adx + ady * ady);
            const ang = innigkeit.graphics.atan2u(dy, dx);

            const dist_inv: u32 = if (dist > 0) 2048 / dist else 0;
            const tu: u8 = @as(u8, @truncate(dist_inv)) -% (t8 *% 3);
            const tv: u8 = ang +% (t8 *% 1);
            buf[y * W + x] = innigkeit.graphics.rainbow[tu +% tv].toPixel();
        }
    }
}

const FIRE_W: u32 = 320;
const FIRE_H: u32 = 200;
var fire_state: [FIRE_H * FIRE_W]u8 = .{0} ** (FIRE_H * FIRE_W);

// Comptime fire color palette: black -> red -> orange -> yellow -> white
const fire_pal: [256]u32 = blk: {
    @setEvalBranchQuota(10000);
    var p: [256]u32 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const t: u32 = i;
        const r: u32 = @min(255, t * 3);
        const g: u32 = if (t < 128) 0 else @min(255, (t - 128) * 4);
        const b: u32 = if (t < 220) 0 else @min(255, (t - 220) * 8);
        p[i] = (r << 16) | (g << 8) | b;
    }
    break :blk p;
};

fn updateFire() void {
    // Seed the base row with strong heat, occasionally cooling
    var x: u32 = 0;
    while (x < FIRE_W) : (x += 1) {
        const r = xrand();
        fire_state[(FIRE_H - 1) * FIRE_W + x] = if ((r & 3) != 0) 255 else @truncate(r >> 4);
    }
    // Propagate heat upward with random horizontal spread
    var fy: u32 = 0;
    while (fy < FIRE_H - 1) : (fy += 1) {
        x = 0;
        while (x < FIRE_W) : (x += 1) {
            const r = xrand();
            // Spread 0 or -1 pixels horizontally
            const spread: i32 = @as(i32, @intCast(r & 3)) - 1; // -1, 0, 1, 2
            const src_x: u32 = blk: {
                const s: i32 = @as(i32, @intCast(x)) + spread;
                if (s < 0) break :blk 0;
                if (s >= @as(i32, FIRE_W)) break :blk FIRE_W - 1;
                break :blk @intCast(s);
            };
            const below: u32 = fire_state[(fy + 1) * FIRE_W + src_x];
            const decay: u32 = r & 3; // 0..3
            fire_state[fy * FIRE_W + x] = @intCast(if (below > decay) below - decay else 0);
        }
    }
}

fn renderFire(buf: []u32, W: u32, H: u32) void {
    const sx = W / FIRE_W;
    const sy = H / FIRE_H;
    const ox = (W - FIRE_W * sx) / 2;
    const oy = (H - FIRE_H * sy) / 2;
    const fire_bottom = oy + FIRE_H * sy;

    // Destination-centric: iterate output rows sequentially for cache efficiency.
    // Each output pixel is written exactly once via @memset, no separate clear needed.
    var y: u32 = 0;
    while (y < H) : (y += 1) {
        const row = buf[y * W ..][0..W];
        if (y < oy or y >= fire_bottom) {
            @memset(row, 0);
            continue;
        }
        const fy = (y - oy) / sy;
        const fire_row = fire_state[fy * FIRE_W ..][0..FIRE_W];
        @memset(row[0..ox], 0);
        var out_x: u32 = ox;
        var fx: u32 = 0;
        while (fx < FIRE_W) : (fx += 1) {
            @memset(row[out_x..][0..sx], fire_pal[fire_row[fx]]);
            out_x += sx;
        }
        if (out_x < W) @memset(row[out_x..], 0);
    }
}

fn renderLissajous(buf: []u32, W: u32, H: u32, frame: u32) void {
    // Decay all pixels: multiply each channel by ~15/16
    for (buf) |*p| {
        const px = p.*;
        const d = (px >> 4) & 0x0F0F0F0F; // extract 1/16 of each channel
        p.* = px -% d;
    }

    const acx: i32 = @intCast(W / 2);
    const acy: i32 = @intCast(H / 2);
    const arx: i32 = @intCast(W * 2 / 5);
    const ary: i32 = @intCast(H * 2 / 5);
    const delta: u8 = @truncate(frame);

    // Trace the a=3, b=2 Lissajous curve (512 points)
    var ti: u32 = 0;
    while (ti < 512) : (ti += 1) {
        const t8: u8 = @truncate(ti);
        const sx = @divTrunc(@as(i32, innigkeit.graphics.sin8(t8 *% 3)) * arx, 127);
        const sy = @divTrunc(@as(i32, innigkeit.graphics.sin8(t8 *% 2 +% delta)) * ary, 127);
        const px_: i32 = acx + sx;
        const py_: i32 = acy + sy;
        if (px_ >= 0 and py_ >= 0) {
            const px: u32 = @intCast(px_);
            const py: u32 = @intCast(py_);
            if (px < W and py < H) {
                const idx = py * W + px;
                const cur = buf[idx];
                const nr: u32 = @min(255, ((cur >> 16) & 0xFF) + 50);
                const ng: u32 = @min(255, ((cur >> 8) & 0xFF) + 80);
                const nb: u32 = @min(255, (cur & 0xFF) + 160);
                buf[idx] = (nr << 16) | (ng << 8) | nb;
            }
        }
    }

    // Bright moving dot at the curve head
    const head_t: u8 = @truncate(frame *% 2);
    const hsx = @divTrunc(@as(i32, innigkeit.graphics.sin8(head_t *% 3)) * arx, 127);
    const hsy = @divTrunc(@as(i32, innigkeit.graphics.sin8(head_t *% 2 +% delta)) * ary, 127);
    const hpx: i32 = acx + hsx;
    const hpy: i32 = acy + hsy;
    {
        var dy: i32 = -3;
        while (dy <= 3) : (dy += 1) {
            var dx: i32 = -3;
            while (dx <= 3) : (dx += 1) {
                if (dx * dx + dy * dy > 9) continue;
                const ppx = hpx + dx;
                const ppy = hpy + dy;
                if (ppx >= 0 and ppy >= 0) {
                    const ux: u32 = @intCast(ppx);
                    const uy: u32 = @intCast(ppy);
                    if (ux < W and uy < H) buf[uy * W + ux] = 0xFF_FF_FF;
                }
            }
        }
    }
}

const EFFECT_NAMES = [_][]const u8{ "Plasma", "Tunnel", "Fire", "Lissajous" };

fn drawHud(canvas: innigkeit.graphics.Canvas, fps: u32, effect: u32) void {
    canvas.fillRect(0, 0, canvas.width, 34, .init(16, 16, 32));
    canvas.drawFmt(8, 4, .white, null, "{d} fps", .{fps});
    canvas.drawFmt(8, 16, .init(180, 185, 255), null, "[{s}]  1:Plasma  2:Tunnel  3:Fire  4:Lissajous  Esc:quit", .{EFFECT_NAMES[effect % 4]});
}

/// Nearest-neighbour 2x upscale: each src pixel becomes a 2x2 block at dst.
/// Reads src sequentially (cache-friendly); writes dst sequentially to WC fb.
fn blitScaled2x(dst: innigkeit.graphics.Canvas, src: []const u32, sw: u32, sh: u32) void {
    var sy: u32 = 0;
    while (sy < sh) : (sy += 1) {
        const src_row = src[sy * sw ..][0..sw];
        var dy: u32 = 0;
        while (dy < 2) : (dy += 1) {
            const dst_row = dst.pixels[(sy * 2 + dy) * dst.stride ..][0 .. sw * 2];
            var sx2: u32 = 0;
            while (sx2 < sw) : (sx2 += 1) {
                const px = src_row[sx2];
                dst_row[sx2 * 2] = px;
                dst_row[sx2 * 2 + 1] = px;
            }
        }
    }
}

pub fn main() void {
    const framebuffer = innigkeit.display.framebufferMap() catch return;
    const canvas: innigkeit.graphics.Canvas = .fromFb(framebuffer.pixels, framebuffer.info);
    const W = canvas.width;
    const H = canvas.height;

    // Allocate back buffer
    const buf_bytes = innigkeit.mem.mmap(
        @as(usize, W) * @as(usize, H) * 4,
        .{ .read = true, .write = true },
    ) catch return;
    defer innigkeit.mem.munmap(buf_bytes) catch {};

    const back_raw = @as([*]u32, @ptrCast(@alignCast(buf_bytes.ptr)))[0 .. @as(usize, W) * @as(usize, H)];
    var back: innigkeit.graphics.Buffer = .{ .pixels = back_raw, .width = W, .height = H, .stride = W };

    // Half-resolution Lissajous accumulation buffer.
    // Decay runs on liss_w*liss_h pixels (1/4 of screen); blitScaled2x upscales to fb.
    const liss_w = W / 2;
    const liss_h = H / 2;
    const liss_bytes = innigkeit.mem.mmap(
        @as(usize, liss_w) * @as(usize, liss_h) * 4,
        .{ .read = true, .write = true },
    ) catch return;
    defer innigkeit.mem.munmap(liss_bytes) catch {};
    const liss_raw = @as([*]u32, @ptrCast(@alignCast(liss_bytes.ptr)))[0 .. @as(usize, liss_w) * @as(usize, liss_h)];
    @memset(liss_raw, 0);

    // Allocate and precompute per-pixel tunnel lookup table.
    // Eliminates isqrt + atan2u from the tunnel inner loop at the cost of ~6 MB.
    const tunnel_tbl: ?[]TunnelPx = blk: {
        const tbl_bytes = innigkeit.mem.mmap(
            @as(usize, W) * @as(usize, H) * @sizeOf(TunnelPx),
            .{ .read = true, .write = true },
        ) catch break :blk null;
        const tbl: []TunnelPx = @alignCast(std.mem.bytesAsSlice(TunnelPx, tbl_bytes));
        buildTunnelTable(tbl, W, H);
        break :blk tbl;
    };
    defer if (tunnel_tbl) |tbl| {
        innigkeit.mem.munmap(std.mem.sliceAsBytes(tbl)) catch {};
    };

    var effect: u32 = 0;
    var frame: u32 = 0;
    var kbd: [16]u8 = undefined;

    var fps: u32 = 0;
    var fps_frames: u32 = 0;
    var fps_time = innigkeit.display.uptimeMs();
    var adaptive: innigkeit.graphics.AdaptiveSync = .{};

    while (true) {
        const t0 = innigkeit.display.uptimeMs();

        // Keyboard input
        const n = innigkeit.display.kbdRead(&kbd);
        for (kbd[0..n]) |sc| {
            if (sc & 0x80 != 0) continue; // ignore key-up scancodes
            switch (sc) {
                0x01 => return, // Escape
                0x02 => effect = 0, // 1
                0x03 => effect = 1, // 2
                0x04 => effect = 2, // 3
                0x05 => effect = 3, // 4
                else => {},
            }
        }

        // Render chosen effec.
        // Lissajous uses a half-res accumulation buffer; all others use back_raw.
        switch (effect % 4) {
            0 => renderPlasma(back_raw, W, H, frame),
            1 => renderTunnel(back_raw, W, H, frame, tunnel_tbl),
            2 => {
                updateFire();
                renderFire(back_raw, W, H);
            },
            3 => renderLissajous(back_raw, liss_w, liss_h, frame),
            else => unreachable,
        }

        // Blit to framebuffer + HUD.
        // Lissajous: 2x scale-blit the small buffer, then draw HUD directly on fb
        //   (fillRect + text = write-only, safe for write-combining mapped pages).
        // Others: HUD into back buffer, then full-res blit.
        if (effect % 4 == 3) {
            blitScaled2x(canvas, liss_raw, liss_w, liss_h);
            drawHud(canvas, fps, effect);
        } else {
            drawHud(back.canvas(), fps, effect);
            back.blitTo(canvas);
        }

        frame +%= 1;
        fps_frames += 1;

        // Update FPS counter each second
        const now = innigkeit.display.uptimeMs();
        if (now -% fps_time >= 1000) {
            fps = fps_frames;
            fps_frames = 0;
            fps_time = now;
        }

        const elapsed = innigkeit.display.uptimeMs() - t0;
        adaptive.recordFrame(elapsed);
        _ = adaptive.sleepForBudget(t0);
    }
}
