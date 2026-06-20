const std = @import("std");
const innigkeit = @import("innigkeit");

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn init(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b };
    }

    /// Convert to a 32-bit BGRX pixel value (blue=bits[7:0]).
    pub fn toPixel(self: Color) u32 {
        return (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | @as(u32, self.b);
    }

    /// Simple alpha blend: fg over bg with alpha 0..255.
    pub fn blend(fg: Color, bg: Color, alpha: u8) Color {
        const a: u32 = alpha;
        return .{
            .r = @truncate((fg.r * a + bg.r * (255 - a)) / 255),
            .g = @truncate((fg.g * a + bg.g * (255 - a)) / 255),
            .b = @truncate((fg.b * a + bg.b * (255 - a)) / 255),
        };
    }

    pub const black: Color = .init(0, 0, 0);
    pub const white: Color = .init(255, 255, 255);
    pub const red: Color = .init(255, 0, 0);
    pub const green: Color = .init(0, 200, 0);
    pub const blue: Color = .init(0, 0, 255);
    pub const gray: Color = .init(128, 128, 128);
    pub const dark_gray: Color = .init(48, 48, 48);
    pub const light_gray: Color = .init(200, 200, 200);
    pub const yellow: Color = .init(255, 255, 0);
    pub const cyan: Color = .init(0, 220, 220);
    pub const orange: Color = .init(255, 160, 0);
    pub const purple: Color = .init(160, 0, 200);
    pub const magenta: Color = .init(255, 0, 255);
};

/// A pixel buffer in normal (non-volatile) memory for off-screen rendering.
/// After drawing, call canvas.blitTo(framebuffer_canvas) to copy to screen.
pub const Buffer = struct {
    pixels: []u32, // owned slice (caller provides, typically via mmap)
    width: u32,
    height: u32,
    stride: u32, // = width (no padding)

    pub fn canvas(self: *Buffer) Canvas {
        return .{
            .pixels = self.pixels.ptr,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
        };
    }

    /// Fill the entire buffer with `color`. Uses @memset for SIMD-optimized fill.
    pub fn fill(self: *Buffer, color: Color) void {
        @memset(self.pixels, color.toPixel());
    }

    /// Blit this buffer to a canvas row-by-row using @memcpy.
    pub fn blitTo(self: Buffer, dst: Canvas) void {
        const copy_w = @min(self.width, dst.width);
        const copy_h = @min(self.height, dst.height);
        var y: u32 = 0;
        while (y < copy_h) : (y += 1) {
            @memcpy(
                dst.pixels[y * dst.stride ..][0..copy_w],
                self.pixels[y * self.stride ..][0..copy_w],
            );
        }
    }
};

