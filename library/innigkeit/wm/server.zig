//! Server side of the native display-server protocol.
//!
//! It owns the surface list (z-order + per-surface committed buffer), turns
//! decoded `protocol.Request`s into state changes, and reports the screen damage
//! to repaint and where pointer input lands.

const std = @import("std");

const caps = @import("../capabilities.zig");
const geometry = @import("geometry.zig");
const protocol = @import("protocol.zig");
const SyscallError = @import("../Error.zig").Syscall;
const display = @import("../display.zig");

const Rect = geometry.Rect;
const SurfaceId = geometry.SurfaceId;
const Handle = caps.Handle;
const Request = protocol.Request;
const Format = protocol.Format;

/// What a request did, for the IPC loop to act on: a new surface (reply with
/// `surface_created`), a screen rect to present, or nothing.
pub const Outcome = union(enum) {
    created: SurfaceId,
    damage: Rect,
    none: void,
};

/// Compositor errors. `Full` = surface table exhausted; `NoSurface` = a request
/// named an id that does not exist.
pub const Error = error{ Full, NoSurface };

/// Saturating u32->i32 so a hostile client-supplied buffer dimension caps at
/// i32-max instead of trapping the (userspace) compositor.
fn satI32(v: u32) i32 {
    return @intCast(@min(v, @as(u32, std.math.maxInt(i32))));
}

