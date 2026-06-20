//! Innigkeit's Window Manager (WM) Compositor Core
//!
//! A self-contained file including only the pure geometry and surface-stack
//! policy shared by both the native WM and the future Wayland compositor.
//!
//! Coordinates are screen pixels. Origins are signed so a surface that is
//! partially off-screen (dragged past an edge) is representable; widths and
//! heights are non-negative and an empty rect (w<=0 or h<=0) means "nothing".

const std = @import("std");

/// An axis-aligned rectangle in screen pixels.
pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,

    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }

    pub fn right(r: Rect) i32 {
        return r.x +| r.w;
    }

    pub fn bottom(r: Rect) i32 {
        return r.y +| r.h;
    }

    /// Half-open containment: the right/bottom edges are exclusive, so adjacent
    /// rects never both claim the same pixel.
    pub fn contains(r: Rect, px: i32, py: i32) bool {
        return px >= r.x and px < r.right() and py >= r.y and py < r.bottom();
    }

    /// The overlapping region of `a` and `b` (empty if they do not overlap).
    pub fn intersect(a: Rect, b: Rect) Rect {
        const x = @max(a.x, b.x);
        const y = @max(a.y, b.y);
        const r = @min(a.right(), b.right());
        const bm = @min(a.bottom(), b.bottom());
        return .{ .x = x, .y = y, .w = r - x, .h = bm - y };
    }

    pub fn overlaps(a: Rect, b: Rect) bool {
        return !a.intersect(b).isEmpty();
    }

    /// Smallest rect covering both inputs (bounding-box union). An empty operand
    /// is ignored. This is the v1 damage model: a single conservative rect that
    /// over-approximates the changed region.
    pub fn boundingUnion(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x = @min(a.x, b.x);
        const y = @min(a.y, b.y);
        const r = @max(a.right(), b.right());
        const bm = @max(a.bottom(), b.bottom());
        return .{ .x = x, .y = y, .w = r - x, .h = bm - y };
    }

    /// Clip this rect to the screen `[0,0]..(w,h)`.
    ///
    /// Used to clamp a damage rect before `present`, so an off-screen or
    /// oversized region never asks the scanout to read out of bounds.
    ///
    /// Returns empty if fully off-screen.
    pub fn clampedToSize(r: Rect, w: i32, h: i32) Rect {
        return r.intersect(.{ .x = 0, .y = 0, .w = w, .h = h });
    }
};

/// Opaque surface identifier. `none` (0) is reserved for "no surface".
pub const SurfaceId = enum(u32) { none = 0, _ };

pub const Surface = struct {
    id: SurfaceId,
    rect: Rect,
    /// Only mapped surfaces are composited and can receive pointer input.
    mapped: bool = true,
};

/// A bottom-to-top ordered surface stack (index 0 = bottommost, last = topmost
/// = focused), with fixed capacity `cap`. The compositor walks it bottom-to-top
/// to paint and top-to-bottom to route a click; raising a surface re-orders it
/// to the top.
///
/// Generic over the stored `Item` so both the lightweight client-side `Surface`
/// and the server's richer per-surface record (geometry + committed buffer cap)
/// share one z-order/hit-test implementation. `Item` must expose the fields this
/// stack reasons about: `id: SurfaceId`, `rect: Rect`, and `mapped: bool`.
pub fn Stack(comptime Item: type, comptime cap: usize) type {
    return struct {
        const Self = @This();

        items: [cap]Item = undefined,
        len: usize = 0,

        pub const capacity = cap;

        /// Add a surface on top. Returns its rect as damage (it must be painted).
        pub fn add(self: *Self, item: Item) error{Full}!Rect {
            if (self.len == cap) return error.Full;
            self.items[self.len] = item;
            self.len += 1;
            return item.rect;
        }

        fn indexOf(self: *const Self, id: SurfaceId) ?usize {
            for (self.items[0..self.len], 0..) |s, i| {
                if (s.id == id) return i;
            }
            return null;
        }

        pub fn find(self: *Self, id: SurfaceId) ?*Item {
            const i = self.indexOf(id) orelse return null;
            return &self.items[i];
        }

        /// Remove `id`. Returns the vacated rect as damage (the area to repaint
        /// with whatever was behind it), or null if `id` was not present.
        pub fn remove(self: *Self, id: SurfaceId) ?Rect {
            const i = self.indexOf(id) orelse return null;
            const gone = self.items[i].rect;
            // Preserve relative order of the rest.
            std.mem.copyForwards(Item, self.items[i .. self.len - 1], self.items[i + 1 .. self.len]);
            self.len -= 1;
            return gone;
        }

        /// Move `id` to the top (focus), preserving the order of the others.
        /// Returns the surface's rect as damage (its stacking changed), or null.
        pub fn raise(self: *Self, id: SurfaceId) ?Rect {
            const i = self.indexOf(id) orelse return null;
            const s = self.items[i];
            std.mem.copyForwards(Item, self.items[i .. self.len - 1], self.items[i + 1 .. self.len]);
            self.items[self.len - 1] = s;
            return s.rect;
        }

        /// Move `id` to a new origin. Returns the damage to repaint: the union of
        /// the old and new rects (so both the vacated and freshly-covered area
        /// are refreshed), or null if `id` was not present.
        pub fn moveTo(self: *Self, id: SurfaceId, x: i32, y: i32) ?Rect {
            const s = self.find(id) orelse return null;
            const old = s.rect;
            s.rect.x = x;
            s.rect.y = y;
            return Rect.boundingUnion(old, s.rect);
        }

        /// The topmost mapped surface containing the point (i.e. who a click or
        /// the cursor lands on). Walks top-to-bottom so the focused/raised window
        /// wins. Returns `.none` if the point hits the background.
        pub fn topAt(self: *const Self, px: i32, py: i32) SurfaceId {
            var i = self.len;
            while (i > 0) {
                i -= 1;
                const s = self.items[i];
                if (s.mapped and s.rect.contains(px, py)) return s.id;
            }
            return .none;
        }

        /// Bottom-to-top slice for compositing (paint in order; later overdraws
        /// earlier). Callers typically skip `!mapped` surfaces.
        pub fn bottomToTop(self: *const Self) []const Item {
            return self.items[0..self.len];
        }
    };
}