pub const Canvas = struct {
    pixels: [*]u32,
    width: u32,
    height: u32,
    stride: u32,

    /// Construct from the result of innigkeit.display.framebufferMap().
    pub fn fromFb(pixels: [*]volatile u32, info: innigkeit.display.FramebufferInfo) Canvas {
        return .{
            .pixels = @volatileCast(pixels),
            .width = info.width,
            .height = info.height,
            .stride = info.stride(),
        };
    }

    /// Write a single pixel at (x, y). Out-of-bounds writes are silently dropped.
    pub fn putPixel(self: Canvas, x: u32, y: u32, color: Color) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.stride + x] = color.toPixel();
    }

    /// Fill the entire canvas with `color`.
    pub fn fill(self: Canvas, color: Color) void {
        const px = color.toPixel();
        if (self.stride == self.width) {
            @memset(self.pixels[0 .. self.height * self.width], px);
        } else {
            var row: u32 = 0;
            while (row < self.height) : (row += 1) {
                @memset(self.pixels[row * self.stride ..][0..self.width], px);
            }
        }
    }

    /// Fill a rectangle with `color`. Clipped to canvas bounds.
    pub fn fillRect(self: Canvas, x: u32, y: u32, w: u32, h: u32, color: Color) void {
        const x1 = @min(x +| w, self.width);
        const y1 = @min(y +| h, self.height);
        if (x >= self.width or y >= self.height or x1 <= x or y1 <= y) return;
        const px = color.toPixel();
        var row = y;
        while (row < y1) : (row += 1) {
            @memset(self.pixels[row * self.stride + x ..][0 .. x1 - x], px);
        }
    }

    /// Draw a 1-pixel-wide rectangle outline. Clipped to canvas bounds.
    pub fn drawRect(self: Canvas, x: u32, y: u32, w: u32, h: u32, color: Color) void {
        if (w == 0 or h == 0) return;
        const x1 = x +| (w - 1);
        const y1 = y +| (h - 1);
        self.hline(x, y, w, color);
        self.hline(x, y1, w, color);
        self.vline(x, y, h, color);
        self.vline(x1, y, h, color);
    }

    /// Draw a horizontal line of `w` pixels starting at (x, y).
    pub fn hline(self: Canvas, x: u32, y: u32, w: u32, color: Color) void {
        if (y >= self.height) return;
        const x1 = @min(x +| w, self.width);
        if (x >= self.width or x1 <= x) return;
        @memset(self.pixels[y * self.stride + x ..][0 .. x1 - x], color.toPixel());
    }

    /// Draw a vertical line of `h` pixels starting at (x, y).
    pub fn vline(self: Canvas, x: u32, y: u32, h: u32, color: Color) void {
        if (x >= self.width) return;
        const y1 = @min(y +| h, self.height);
        if (y >= self.height) return;
        const px = color.toPixel();
        var row = y;
        while (row < y1) : (row += 1) {
            self.pixels[row * self.stride + x] = px;
        }
    }

    /// Draw a line from (x0,y0) to (x1,y1) using Bresenham's algorithm.
    pub fn drawLine(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, color: Color) void {
        var cx0 = x0;
        var cy0 = y0;
        const dx: i32 = @intCast(@abs(x1 - x0));
        const dy: i32 = @intCast(@abs(y1 - y0));
        const sx: i32 = if (x0 < x1) 1 else -1;
        const sy: i32 = if (y0 < y1) 1 else -1;
        var err: i32 = dx - dy;

        while (true) {
            if (cx0 >= 0 and cy0 >= 0) {
                self.putPixel(@intCast(cx0), @intCast(cy0), color);
            }
            if (cx0 == x1 and cy0 == y1) break;
            const e2 = 2 * err;
            if (e2 > -dy) {
                err -= dy;
                cx0 += sx;
            }
            if (e2 < dx) {
                err += dx;
                cy0 += sy;
            }
        }
    }

    /// Return a sub-canvas covering the rectangle (x, y, w, h) within this canvas.
    /// The sub-canvas shares the same pixel buffer; writes are clipped to the
    /// intersection of the requested region and the parent's bounds.
    pub fn sub(self: Canvas, x: u32, y: u32, w: u32, h: u32) Canvas {
        const cx = @min(x, self.width);
        const cy = @min(y, self.height);
        const cw = @min(w, self.width -| cx);
        const ch = @min(h, self.height -| cy);
        return .{
            .pixels = self.pixels + cy * self.stride + cx,
            .width = cw,
            .height = ch,
            .stride = self.stride,
        };
    }

    /// Blit this canvas to dst row-by-row using @memcpy.
    pub fn blitTo(self: Canvas, dst: Canvas) void {
        const copy_w = @min(self.width, dst.width);
        const copy_h = @min(self.height, dst.height);
        var y: u32 = 0;
        while (y < copy_h) : (y += 1) {
            @memcpy(
                dst.pixels[y * dst.stride ..][0..copy_w],
                self.pixels[y * self.stride ..][0..copy_w],
            );
        }
    }

    /// Alpha-blend a single pixel (inline, used by shape drawing).
    inline fn blendPixel(self: Canvas, x: u32, y: u32, color: Color, alpha: u8) void {
        if (x >= self.width or y >= self.height) return;
        const a: u32 = alpha;
        const ia: u32 = 255 - a;
        const dst_px = self.pixels[y * self.stride + x];
        const dr: u32 = (dst_px >> 16) & 0xFF;
        const dg: u32 = (dst_px >> 8) & 0xFF;
        const db: u32 = dst_px & 0xFF;
        const sr: u32 = color.r;
        const sg: u32 = color.g;
        const sb: u32 = color.b;
        // Fast 8-bit multiply: (x * y + 128) >> 8
        const r: u32 = (sr * a + dr * ia + 128) >> 8;
        const g: u32 = (sg * a + dg * ia + 128) >> 8;
        const b: u32 = (sb * a + db * ia + 128) >> 8;
        self.pixels[y * self.stride + x] = (r << 16) | (g << 8) | b;
    }

    /// Alpha-blend a color onto every pixel in the rect. alpha=255 is opaque.
    pub fn fillRectAlpha(self: Canvas, x: u32, y: u32, w: u32, h: u32, color: Color, alpha: u8) void {
        if (alpha == 0) return;
        if (alpha == 255) {
            self.fillRect(x, y, w, h, color);
            return;
        }
        const x1 = @min(x +| w, self.width);
        const y1 = @min(y +| h, self.height);
        if (x >= self.width or y >= self.height or x1 <= x or y1 <= y) return;
        const a: u32 = alpha;
        const ia: u32 = 255 - a;
        const sr: u32 = color.r;
        const sg: u32 = color.g;
        const sb: u32 = color.b;
        var row = y;
        while (row < y1) : (row += 1) {
            var col = x;
            while (col < x1) : (col += 1) {
                const dst_px = self.pixels[row * self.stride + col];
                const dr: u32 = (dst_px >> 16) & 0xFF;
                const dg: u32 = (dst_px >> 8) & 0xFF;
                const db: u32 = dst_px & 0xFF;
                const r: u32 = (sr * a + dr * ia + 128) >> 8;
                const g: u32 = (sg * a + dg * ia + 128) >> 8;
                const b: u32 = (sb * a + db * ia + 128) >> 8;
                self.pixels[row * self.stride + col] = (r << 16) | (g << 8) | b;
            }
        }
    }

    /// Horizontal gradient from c1 (left) to c2 (right).
    pub fn fillGradientH(self: Canvas, x: u32, y: u32, w: u32, h: u32, c1: Color, c2: Color) void {
        if (w == 0 or h == 0) return;
        const x1 = @min(x +| w, self.width);
        const y1 = @min(y +| h, self.height);
        if (x >= self.width or y >= self.height or x1 <= x or y1 <= y) return;
        if (w == 1) {
            const px = c1.toPixel();
            var row = y;
            while (row < y1) : (row += 1) self.pixels[row * self.stride + x] = px;
            return;
        }
        const steps = w;
        var row = y;
        while (row < y1) : (row += 1) {
            var col = x;
            while (col < x1) : (col += 1) {
                const t = col - x; // 0..w-1
                const r: u32 = (@as(u32, c1.r) * (steps - 1 - t) + @as(u32, c2.r) * t) / (steps - 1);
                const g: u32 = (@as(u32, c1.g) * (steps - 1 - t) + @as(u32, c2.g) * t) / (steps - 1);
                const b: u32 = (@as(u32, c1.b) * (steps - 1 - t) + @as(u32, c2.b) * t) / (steps - 1);
                self.pixels[row * self.stride + col] = (r << 16) | (g << 8) | b;
            }
        }
    }

    /// Vertical gradient from c1 (top) to c2 (bottom).
    pub fn fillGradientV(self: Canvas, x: u32, y: u32, w: u32, h: u32, c1: Color, c2: Color) void {
        if (w == 0 or h == 0) return;
        const x1 = @min(x +| w, self.width);
        const y1 = @min(y +| h, self.height);
        if (x >= self.width or y >= self.height) return;
        const steps = h;
        var row = y;
        while (row < y1) : (row += 1) {
            const t = row - y; // 0..h-1
            const r: u32 = if (steps <= 1) c1.r else (@as(u32, c1.r) * (steps - 1 - t) + @as(u32, c2.r) * t) / (steps - 1);
            const g: u32 = if (steps <= 1) c1.g else (@as(u32, c1.g) * (steps - 1 - t) + @as(u32, c2.g) * t) / (steps - 1);
            const b: u32 = if (steps <= 1) c1.b else (@as(u32, c1.b) * (steps - 1 - t) + @as(u32, c2.b) * t) / (steps - 1);
            @memset(self.pixels[row * self.stride + x ..][0 .. x1 - x], (r << 16) | (g << 8) | b);
        }
    }

    /// Filled circle using MSAA 2x2 supersampling for anti-aliased edges.
    pub fn fillCircle(self: Canvas, cx: i32, cy: i32, r: i32, color: Color) void {
        if (r <= 0) return;
        const r4 = r * 4;
        const r4sq = r4 * r4;
        const cx4 = cx * 4;
        const cy4 = cy * 4;

        const bx0 = @max(0, cx - r - 1);
        const by0 = @max(0, cy - r - 1);
        const bx1: i32 = @min(@as(i32, @intCast(self.width)), cx + r + 2);
        const by1: i32 = @min(@as(i32, @intCast(self.height)), cy + r + 2);

        var py: i32 = by0;
        while (py < by1) : (py += 1) {
            var px: i32 = bx0;
            while (px < bx1) : (px += 1) {
                // Test 4 sub-pixel samples at (px*4 ± 1, py*4 ± 1)
                const px4 = px * 4;
                const py4 = py * 4;
                var count: u32 = 0;
                const offsets = [4][2]i32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
                for (offsets) |off| {
                    const dx = px4 + off[0] - cx4;
                    const dy = py4 + off[1] - cy4;
                    if (dx * dx + dy * dy <= r4sq) count += 1;
                }
                if (count > 0) {
                    const alpha: u8 = @intCast(count * 64 - @as(u32, if (count == 4) 1 else 0));
                    self.blendPixel(@intCast(px), @intCast(py), color, alpha);
                }
            }
        }
    }

    /// Circle outline (1px) with MSAA.
    pub fn drawCircle(self: Canvas, cx: i32, cy: i32, r: i32, color: Color) void {
        if (r <= 0) return;
        const r4 = r * 4;
        const r4sq = r4 * r4;
        const r4_inner = (r - 1) * 4;
        const r4_inner_sq = r4_inner * r4_inner;
        const cx4 = cx * 4;
        const cy4 = cy * 4;

        const bx0 = @max(0, cx - r - 1);
        const by0 = @max(0, cy - r - 1);
        const bx1: i32 = @min(@as(i32, @intCast(self.width)), cx + r + 2);
        const by1: i32 = @min(@as(i32, @intCast(self.height)), cy + r + 2);

        var py: i32 = by0;
        while (py < by1) : (py += 1) {
            var px: i32 = bx0;
            while (px < bx1) : (px += 1) {
                const px4 = px * 4;
                const py4 = py * 4;
                var count: u32 = 0;
                const offsets = [4][2]i32{ .{ -1, -1 }, .{ 1, -1 }, .{ -1, 1 }, .{ 1, 1 } };
                for (offsets) |off| {
                    const dx = px4 + off[0] - cx4;
                    const dy = py4 + off[1] - cy4;
                    const dist2 = dx * dx + dy * dy;
                    // On the ring: inside outer radius but outside inner radius
                    if (dist2 <= r4sq and dist2 > r4_inner_sq) count += 1;
                }
                if (count > 0) {
                    const alpha: u8 = @intCast(count * 64 - @as(u32, if (count == 4) 1 else 0));
                    self.blendPixel(@intCast(px), @intCast(py), color, alpha);
                }
            }
        }
    }

    /// Filled rounded rectangle.
    pub fn fillRoundRect(self: Canvas, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        if (w == 0 or h == 0) return;
        const r: i32 = @intCast(@min(radius, @min(w / 2, h / 2)));
        const iw: i32 = @intCast(w);
        const ih: i32 = @intCast(h);

        // Center horizontal strip
        if (r < ih) {
            const cx0: u32 = @intCast(@max(0, x));
            const cy0: u32 = @intCast(@max(0, y + r));
            const sw: u32 = if (x < 0) @intCast(@max(0, iw + x)) else @intCast(iw);
            const sh: u32 = @intCast(@max(0, ih - r * 2));
            self.fillRect(cx0, cy0, sw, sh, color);
        }

        // Top horizontal strip (between corner circles)
        if (r > 0) {
            const tx0: u32 = @intCast(@max(0, x + r));
            const ty0: u32 = @intCast(@max(0, y));
            const tw: u32 = @intCast(@max(0, iw - r * 2));
            const th: u32 = @intCast(r);
            self.fillRect(tx0, ty0, tw, th, color);

            // Bottom horizontal strip
            const bx0: u32 = @intCast(@max(0, x + r));
            const by0: u32 = @intCast(@max(0, y + ih - r));
            self.fillRect(bx0, by0, tw, th, color);
        }

        // Four corner circles
        self.fillCircle(x + r, y + r, r, color);
        self.fillCircle(x + iw - r - 1, y + r, r, color);
        self.fillCircle(x + r, y + ih - r - 1, r, color);
        self.fillCircle(x + iw - r - 1, y + ih - r - 1, r, color);
    }

    /// Rounded rectangle outline (1px).
    pub fn drawRoundRect(self: Canvas, x: i32, y: i32, w: u32, h: u32, radius: u32, color: Color) void {
        if (w == 0 or h == 0) return;
        const r: i32 = @intCast(@min(radius, @min(w / 2, h / 2)));
        const iw: i32 = @intCast(w);
        const ih: i32 = @intCast(h);

        // Horizontal edges (between corners)
        if (r > 0 and r < iw) {
            const edge_w: u32 = @intCast(@max(0, iw - r * 2));
            // Top edge
            if (y >= 0 and x + r >= 0) self.hline(@intCast(x + r), @intCast(y), edge_w, color);
            // Bottom edge
            const by: i32 = y + ih - 1;
            const canvas_h: i32 = @intCast(self.height);
            if (by >= 0 and x + r >= 0 and by < canvas_h) self.hline(@intCast(x + r), @intCast(by), edge_w, color);
        }
        // Vertical edges (between corners)
        if (r > 0 and r < ih) {
            const edge_h: u32 = @intCast(@max(0, ih - r * 2));
            // Left edge
            if (x >= 0 and y + r >= 0) self.vline(@intCast(x), @intCast(y + r), edge_h, color);
            // Right edge
            const rx: i32 = x + iw - 1;
            const canvas_w: i32 = @intCast(self.width);
            if (rx >= 0 and y + r >= 0 and rx < canvas_w) self.vline(@intCast(rx), @intCast(y + r), edge_h, color);
        }

        // Four corner arcs
        self.drawCircle(x + r, y + r, r, color);
        self.drawCircle(x + iw - r - 1, y + r, r, color);
        self.drawCircle(x + r, y + ih - r - 1, r, color);
        self.drawCircle(x + iw - r - 1, y + ih - r - 1, r, color);
    }

    /// Draw a soft drop shadow under a rect.
    pub fn drawShadow(self: Canvas, x: i32, y: i32, w: u32, h: u32, offset_x: i32, offset_y: i32, alpha: u8) void {
        const blur_steps: u32 = 4;
        const step_alpha: u8 = @truncate(@as(u32, alpha) / blur_steps);
        var i: u32 = 0;
        while (i < blur_steps) : (i += 1) {
            const expand: i32 = @intCast(blur_steps - i);
            const sx = x + offset_x - expand;
            const sy = y + offset_y - expand;
            const sw = w + @as(u32, @intCast(expand * 2));
            const sh = h + @as(u32, @intCast(expand * 2));
            const csx: u32 = @intCast(@max(0, sx));
            const csy: u32 = @intCast(@max(0, sy));
            self.fillRectAlpha(csx, csy, sw, sh, Color.black, step_alpha);
        }
    }

    /// Draw a single 8x8 character at pixel position (x, y).
    /// If `bg` is non-null, background pixels are filled; otherwise transparent.
    pub fn drawChar(self: Canvas, x: u32, y: u32, ch: u8, fg: Color, bg: ?Color) void {
        const glyph = font[ch];
        var row: u32 = 0;
        while (row < 8) : (row += 1) {
            const bits = glyph[row];
            var col: u32 = 0;
            while (col < 8) : (col += 1) {
                const set = (bits >> @intCast(7 - col)) & 1 != 0;
                if (set) {
                    self.putPixel(x + col, y + row, fg);
                } else if (bg) |bgc| {
                    self.putPixel(x + col, y + row, bgc);
                }
            }
        }
    }

    /// Draw a string of text at (x, y). Each character is 8 pixels wide.
    pub fn drawText(self: Canvas, x: u32, y: u32, text: []const u8, fg: Color, bg: ?Color) void {
        for (text, 0..) |ch, i| {
            self.drawChar(x +| @as(u32, @truncate(i)) *| 8, y, ch, fg, bg);
        }
    }

    /// Format and draw text using std.fmt.bufPrint with a 256-byte stack buffer.
    pub fn drawFmt(self: Canvas, x: u32, y: u32, fg: Color, bg: ?Color, comptime fmt: []const u8, args: anytype) void {
        var buf: [256]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..0];
        self.drawText(x, y, s, fg, bg);
    }

    /// Returns the pixel width of a text string (always text.len * 8).
    pub fn textWidth(text: []const u8) u32 {
        return @intCast(@min(text.len *| 8, @as(usize, std.math.maxInt(u32))));
    }

    /// Filled triangle with scanline rasterizer. Vertices may be in any order.
    pub fn fillTriangle(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: Color) void {
        // Sort vertices so ay <= by <= cy.
        var ax = x0;
        var ay = y0;
        var bx = x1;
        var by = y1;
        var cx = x2;
        var cy = y2;
        if (ay > by) {
            std.mem.swap(i32, &ax, &bx);
            std.mem.swap(i32, &ay, &by);
        }
        if (ay > cy) {
            std.mem.swap(i32, &ax, &cx);
            std.mem.swap(i32, &ay, &cy);
        }
        if (by > cy) {
            std.mem.swap(i32, &bx, &cx);
            std.mem.swap(i32, &by, &cy);
        }

        const total_h = cy - ay;
        if (total_h == 0) return;

        var y: i32 = ay;
        while (y <= cy) : (y += 1) {
            const second_half = y >= by;
            const seg_h: i32 = if (second_half) cy - by else by - ay;
            if (seg_h == 0) {
                y += 1;
                continue;
            }

            const alpha = @as(i32, y - ay) * 256 / total_h;
            const beta = if (second_half)
                @as(i32, y - by) * 256 / seg_h
            else
                @as(i32, y - ay) * 256 / seg_h;

            var lx = ax + (cx - ax) * alpha / 256;
            var rx = if (second_half)
                bx + (cx - bx) * beta / 256
            else
                ax + (bx - ax) * beta / 256;

            if (lx > rx) std.mem.swap(i32, &lx, &rx);

            if (y < 0 or y >= @as(i32, @intCast(self.height))) continue;
            const py: u32 = @intCast(y);
            const px0: u32 = @intCast(@max(0, lx));
            const px1: u32 = @intCast(@min(@as(i32, @intCast(self.width)), rx + 1));
            if (px1 > px0) self.hline(px0, py, px1 - px0, color);
        }
    }

    /// Outline triangle with 1-px lines.
    pub fn drawTriangle(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: Color) void {
        self.drawLine(x0, y0, x1, y1, color);
        self.drawLine(x1, y1, x2, y2, color);
        self.drawLine(x2, y2, x0, y0, color);
    }

    /// Thick line using Bresenham + rectangular cross-section (width in pixels).
    pub fn drawLineFat(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, width: u32, color: Color) void {
        if (width <= 1) {
            self.drawLine(x0, y0, x1, y1, color);
            return;
        }
        const hw: i32 = @intCast(width / 2);
        const dx = x1 - x0;
        const dy = y1 - y0;
        const len_sq = dx * dx + dy * dy;
        if (len_sq == 0) {
            const cx: u32 = @intCast(@max(0, x0 -| hw));
            const cy: u32 = @intCast(@max(0, y0 -| hw));
            self.fillRect(cx, cy, width, width, color);
            return;
        }
        // Perpendicular unit vector (integer, scaled by 256)
        const len256 = @as(i32, @intCast(isqrt(@as(u32, @intCast(@max(0, len_sq)))) + 1)) + 1;
        const px = -dy * 256 / len256;
        const py = dx * 256 / len256;

        // Draw as a thick quad by offsetting vertices
        const ox = px * hw / 256;
        const oy = py * hw / 256;

        // Fill as two triangles of the quad
        self.fillTriangle(x0 - ox, y0 - oy, x0 + ox, y0 + oy, x1 + ox, y1 + oy, color);
        self.fillTriangle(x0 - ox, y0 - oy, x1 + ox, y1 + oy, x1 - ox, y1 - oy, color);
    }

    /// Quadratic Bezier curve through P0, P1 (control), P2.
    pub fn drawBezier(self: Canvas, x0: i32, y0: i32, x1: i32, y1: i32, x2: i32, y2: i32, color: Color) void {
        const STEPS = 64;
        var px = x0;
        var py = y0;
        var t: i32 = 1;
        while (t <= STEPS) : (t += 1) {
            const u = t * 256 / STEPS; // [0..256]
            const mu = 256 - u;
            const nx = (mu * mu * x0 + 2 * mu * u * x1 + u * u * x2) >> 16;
            const ny = (mu * mu * y0 + 2 * mu * u * y1 + u * u * y2) >> 16;
            self.drawLine(px, py, nx, ny, color);
            px = nx;
            py = ny;
        }
    }

    /// Cubic Bezier through P0, P1, P2 (controls), P3.
    pub fn drawBezierCubic(
        self: Canvas,
        x0: i32,
        y0: i32,
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
        x3: i32,
        y3: i32,
        color: Color,
    ) void {
        const STEPS = 96;
        var px = x0;
        var py = y0;
        var t: i32 = 1;
        while (t <= STEPS) : (t += 1) {
            const u = t * 256 / STEPS;
            const mu = 256 - u;
            // B(t) = (1-t)^3 P0 + 3(1-t)^2 t P1 + 3(1-t) t^2 P2 + t^3 P3
            const mu3 = mu * mu * mu;
            const uc3 = u * u * u;
            const mu2u = 3 * mu * mu * u;
            const muu2 = 3 * mu * u * u;
            const nx = (mu3 * x0 + mu2u * x1 + muu2 * x2 + uc3 * x3) >> 24;
            const ny = (mu3 * y0 + mu2u * y1 + muu2 * y2 + uc3 * y3) >> 24;
            self.drawLine(px, py, nx, ny, color);
            px = nx;
            py = ny;
        }
    }

    /// Horizontal progress bar. Fills `value/max` fraction with `fg`, rest with `bg`.
    pub fn drawBar(self: Canvas, x: u32, y: u32, w: u32, h: u32, value: u32, max: u32, fg: Color, bg: Color) void {
        const fill_w = if (max > 0) @min(w, w * value / max) else 0;
        if (fill_w > 0) self.fillRect(x, y, fill_w, h, fg);
        if (fill_w < w) self.fillRect(x + fill_w, y, w - fill_w, h, bg);
    }

    /// Draw text at `scale`x magnification using the 8x8 font.
    /// `scale=1` is normal; `scale=2` produces 16x16 glyphs.
    pub fn drawTextScaled(self: Canvas, x: u32, y: u32, text: []const u8, scale: u32, fg: Color, bg: ?Color) void {
        if (scale <= 1) {
            self.drawText(x, y, text, fg, bg);
            return;
        }
        var cx = x;
        for (text) |ch| {
            self.drawCharScaled(cx, y, ch, scale, fg, bg);
            cx += 8 * scale;
        }
    }

    /// Draw a single character at `scale`x magnification.
    pub fn drawCharScaled(self: Canvas, x: u32, y: u32, ch: u8, scale: u32, fg: Color, bg: ?Color) void {
        const glyph = font[ch];
        var row: u32 = 0;
        while (row < 8) : (row += 1) {
            const bits = glyph[row];
            var col: u32 = 0;
            while (col < 8) : (col += 1) {
                const set = (bits >> @intCast(7 - col)) & 1 != 0;
                const pixel_color = if (set) fg else (bg orelse continue);
                self.fillRect(x + col * scale, y + row * scale, scale, scale, pixel_color);
            }
        }
    }
};