/// The compositor over a fixed `max_surfaces`. Generic only in capacity; the
/// per-surface record carries the geometry the `Stack` reasons about plus the
/// server-only buffer binding and owning client.
pub fn Compositor(comptime max_surfaces: usize) type {
    return struct {
        const Self = @This();

        /// Per-surface server state. The first three fields are the contract the
        /// `Stack` needs (id/rect/mapped); the rest is the committed buffer.
        pub const ServerSurface = struct {
            id: SurfaceId,
            rect: Rect,
            mapped: bool,
            /// Committed buffer cap (read-only copy from the client), or
            /// `invalid_handle` before the first `attach`. Stored, never invoked.
            buffer: Handle,
            buf_width: u32,
            buf_height: u32,
            format: Format,
            /// Owning connection id, so pointer input routes to the right client.
            client: u32,
        };

        /// Where a pointer landed: the surface, its owning client, and the
        /// surface-local coordinates the client wants in its input events.
        pub const Hit = struct {
            surface: SurfaceId,
            client: u32,
            local_x: i32,
            local_y: i32,
        };

        stack: geometry.Stack(ServerSurface, max_surfaces) = .{},
        scanout: Rect,
        next_id: u32 = 1,

        /// A compositor for a `width`x`height` scanout (the display bounds used to
        /// clamp every damage rect before it reaches `present`).
        pub fn init(width: i32, height: i32) Self {
            return .{ .scanout = .{ .x = 0, .y = 0, .w = width, .h = height } };
        }

        /// Allocate a fresh surface for `client`, placed at (`x`,`y`), initially
        /// empty (0x0) and unmapped until its first buffer `commit`.
        pub fn createSurface(self: *Self, client: u32, x: i32, y: i32) Error!SurfaceId {
            const id: SurfaceId = @enumFromInt(self.next_id);
            _ = try self.stack.add(.{
                .id = id,
                .rect = .{ .x = x, .y = y, .w = 0, .h = 0 },
                .mapped = false,
                .buffer = caps.invalid_handle,
                .buf_width = 0,
                .buf_height = 0,
                .format = .bgrx8888,
                .client = client,
            });
            self.next_id += 1;
            return id;
        }

        /// Bind a buffer (and its pixel geometry) to a surface. The surface takes
        /// the buffer's size; it becomes visible on the next `commit`.
        pub fn attach(self: *Self, id: SurfaceId, buffer: Handle, width: u32, height: u32, format: Format) Error!void {
            const s = self.stack.find(id) orelse return error.NoSurface;
            s.buffer = buffer;
            s.buf_width = width;
            s.buf_height = height;
            s.format = format;
            s.rect.w = satI32(width);
            s.rect.h = satI32(height);
        }

        /// Commit a surface: mark it mapped and return the screen rect to present
        /// the surface-local `damage` translated to screen, clipped to the
        /// surface, and clamped to the scanout (so it can never read out of bounds).
        pub fn commit(self: *Self, id: SurfaceId, damage: Rect) Error!Rect {
            const s = self.stack.find(id) orelse return error.NoSurface;
            s.mapped = true;
            const screen: Rect = .{ .x = s.rect.x + damage.x, .y = s.rect.y + damage.y, .w = damage.w, .h = damage.h };
            return screen.intersect(s.rect).clampedToSize(self.scanout.w, self.scanout.h);
        }

        /// Reposition a surface; returns the union of old+new area (clamped) to
        /// repaint.
        pub fn setPosition(self: *Self, id: SurfaceId, x: i32, y: i32) Error!Rect {
            const dmg = self.stack.moveTo(id, x, y) orelse return error.NoSurface;
            return dmg.clampedToSize(self.scanout.w, self.scanout.h);
        }

        /// Raise a surface to the top (focus); returns its rect (clamped) to
        /// repaint, since stacking changed.
        pub fn raise(self: *Self, id: SurfaceId) Error!Rect {
            const dmg = self.stack.raise(id) orelse return error.NoSurface;
            return dmg.clampedToSize(self.scanout.w, self.scanout.h);
        }

        /// Destroy a surface; returns the vacated rect (clamped) to repaint with
        /// whatever was behind it.
        pub fn destroy(self: *Self, id: SurfaceId) Error!Rect {
            const dmg = self.stack.remove(id) orelse return error.NoSurface;
            return dmg.clampedToSize(self.scanout.w, self.scanout.h);
        }

        /// Who is under (`px`,`py`): the topmost mapped surface, its client, and
        /// the surface-local coordinates or null if the point hits background.
        pub fn pointerAt(self: *Self, px: i32, py: i32) ?Hit {
            const id = self.stack.topAt(px, py);
            if (id == .none) return null;
            const s = self.stack.find(id) orelse return null;
            return .{ .surface = id, .client = s.client, .local_x = px - s.rect.x, .local_y = py - s.rect.y };
        }

        /// Look up a surface's full server record.
        pub fn find(self: *Self, id: SurfaceId) ?*ServerSurface {
            return self.stack.find(id);
        }

        /// Bottom-to-top surfaces, for the compositing pass (paint in order).
        pub fn surfaces(self: *const Self) []const ServerSurface {
            return self.stack.bottomToTop();
        }

        /// Apply a decoded request from `client` and report what the loop must do.
        /// The single dispatch entry the live server wraps; `connect` carries only
        /// transport state (the loop's concern), so it is a no-op here.
        pub fn apply(self: *Self, client: u32, req: Request) Error!Outcome {
            return switch (req) {
                .connect => .none,
                .create_surface => .{ .created = try self.createSurface(client, 0, 0) },
                .attach_buffer => |r| blk: {
                    try self.attach(r.surface, r.buffer, r.width, r.height, r.format);
                    break :blk .none;
                },
                .commit => |r| .{ .damage = try self.commit(r.surface, r.damage) },
                .set_position => |r| .{ .damage = try self.setPosition(r.surface, r.x, r.y) },
                .destroy_surface => |r| .{ .damage = try self.destroy(r.surface) },
            };
        }
    };
}

/// A request as it arrives at the server: which client sent it, and the raw
/// `Message` (the server decodes it, so a malformed one is dropped, not fatal).
pub const Incoming = struct {
    client: u32,
    msg: caps.Message,
};

