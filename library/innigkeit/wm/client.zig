//! Client side of the native display-server protocol.
//!
//! A thin, typed surface over `protocol`: `connect` -> a `Connection`,
//! `createSurface` -> a `Surface`, then `attach`/`commit`/`setPosition`/`destroy`
//! and an event stream. Apps port from "map the framebuffer + draw" to "get a
//! surface + draw into my own buffer + commit".
//!
//! Transport injection. The client's real work is *which message each operation
//! emits and how it decodes the replies/events*, so `Connection`/`Surface` are
//! generic over a `Transport` (the wire). Production uses `SyscallTransport`
//! (the IPC syscalls); tests inject an in-memory fake, so the client behavior is
//! host-unit-tested, not merely compile-checked. A transport provides:
//!   - `call(*Message) !void`: request, reply in place (server endpoint)
//!   - `send(*const Message) !void`: fire-and-forget request (server endpoint)
//!   - `recvEvent(*Message) !void`: block for the next event (event endpoint)

const std = @import("std");

const geometry = @import("geometry.zig");
const protocol = @import("protocol.zig");
const caps = @import("../capabilities.zig");
const Syscall = @import("../syscall.zig").Syscall;
const SyscallError = @import("../Error.zig").Syscall;

const Message = caps.Message;
const Handle = caps.Handle;
const Rect = geometry.Rect;
const SurfaceId = geometry.SurfaceId;
const Request = protocol.Request;
const Event = protocol.Event;
const Format = protocol.Format;

/// What a client call can surface: any syscall/IPC error, an unknown opcode on
/// the wire, or a reply that did not match the request (`ProtocolViolation`).
pub const Error = SyscallError || protocol.DecodeError || error{ProtocolViolation};

/// A live connection: the server request endpoint (call/send) and our own event
/// endpoint (recv), generic over the wire transport. Holds no allocation.
pub fn Connection(comptime Transport: type) type {
    return struct {
        const Self = @This();

        transport: Transport,

        /// Ask the server for a fresh surface. Synchronous (`call`): the reply is
        /// `Event.surface_created`, carrying the assigned id + a per-surface frame
        /// `Notify` (caps[0]) for pacing. Any other reply is a `ProtocolViolation`.
        pub fn createSurface(self: *Self) Error!Surface(Transport) {
            var msg = (Request{ .create_surface = {} }).encode();
            try self.transport.call(&msg);
            return switch (try Event.decode(msg)) {
                .surface_created => |s| .{ .conn = self, .id = s.surface, .frame = s.frame },
                else => error.ProtocolViolation,
            };
        }

        /// Block for the next server->client event (input, frame_done, configure,
        /// buffer_released, closed). The compositor's main loop on the client side.
        pub fn nextEvent(self: *Self) Error!Event {
            var msg: Message = .{};
            try self.transport.recvEvent(&msg);
            return Event.decode(msg);
        }
    };
}

/// A client surface: an id, its frame `Notify`, and a back-pointer to the owning
/// connection (the wire). Operations build a `protocol.Request` and send it.
pub fn Surface(comptime Transport: type) type {
    return struct {
        const Self = @This();

        conn: *Connection(Transport),
        id: SurfaceId,
        /// Per-surface frame callback `Notify`; wait on it to pace repaints.
        frame: Handle,

        /// Bind `buffer` as this surface's pixels. The server receives a
        /// **read-only** copy (`caps.copy(.., .read_only)`) so it composites
        /// zero-copy yet cannot scribble on the client's buffer (H1). `width`x
        /// `height` is the geometry the buffer holds, in `format`.
        pub fn attach(self: Self, buffer: Handle, width: u32, height: u32, format: Format) Error!void {
            const shared = try caps.copy(buffer, caps.Rights.read_only);
            defer caps.delete(shared) catch {}; // server kept its own copy on send
            const msg = (Request{ .attach_buffer = .{
                .surface = self.id,
                .buffer = shared,
                .width = width,
                .height = height,
                .format = format,
            } }).encode();
            try self.conn.transport.send(&msg);
        }

        /// Make the attached buffer current and repaint `damage` (surface-local).
        pub fn commit(self: Self, damage: Rect) Error!void {
            const msg = (Request{ .commit = .{ .surface = self.id, .damage = damage } }).encode();
            try self.conn.transport.send(&msg);
        }

        /// Reposition the surface's top-left in screen pixels.
        pub fn setPosition(self: Self, x: i32, y: i32) Error!void {
            const msg = (Request{ .set_position = .{ .surface = self.id, .x = x, .y = y } }).encode();
            try self.conn.transport.send(&msg);
        }

        /// Drop the surface; the server releases its resources.
        pub fn destroy(self: Self) Error!void {
            const msg = (Request{ .destroy_surface = .{ .surface = self.id } }).encode();
            try self.conn.transport.send(&msg);
        }

        /// Block until the server signals this surface's frame callback (the cue
        /// to draw and `commit` the next frame).
        pub fn waitFrame(self: Self) Error!void {
            _ = try caps.notifyWait(self.frame, ~@as(u64, 0));
        }
    };
}