/// Frame-rate governor.
///
/// Tracks a rolling window of 8 frame times and selects the highest sustainable
/// target tier from {120, 60, 30, 15} fps. Call `sleepForBudget` at the end of
/// every frame loop iteration; it blocks just long enough to hit the target and
/// returns the budget it used so callers can log or display it.
pub const AdaptiveSync = struct {
    const HISTORY = 8;
    const TIERS = [_]u32{ 120, 60, 30, 15 };

    history: [HISTORY]u64 = .{0} ** HISTORY,
    head: usize = 0,
    count: usize = 0,
    target_fps: u32 = 60,

    /// Record `frame_ms` and update target_fps.
    pub fn recordFrame(self: *AdaptiveSync, frame_ms: u64) void {
        self.history[self.head] = frame_ms;
        self.head = (self.head + 1) % HISTORY;
        if (self.count < HISTORY) self.count += 1;

        const avg = self.avgMs();
        self.target_fps = chooseTier(avg);
    }

    /// Sleep for however long is left in the current frame budget, then return
    /// the budget duration in ms. Call at the end of the frame loop.
    pub fn sleepForBudget(self: *AdaptiveSync, frame_start_ms: u64) u64 {
        const now = innigkeit.display.uptimeMs();
        const elapsed = now - frame_start_ms;
        const budget: u64 = 1000 / self.target_fps;
        if (elapsed < budget) {
            innigkeit.sleep((budget - elapsed) * std.time.ns_per_ms);
        }
        return budget;
    }

    fn avgMs(self: *const AdaptiveSync) u64 {
        if (self.count == 0) return 16;
        var sum: u64 = 0;
        for (self.history[0..self.count]) |v| sum += v;
        return sum / self.count;
    }

    fn chooseTier(avg_ms: u64) u32 {
        for (TIERS) |fps| {
            if (avg_ms <= 1000 / fps) return fps;
        }
        return TIERS[TIERS.len - 1];
    }
};