/// The live display server: the pure `Compositor` plus the IPC/scanout plumbing,
/// which is injected as a `Platform` so the loop's *orchestration* (client
/// registration, the `surface_created` reply, damage->present dispatch, dropping
/// malformed requests) is host-tested with a fake, while only the thin real
/// `SyscallPlatform` touches the kernel. A `Platform` provides:
///   - `recv() !Incoming`: next request (any client)
///   - `sendEvent(Handle, *const Message) !void`: push an event to a client
///   - `createFrameNotify() !Handle`: a surface's frame Notify
///   - `present(Rect) void`: present a damage rect
pub fn Server(comptime Platform: type, comptime max_surfaces: usize, comptime max_clients: usize) type {
    return struct {
        const Self = @This();

        compositor: Compositor(max_surfaces),
        platform: Platform,

        /// client id -> its event endpoint (server->client), `invalid_handle` until
        /// the client `connect`s. A request from an unregistered client still
        /// mutates compositor state, but no event can be delivered to it.
        clients: [max_clients]Handle = [_]Handle{caps.invalid_handle} ** max_clients,

        pub fn init(platform: Platform, width: i32, height: i32) Self {
            return .{ .compositor = Compositor(max_surfaces).init(width, height), .platform = platform };
        }

        /// Process exactly one request (the body of the main loop). A malformed
        /// message or an out-of-range client id is dropped: a misbehaving client
        /// can never wedge the server.
        pub fn handleOne(self: *Self) !void {
            const inc = try self.platform.recv();
            if (inc.client >= max_clients) return;
            const req = Request.decode(inc.msg) catch return;
            switch (req) {
                .connect => |r| self.clients[inc.client] = r.event_endpoint,
                else => try self.dispatch(inc.client, req),
            }
        }

        fn dispatch(self: *Self, client: u32, req: Request) !void {
            switch (try self.compositor.apply(client, req)) {
                .created => |id| {
                    const channel = self.clients[client];
                    if (channel == caps.invalid_handle) return; // client never connected
                    const frame = try self.platform.createFrameNotify();
                    var ev = (protocol.Event{ .surface_created = .{ .surface = id, .frame = frame } }).encode();
                    try self.platform.sendEvent(channel, &ev);
                },
                .damage => |rect| if (!rect.isEmpty()) self.platform.present(rect),
                .none => {},
            }
        }
    };
}

/// The production `Platform`: requests arrive on one server endpoint, events go
/// back on each client's event endpoint, frame Notifies and the present syscall
/// are the real kernel ops. Multi-client demux (per-client endpoints + a
/// multi-wait) is the next refinement; today it reads a single request channel.
pub const SyscallPlatform = struct {
    request_endpoint: Handle,

    pub fn recv(self: SyscallPlatform) SyscallError!Incoming {
        var msg: caps.Message = .{};
        try caps.endpointRecv(self.request_endpoint, &msg);
        return .{ .client = 0, .msg = msg };
    }

    pub fn sendEvent(_: SyscallPlatform, channel: Handle, msg: *const caps.Message) SyscallError!void {
        return caps.endpointSend(channel, msg);
    }

    pub fn createFrameNotify(_: SyscallPlatform) SyscallError!Handle {
        return caps.create(.notify);
    }

    pub fn present(_: SyscallPlatform, rect: Rect) void {
        // The rect is already scanout-clamped (non-negative, in bounds) by the
        // compositor, and non-empty (dispatch checks), so the casts are sound.
        display.present(@intCast(rect.x), @intCast(rect.y), @intCast(rect.w), @intCast(rect.h));
    }
};

const TestComp = Compositor(8);

fn handle(n: u32) Handle {
    return @enumFromInt(n);
}

test "createSurface allocates rising ids, empty and unmapped until commit" {
    var c = TestComp.init(800, 600);
    const a = try c.createSurface(1, 10, 20);
    const b = try c.createSurface(1, 0, 0);
    try std.testing.expectEqual(@as(SurfaceId, @enumFromInt(1)), a);
    try std.testing.expectEqual(@as(SurfaceId, @enumFromInt(2)), b);

    const sa = c.find(a).?;
    try std.testing.expect(!sa.mapped);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 0, .h = 0 }, sa.rect);
    try std.testing.expectEqual(caps.invalid_handle, sa.buffer);
}

test "attach sizes the surface; commit maps it and reports screen damage" {
    var c = TestComp.init(800, 600);
    const id = try c.createSurface(1, 100, 50);
    try c.attach(id, handle(7), 200, 150, .bgrx8888);

    const s = c.find(id).?;
    try std.testing.expectEqual(@as(i32, 200), s.rect.w);
    try std.testing.expectEqual(@as(i32, 150), s.rect.h);
    try std.testing.expectEqual(handle(7), s.buffer);

    // Surface-local damage (10,10,20,20) -> screen (110,60,20,20).
    const dmg = try c.commit(id, .{ .x = 10, .y = 10, .w = 20, .h = 20 });
    try std.testing.expect(c.find(id).?.mapped);
    try std.testing.expectEqual(Rect{ .x = 110, .y = 60, .w = 20, .h = 20 }, dmg);
}

test "commit clips damage to the surface and the scanout" {
    var c = TestComp.init(640, 480);
    const id = try c.createSurface(1, 600, 0); // near the right edge
    try c.attach(id, handle(1), 200, 200, .bgrx8888); // spills off-screen

    // Local damage covers the whole surface; only the on-screen, in-surface part
    // survives: screen x in [600,640) -> width 40.
    const dmg = try c.commit(id, .{ .x = 0, .y = 0, .w = 200, .h = 200 });
    try std.testing.expectEqual(Rect{ .x = 600, .y = 0, .w = 40, .h = 200 }, dmg);
}