test "Rect: containment is half-open (no double-claimed edge pixels)" {
    const r: Rect = .{ .x = 10, .y = 10, .w = 20, .h = 20 }; // covers [10,30) x [10,30)
    try std.testing.expect(r.contains(10, 10)); // top-left corner included
    try std.testing.expect(r.contains(29, 29)); // last pixel included
    try std.testing.expect(!r.contains(30, 20)); // right edge excluded
    try std.testing.expect(!r.contains(20, 30)); // bottom edge excluded
    try std.testing.expect(!r.contains(9, 20));
}

test "Rect: intersect / overlaps / boundingUnion" {
    const a: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const b: Rect = .{ .x = 50, .y = 50, .w = 100, .h = 100 };
    const i = a.intersect(b);
    try std.testing.expectEqual(Rect{ .x = 50, .y = 50, .w = 50, .h = 50 }, i);
    try std.testing.expect(a.overlaps(b));

    // Adjacent (touching but not overlapping) -> empty intersection.
    const c: Rect = .{ .x = 100, .y = 0, .w = 10, .h = 100 };
    try std.testing.expect(a.intersect(c).isEmpty());
    try std.testing.expect(!a.overlaps(c));

    const u = a.boundingUnion(b);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 150, .h = 150 }, u);
    // Empty operand is ignored.
    try std.testing.expectEqual(a, a.boundingUnion(.{}));
}

test "Rect: clampedToSize clips damage to the screen" {
    const screen_w: i32 = 800;
    const screen_h: i32 = 600;
    // Fully inside -> unchanged.
    const inside: Rect = .{ .x = 10, .y = 10, .w = 100, .h = 100 };
    try std.testing.expectEqual(inside, inside.clampedToSize(screen_w, screen_h));
    // Spilling past the right/bottom edges -> clipped to the screen.
    const spill: Rect = .{ .x = 750, .y = 550, .w = 200, .h = 200 };
    try std.testing.expectEqual(
        Rect{ .x = 750, .y = 550, .w = 50, .h = 50 },
        spill.clampedToSize(screen_w, screen_h),
    );
    // Fully off-screen -> empty (nothing to present).
    const off: Rect = .{ .x = 900, .y = 700, .w = 10, .h = 10 };
    try std.testing.expect(off.clampedToSize(screen_w, screen_h).isEmpty());
}

fn sid(n: u32) SurfaceId {
    return @enumFromInt(n);
}

test "Stack: z-order, raise, and topAt hit-testing" {
    var stack: Stack(Surface, 8) = .{};
    // Two overlapping windows; B is added later so it is on top.
    _ = try stack.add(.{ .id = sid(1), .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 } });
    _ = try stack.add(.{ .id = sid(2), .rect = .{ .x = 50, .y = 50, .w = 100, .h = 100 } });

    // In the overlap, the topmost (B=2) wins; outside B, A=1 wins; elsewhere none.
    try std.testing.expectEqual(sid(2), stack.topAt(60, 60));
    try std.testing.expectEqual(sid(1), stack.topAt(10, 10));
    try std.testing.expectEqual(SurfaceId.none, stack.topAt(200, 200));

    // Raising A flips the overlap result.
    _ = stack.raise(sid(1)).?;
    try std.testing.expectEqual(sid(1), stack.topAt(60, 60));
    // Bottom-to-top order now ends with the raised surface.
    const order = stack.bottomToTop();
    try std.testing.expectEqual(sid(2), order[0].id);
    try std.testing.expectEqual(sid(1), order[1].id);
}

test "Stack: unmapped surfaces are skipped by hit-testing" {
    var stack: Stack(Surface, 4) = .{};
    _ = try stack.add(.{ .id = sid(1), .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 } });
    _ = try stack.add(.{ .id = sid(2), .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .mapped = false });
    // 2 covers the same area but is unmapped -> the click falls through to 1.
    try std.testing.expectEqual(sid(1), stack.topAt(10, 10));
}

test "Stack: move and remove report damage" {
    var stack: Stack(Surface, 4) = .{};
    _ = try stack.add(.{ .id = sid(1), .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 } });

    // Moving reports the union of old + new position.
    const move_dmg = stack.moveTo(sid(1), 100, 100).?;
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 120, .h = 120 }, move_dmg);
    try std.testing.expectEqual(@as(i32, 100), stack.find(sid(1)).?.rect.x);

    // Removing reports the vacated rect (to repaint what was behind it).
    const rm_dmg = stack.remove(sid(1)).?;
    try std.testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 20, .h = 20 }, rm_dmg);
    try std.testing.expectEqual(@as(usize, 0), stack.len);
    try std.testing.expectEqual(@as(?Rect, null), stack.remove(sid(1))); // gone
}

test "Stack: capacity is enforced" {
    var stack: Stack(Surface, 1) = .{};
    _ = try stack.add(.{ .id = sid(1), .rect = .{ .x = 0, .y = 0, .w = 1, .h = 1 } });
    try std.testing.expectError(error.Full, stack.add(.{ .id = sid(2), .rect = .{} }));
}