/// Sin lookup table: 256 entries, period 256, output range [-127, 127] as i8.
/// Usage: sin8(phase) where phase is u8 -> cycles through one full period.
pub const sin_table: [256]i8 = blk: {
    @setEvalBranchQuota(100000);
    var t: [256]i8 = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        const angle = @as(f64, @floatFromInt(i)) * std.math.tau / 256.0;
        t[i] = @round(std.math.sin(angle) * 127.0);
    }
    break :blk t;
};

pub inline fn sin8(phase: u8) i8 {
    return sin_table[phase];
}

pub inline fn cos8(phase: u8) i8 {
    return sin_table[(phase +% 64) & 0xFF]; // cos = sin(x + π/2)
}

/// Integer square root: returns floor(sqrt(n)).
/// Uses a bit-length initial estimate so Newton's method converges in <= 2 iterations.
pub fn isqrt(n: u32) u32 {
    if (n == 0) return 0;
    const bits: u32 = 32 - @clz(n);
    var x: u32 = @as(u32, 1) << @as(u5, @truncate((bits + 1) / 2));
    var y: u32 = (x + n / x) >> 1;
    while (y < x) {
        x = y;
        y = (x + n / x) >> 1;
    }
    return x;
}

/// Approximate atan2 returning an 8-bit angle: 0=east, 64=north, 128=west, 192=south.
/// Screen convention: y increases downward. Integer-only; error < 1 degree.
pub fn atan2u(y_: i32, x_: i32) u8 {
    if (x_ == 0 and y_ == 0) return 0;
    const ax: u32 = @intCast(@abs(x_));
    const ay: u32 = @intCast(@abs(y_));
    const denom = ax + ay;
    const base: u32 = if (ax >= ay)
        64 * ay / denom
    else
        64 - 64 * ax / denom;
    return @truncate(
        if (x_ >= 0 and y_ >= 0)
            base
        else if (x_ < 0 and y_ >= 0)
            128 - base
        else if (x_ < 0 and y_ < 0)
            128 + base
        else
            256 - base,
    );
}