/// The real wire: requests go to the server endpoint (call/send), events arrive
/// on our event endpoint (recv).
pub const SyscallTransport = struct {
    server: Handle,
    events: Handle,

    pub fn call(self: SyscallTransport, msg: *Message) Syscall.Error!void {
        return caps.endpointCall(self.server, msg);
    }
    pub fn send(self: SyscallTransport, msg: *const Message) Syscall.Error!void {
        return caps.endpointSend(self.server, msg);
    }
    pub fn recvEvent(self: SyscallTransport, msg: *Message) Syscall.Error!void {
        return caps.endpointRecv(self.events, msg);
    }
};

/// A connected client over the real syscalls.
pub const Client = Connection(SyscallTransport);

/// Connect to the compositor over an already-granted server request `endpoint`
/// (the compositor grants it at spawn).
///
/// Creates our event endpoint and hands the server a copy so it can push events.
pub fn connect(server_endpoint: Handle) Error!Client {
    const events = try caps.create(.endpoint);
    // The kernel copies caps[0] into the server's table on send; we keep `events`
    // to recv on. (transferCaps shares the object, sender retains its handle.)
    var msg = (Request{ .connect = .{ .event_endpoint = events } }).encode();
    try caps.endpointSend(server_endpoint, &msg);
    return .{ .transport = .{ .server = server_endpoint, .events = events } };
}

/// Records sent/called messages and replays a canned reply + an event queue.
const FakeTransport = struct {
    sent: [8]Message = undefined,
    sent_len: usize = 0,
    reply: Message = .{},
    events: [8]Message = undefined,
    events_len: usize = 0,
    event_idx: usize = 0,

    fn send(self: *FakeTransport, msg: *const Message) SyscallError!void {
        self.sent[self.sent_len] = msg.*;
        self.sent_len += 1;
    }

    fn call(self: *FakeTransport, msg: *Message) SyscallError!void {
        self.sent[self.sent_len] = msg.*;
        self.sent_len += 1;
        msg.* = self.reply;
    }

    fn recvEvent(self: *FakeTransport, msg: *Message) SyscallError!void {
        msg.* = self.events[self.event_idx];
        self.event_idx += 1;
    }

    fn lastSent(self: *const FakeTransport) Message {
        return self.sent[self.sent_len - 1];
    }
};

const TestConn = Connection(FakeTransport);

fn sid(n: u32) SurfaceId {
    return @enumFromInt(n);
}

test "createSurface issues create_surface and binds the server's reply" {
    var conn: TestConn = .{ .transport = .{} };
    conn.transport.reply = (Event{ .surface_created = .{ .surface = sid(5), .frame = @enumFromInt(99) } }).encode();

    const surface = try conn.createSurface();
    try std.testing.expectEqual(sid(5), surface.id);
    try std.testing.expectEqual(@as(Handle, @enumFromInt(99)), surface.frame);
    // It sent exactly one request, and it was create_surface.
    try std.testing.expectEqual(@as(usize, 1), conn.transport.sent_len);
    try std.testing.expectEqual(Request{ .create_surface = {} }, try Request.decode(conn.transport.sent[0]));
}

test "createSurface rejects a mismatched reply as a protocol violation" {
    var conn: TestConn = .{ .transport = .{} };
    conn.transport.reply = (Event{ .closed = .{ .surface = sid(5) } }).encode();
    try std.testing.expectError(error.ProtocolViolation, conn.createSurface());
}

test "surface ops emit the matching requests" {
    var conn: TestConn = .{ .transport = .{} };
    const surface: Surface(FakeTransport) = .{ .conn = &conn, .id = sid(3), .frame = @enumFromInt(1) };

    try surface.commit(.{ .x = 1, .y = 2, .w = 10, .h = 20 });
    try std.testing.expectEqual(
        Request{ .commit = .{ .surface = sid(3), .damage = .{ .x = 1, .y = 2, .w = 10, .h = 20 } } },
        try Request.decode(conn.transport.lastSent()),
    );

    try surface.setPosition(-40, 50);
    try std.testing.expectEqual(
        Request{ .set_position = .{ .surface = sid(3), .x = -40, .y = 50 } },
        try Request.decode(conn.transport.lastSent()),
    );

    try surface.destroy();
    try std.testing.expectEqual(
        Request{ .destroy_surface = .{ .surface = sid(3) } },
        try Request.decode(conn.transport.lastSent()),
    );
    try std.testing.expectEqual(@as(usize, 3), conn.transport.sent_len);
}

test "nextEvent decodes the server's event stream in order" {
    var conn: TestConn = .{ .transport = .{} };
    conn.transport.events[0] = (Event{ .pointer = .{ .surface = sid(3), .x = 7, .y = 8, .buttons = 1 } }).encode();
    conn.transport.events[1] = (Event{ .frame_done = .{ .surface = sid(3), .time_ms = 1234 } }).encode();

    try std.testing.expectEqual(
        Event{ .pointer = .{ .surface = sid(3), .x = 7, .y = 8, .buttons = 1 } },
        try conn.nextEvent(),
    );
    try std.testing.expectEqual(
        Event{ .frame_done = .{ .surface = sid(3), .time_ms = 1234 } },
        try conn.nextEvent(),
    );
}