test "z-order: pointerAt picks the top surface with local coords; raise flips it" {
    var c = TestComp.init(800, 600);
    const a = try c.createSurface(11, 0, 0);
    const b = try c.createSurface(22, 50, 50);
    try c.attach(a, handle(1), 100, 100, .bgrx8888);
    try c.attach(b, handle(2), 100, 100, .bgrx8888);
    _ = try c.commit(a, .{});
    _ = try c.commit(b, .{});

    // In the overlap, b (added later, on top) wins; coords are surface-local.
    const hit = c.pointerAt(60, 60).?;
    try std.testing.expectEqual(b, hit.surface);
    try std.testing.expectEqual(@as(u32, 22), hit.client);
    try std.testing.expectEqual(@as(i32, 10), hit.local_x); // 60 - 50
    try std.testing.expectEqual(@as(i32, 10), hit.local_y);

    // Outside b but inside a -> a wins, with a-local coords.
    try std.testing.expectEqual(a, c.pointerAt(10, 10).?.surface);
    // Background -> no hit.
    try std.testing.expectEqual(@as(?TestComp.Hit, null), c.pointerAt(700, 700));

    // Raise a above b; now a wins the overlap.
    _ = try c.raise(a);
    try std.testing.expectEqual(a, c.pointerAt(60, 60).?.surface);
}

test "setPosition and destroy report damage; unmapped surfaces aren't hit" {
    var c = TestComp.init(800, 600);
    const id = try c.createSurface(1, 0, 0);
    try c.attach(id, handle(1), 20, 20, .bgrx8888);
    _ = try c.commit(id, .{});

    // Move reports union(old,new).
    const move_dmg = try c.setPosition(id, 100, 100);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 120, .h = 120 }, move_dmg);

    // Destroy reports the vacated rect, and the surface is gone.
    const rm_dmg = try c.destroy(id);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 100, .w = 20, .h = 20 }, rm_dmg);
    try std.testing.expectError(error.NoSurface, c.commit(id, .{}));
}

test "apply dispatches the protocol requests end to end" {
    var c = TestComp.init(300, 300);
    // connect is a no-op for the compositor.
    try std.testing.expectEqual(Outcome{ .none = {} }, try c.apply(1, .{ .connect = .{ .event_endpoint = handle(9) } }));

    // create_surface -> created(id).
    const out = try c.apply(1, .{ .create_surface = {} });
    const id = out.created;
    try std.testing.expectEqual(@as(SurfaceId, @enumFromInt(1)), id);

    // attach -> none, but sizes the surface.
    try std.testing.expectEqual(
        Outcome{ .none = {} },
        try c.apply(1, .{ .attach_buffer = .{ .surface = id, .buffer = handle(5), .width = 64, .height = 64, .format = .bgrx8888 } }),
    );

    // commit -> damage (placed at origin by apply).
    try std.testing.expectEqual(
        Outcome{ .damage = .{ .x = 0, .y = 0, .w = 64, .h = 64 } },
        try c.apply(1, .{ .commit = .{ .surface = id, .damage = .{ .x = 0, .y = 0, .w = 64, .h = 64 } } }),
    );

    // a request against a missing surface surfaces NoSurface.
    try std.testing.expectError(error.NoSurface, c.apply(1, .{ .destroy_surface = .{ .surface = @enumFromInt(999) } }));
}

test "createSurface enforces capacity" {
    var c = Compositor(1).init(100, 100);
    _ = try c.createSurface(1, 0, 0);
    try std.testing.expectError(error.Full, c.createSurface(1, 0, 0));
}