/// Precomputed rainbow color palette: 256 entries covering full hue range (HSV s=v=1).
pub const rainbow: [256]Color = blk: {
    @setEvalBranchQuota(100000);
    var p: [256]Color = undefined;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        // Hue in [0, 360), saturation=1, value=1 -> c=1, m=0
        const h: f64 = @as(f64, @floatFromInt(i)) / 256.0 * 360.0;
        const sector_f: f64 = h / 60.0;
        const sector_i: u32 = @trunc(@floor(sector_f));
        const sector: u32 = sector_i % 6;
        // h/60 mod 2: h_mod2 in [0, 2)
        const h_mod2: f64 = sector_f - @as(f64, @floatFromInt((sector_i / 2) * 2));
        const x_val: f64 = 1.0 - @abs(h_mod2 - 1.0);
        const r1: f64 = switch (sector) {
            0, 5 => 1.0,
            1, 4 => x_val,
            else => 0.0,
        };
        const g1: f64 = switch (sector) {
            1, 2 => 1.0,
            0, 3 => x_val,
            else => 0.0,
        };
        const b1: f64 = switch (sector) {
            3, 4 => 1.0,
            2, 5 => x_val,
            else => 0.0,
        };
        p[i] = .{
            .r = @trunc(r1 * 255.0),
            .g = @trunc(g1 * 255.0),
            .b = @trunc(b1 * 255.0),
        };
    }
    break :blk p;
};

/// 8x8 Bitmap Font (PC/VGA BIOS style)
///
/// Index is the ASCII code point (0–255).
/// Each entry is 8 bytes; each byte is one row with bit 7 = leftmost pixel.
/// Printable ASCII (0x20–0x7E) contains proper glyphs; the rest are zeroed.
const font: [256][8]u8 = blk: {
    var f: [256][8]u8 = [_][8]u8{.{ 0, 0, 0, 0, 0, 0, 0, 0 }} ** 256;

    // 0x20  SPACE
    f[0x20] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // 0x21  !
    f[0x21] = .{ 0x18, 0x3C, 0x3C, 0x18, 0x18, 0x00, 0x18, 0x00 };
    // 0x22  "
    f[0x22] = .{ 0x66, 0x66, 0x24, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // 0x23  #
    f[0x23] = .{ 0x6C, 0x6C, 0xFE, 0x6C, 0xFE, 0x6C, 0x6C, 0x00 };
    // 0x24  $
    f[0x24] = .{ 0x18, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x18, 0x00 };
    // 0x25  %
    f[0x25] = .{ 0x00, 0xC6, 0xCC, 0x18, 0x30, 0x66, 0xC6, 0x00 };
    // 0x26  &
    f[0x26] = .{ 0x38, 0x6C, 0x38, 0x76, 0xDC, 0xCC, 0x76, 0x00 };
    // 0x27  '
    f[0x27] = .{ 0x18, 0x18, 0x30, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // 0x28  (
    f[0x28] = .{ 0x0C, 0x18, 0x30, 0x30, 0x30, 0x18, 0x0C, 0x00 };
    // 0x29  )
    f[0x29] = .{ 0x30, 0x18, 0x0C, 0x0C, 0x0C, 0x18, 0x30, 0x00 };
    // 0x2A  *
    f[0x2A] = .{ 0x00, 0x66, 0x3C, 0xFF, 0x3C, 0x66, 0x00, 0x00 };
    // 0x2B  +
    f[0x2B] = .{ 0x00, 0x18, 0x18, 0x7E, 0x18, 0x18, 0x00, 0x00 };
    // 0x2C  ,
    f[0x2C] = .{ 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x30, 0x00 };
    // 0x2D  -
    f[0x2D] = .{ 0x00, 0x00, 0x00, 0x7E, 0x00, 0x00, 0x00, 0x00 };
    // 0x2E  .
    f[0x2E] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x18, 0x18, 0x00 };
    // 0x2F  /
    f[0x2F] = .{ 0x06, 0x0C, 0x18, 0x30, 0x60, 0xC0, 0x80, 0x00 };

    // 0x30  0
    f[0x30] = .{ 0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00 };
    // 0x31  1
    f[0x31] = .{ 0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00 };
    // 0x32  2
    f[0x32] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x30, 0x7E, 0x00 };
    // 0x33  3
    f[0x33] = .{ 0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00 };
    // 0x34  4
    f[0x34] = .{ 0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00 };
    // 0x35  5
    f[0x35] = .{ 0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00 };
    // 0x36  6
    f[0x36] = .{ 0x1C, 0x30, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00 };
    // 0x37  7
    f[0x37] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x30, 0x30, 0x00 };
    // 0x38  8
    f[0x38] = .{ 0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00 };
    // 0x39  9
    f[0x39] = .{ 0x3C, 0x66, 0x66, 0x3E, 0x06, 0x0C, 0x38, 0x00 };

    // 0x3A  :
    f[0x3A] = .{ 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x00, 0x00 };
    // 0x3B  ;
    f[0x3B] = .{ 0x00, 0x18, 0x18, 0x00, 0x18, 0x18, 0x30, 0x00 };
    // 0x3C  <
    f[0x3C] = .{ 0x06, 0x0C, 0x18, 0x30, 0x18, 0x0C, 0x06, 0x00 };
    // 0x3D  =
    f[0x3D] = .{ 0x00, 0x00, 0x7E, 0x00, 0x7E, 0x00, 0x00, 0x00 };
    // 0x3E  >
    f[0x3E] = .{ 0x60, 0x30, 0x18, 0x0C, 0x18, 0x30, 0x60, 0x00 };
    // 0x3F  ?
    f[0x3F] = .{ 0x3C, 0x66, 0x06, 0x0C, 0x18, 0x00, 0x18, 0x00 };
    // 0x40  @
    f[0x40] = .{ 0x3E, 0x63, 0x6F, 0x69, 0x6F, 0x60, 0x3E, 0x00 };

    // 0x41  A
    f[0x41] = .{ 0x18, 0x3C, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 };
    // 0x42  B
    f[0x42] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x66, 0x66, 0x7C, 0x00 };
    // 0x43  C
    f[0x43] = .{ 0x3C, 0x66, 0x60, 0x60, 0x60, 0x66, 0x3C, 0x00 };
    // 0x44  D
    f[0x44] = .{ 0x78, 0x6C, 0x66, 0x66, 0x66, 0x6C, 0x78, 0x00 };
    // 0x45  E
    f[0x45] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x7E, 0x00 };
    // 0x46  F
    f[0x46] = .{ 0x7E, 0x60, 0x60, 0x7C, 0x60, 0x60, 0x60, 0x00 };
    // 0x47  G
    f[0x47] = .{ 0x3C, 0x66, 0x60, 0x6E, 0x66, 0x66, 0x3C, 0x00 };
    // 0x48  H
    f[0x48] = .{ 0x66, 0x66, 0x66, 0x7E, 0x66, 0x66, 0x66, 0x00 };
    // 0x49  I
    f[0x49] = .{ 0x3C, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    // 0x4A  J
    f[0x4A] = .{ 0x1E, 0x0C, 0x0C, 0x0C, 0x0C, 0x6C, 0x38, 0x00 };
    // 0x4B  K
    f[0x4B] = .{ 0x66, 0x6C, 0x78, 0x70, 0x78, 0x6C, 0x66, 0x00 };
    // 0x4C  L
    f[0x4C] = .{ 0x60, 0x60, 0x60, 0x60, 0x60, 0x60, 0x7E, 0x00 };
    // 0x4D  M
    f[0x4D] = .{ 0x63, 0x77, 0x7F, 0x6B, 0x63, 0x63, 0x63, 0x00 };
    // 0x4E  N
    f[0x4E] = .{ 0x66, 0x76, 0x7E, 0x7E, 0x6E, 0x66, 0x66, 0x00 };
    // 0x4F  O
    f[0x4F] = .{ 0x3C, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    // 0x50  P
    f[0x50] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60, 0x60, 0x00 };
    // 0x51  Q
    f[0x51] = .{ 0x3C, 0x66, 0x66, 0x66, 0x6E, 0x3C, 0x06, 0x00 };
    // 0x52  R
    f[0x52] = .{ 0x7C, 0x66, 0x66, 0x7C, 0x6C, 0x66, 0x66, 0x00 };
    // 0x53  S
    f[0x53] = .{ 0x3C, 0x66, 0x60, 0x3C, 0x06, 0x66, 0x3C, 0x00 };
    // 0x54  T
    f[0x54] = .{ 0x7E, 0x18, 0x18, 0x18, 0x18, 0x18, 0x18, 0x00 };
    // 0x55  U
    f[0x55] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    // 0x56  V
    f[0x56] = .{ 0x66, 0x66, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 };
    // 0x57  W
    f[0x57] = .{ 0x63, 0x63, 0x63, 0x6B, 0x7F, 0x77, 0x63, 0x00 };
    // 0x58  X
    f[0x58] = .{ 0x66, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x66, 0x00 };
    // 0x59  Y
    f[0x59] = .{ 0x66, 0x66, 0x66, 0x3C, 0x18, 0x18, 0x18, 0x00 };
    // 0x5A  Z
    f[0x5A] = .{ 0x7E, 0x06, 0x0C, 0x18, 0x30, 0x60, 0x7E, 0x00 };

    // 0x5B  [
    f[0x5B] = .{ 0x3C, 0x30, 0x30, 0x30, 0x30, 0x30, 0x3C, 0x00 };
    // 0x5C  backslash
    f[0x5C] = .{ 0xC0, 0x60, 0x30, 0x18, 0x0C, 0x06, 0x02, 0x00 };
    // 0x5D  ]
    f[0x5D] = .{ 0x3C, 0x0C, 0x0C, 0x0C, 0x0C, 0x0C, 0x3C, 0x00 };
    // 0x5E  ^
    f[0x5E] = .{ 0x18, 0x3C, 0x66, 0x00, 0x00, 0x00, 0x00, 0x00 };
    // 0x5F  _
    f[0x5F] = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xFF };

    // 0x60  `
    f[0x60] = .{ 0x30, 0x18, 0x0C, 0x00, 0x00, 0x00, 0x00, 0x00 };

    // 0x61  a
    f[0x61] = .{ 0x00, 0x00, 0x3C, 0x06, 0x3E, 0x66, 0x3E, 0x00 };
    // 0x62  b
    f[0x62] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x7C, 0x00 };
    // 0x63  c
    f[0x63] = .{ 0x00, 0x00, 0x3C, 0x66, 0x60, 0x66, 0x3C, 0x00 };
    // 0x64  d
    f[0x64] = .{ 0x06, 0x06, 0x3E, 0x66, 0x66, 0x66, 0x3E, 0x00 };
    // 0x65  e
    f[0x65] = .{ 0x00, 0x00, 0x3C, 0x66, 0x7E, 0x60, 0x3C, 0x00 };
    // 0x66  f
    f[0x66] = .{ 0x1C, 0x30, 0x30, 0x78, 0x30, 0x30, 0x30, 0x00 };
    // 0x67  g
    f[0x67] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x3C };
    // 0x68  h
    f[0x68] = .{ 0x60, 0x60, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 };
    // 0x69  i
    f[0x69] = .{ 0x18, 0x00, 0x38, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    // 0x6A  j
    f[0x6A] = .{ 0x06, 0x00, 0x06, 0x06, 0x06, 0x66, 0x66, 0x3C };
    // 0x6B  k
    f[0x6B] = .{ 0x60, 0x60, 0x66, 0x6C, 0x78, 0x6C, 0x66, 0x00 };
    // 0x6C  l
    f[0x6C] = .{ 0x38, 0x18, 0x18, 0x18, 0x18, 0x18, 0x3C, 0x00 };
    // 0x6D  m
    f[0x6D] = .{ 0x00, 0x00, 0x66, 0x7F, 0x7F, 0x6B, 0x63, 0x00 };
    // 0x6E  n
    f[0x6E] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x66, 0x66, 0x00 };
    // 0x6F  o
    f[0x6F] = .{ 0x00, 0x00, 0x3C, 0x66, 0x66, 0x66, 0x3C, 0x00 };
    // 0x70  p
    f[0x70] = .{ 0x00, 0x00, 0x7C, 0x66, 0x66, 0x7C, 0x60, 0x60 };
    // 0x71  q
    f[0x71] = .{ 0x00, 0x00, 0x3E, 0x66, 0x66, 0x3E, 0x06, 0x06 };
    // 0x72  r
    f[0x72] = .{ 0x00, 0x00, 0x7C, 0x66, 0x60, 0x60, 0x60, 0x00 };
    // 0x73  s
    f[0x73] = .{ 0x00, 0x00, 0x3E, 0x60, 0x3C, 0x06, 0x7C, 0x00 };
    // 0x74  t
    f[0x74] = .{ 0x30, 0x30, 0x7E, 0x30, 0x30, 0x36, 0x1C, 0x00 };
    // 0x75  u
    f[0x75] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x66, 0x3E, 0x00 };
    // 0x76  v
    f[0x76] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3C, 0x18, 0x00 };
    // 0x77  w
    f[0x77] = .{ 0x00, 0x00, 0x63, 0x6B, 0x7F, 0x7F, 0x36, 0x00 };
    // 0x78  x
    f[0x78] = .{ 0x00, 0x00, 0x66, 0x3C, 0x18, 0x3C, 0x66, 0x00 };
    // 0x79  y
    f[0x79] = .{ 0x00, 0x00, 0x66, 0x66, 0x66, 0x3E, 0x06, 0x3C };
    // 0x7A  z
    f[0x7A] = .{ 0x00, 0x00, 0x7E, 0x0C, 0x18, 0x30, 0x7E, 0x00 };

    // 0x7B  {
    f[0x7B] = .{ 0x0E, 0x18, 0x18, 0x70, 0x18, 0x18, 0x0E, 0x00 };
    // 0x7C  |
    f[0x7C] = .{ 0x18, 0x18, 0x18, 0x00, 0x18, 0x18, 0x18, 0x00 };
    // 0x7D  }
    f[0x7D] = .{ 0x70, 0x18, 0x18, 0x0E, 0x18, 0x18, 0x70, 0x00 };
    // 0x7E  ~
    f[0x7E] = .{ 0x76, 0xDC, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };

    break :blk f;
};