/// An in-memory `Platform`: a request inbox to drain, and records of the events
/// pushed, rects presented, and frame Notifies handed out.
const FakePlatform = struct {
    inbox: [16]Incoming = undefined,
    inbox_len: usize = 0,
    inbox_pos: usize = 0,
    sent: [16]struct { channel: Handle, msg: caps.Message } = undefined,
    sent_len: usize = 0,
    presented: [16]Rect = undefined,
    presented_len: usize = 0,
    next_notify: u32 = 1000,

    fn pushReq(self: *FakePlatform, client: u32, req: Request) void {
        self.inbox[self.inbox_len] = .{ .client = client, .msg = req.encode() };
        self.inbox_len += 1;
    }

    fn pushRaw(self: *FakePlatform, client: u32, msg: caps.Message) void {
        self.inbox[self.inbox_len] = .{ .client = client, .msg = msg };
        self.inbox_len += 1;
    }

    fn recv(self: *FakePlatform) error{Empty}!Incoming {
        if (self.inbox_pos == self.inbox_len) return error.Empty;
        defer self.inbox_pos += 1;
        return self.inbox[self.inbox_pos];
    }

    fn sendEvent(self: *FakePlatform, channel: Handle, msg: *const caps.Message) error{}!void {
        self.sent[self.sent_len] = .{ .channel = channel, .msg = msg.* };
        self.sent_len += 1;
    }

    fn createFrameNotify(self: *FakePlatform) error{}!Handle {
        defer self.next_notify += 1;
        return @enumFromInt(self.next_notify);
    }

    fn present(self: *FakePlatform, rect: Rect) void {
        self.presented[self.presented_len] = rect;
        self.presented_len += 1;
    }
};

const TestServer = Server(FakePlatform, 8, 4);

/// Drain the whole inbox through the server.
fn run(server: *TestServer) !void {
    while (true) {
        server.handleOne() catch |err| switch (err) {
            error.Empty => return,
            else => return err,
        };
    }
}

test "connect registers the event channel; create_surface replies surface_created on it" {
    var server = TestServer.init(.{}, 800, 600);
    server.platform.pushReq(0, .{ .connect = .{ .event_endpoint = handle(77) } });
    server.platform.pushReq(0, .{ .create_surface = {} });
    try run(&server);

    // Exactly one event, to the registered channel, and it is surface_created
    // for the allocated id carrying a freshly-minted frame Notify.
    try std.testing.expectEqual(@as(usize, 1), server.platform.sent_len);
    try std.testing.expectEqual(handle(77), server.platform.sent[0].channel);
    const ev = try protocol.Event.decode(server.platform.sent[0].msg);
    try std.testing.expectEqual(@as(SurfaceId, @enumFromInt(1)), ev.surface_created.surface);
    try std.testing.expectEqual(@as(Handle, @enumFromInt(1000)), ev.surface_created.frame);
}

test "commit presents the damage rect; empty damage presents nothing" {
    var server = TestServer.init(.{}, 800, 600);
    server.platform.pushReq(0, .{ .connect = .{ .event_endpoint = handle(1) } });
    server.platform.pushReq(0, .{ .create_surface = {} });
    const id: SurfaceId = @enumFromInt(1);
    server.platform.pushReq(0, .{ .attach_buffer = .{ .surface = id, .buffer = handle(2), .width = 100, .height = 100, .format = .bgrx8888 } });
    server.platform.pushReq(0, .{ .commit = .{ .surface = id, .damage = .{ .x = 10, .y = 10, .w = 30, .h = 30 } } });
    try run(&server);

    try std.testing.expectEqual(@as(usize, 1), server.platform.presented_len);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 30, .h = 30 }, server.platform.presented[0]);

    // An empty-damage commit presents nothing further.
    server.platform.pushReq(0, .{ .commit = .{ .surface = id, .damage = .{} } });
    try run(&server);
    try std.testing.expectEqual(@as(usize, 1), server.platform.presented_len);
}

test "a malformed request is dropped, not fatal" {
    var server = TestServer.init(.{}, 800, 600);
    server.platform.pushRaw(0, .{ .tag = 0xDEAD }); // unknown opcode
    server.platform.pushReq(0, .{ .connect = .{ .event_endpoint = handle(5) } });
    server.platform.pushReq(0, .{ .create_surface = {} });
    try run(&server); // must not error on the bad message

    try std.testing.expectEqual(@as(usize, 1), server.platform.sent_len); // the good ones still worked
}

test "a request from an unconnected client mutates state but delivers no event" {
    var server = TestServer.init(.{}, 800, 600);
    // No connect first: create_surface still allocates, but there's no channel.
    server.platform.pushReq(0, .{ .create_surface = {} });
    try run(&server);
    try std.testing.expectEqual(@as(usize, 0), server.platform.sent_len);
    try std.testing.expect(server.compositor.find(@enumFromInt(1)) != null);
}
