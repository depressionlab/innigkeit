//! The native display-server wire protocol.
//!
//! A typed layer over the IPC `Message` (8-byte tag + `4u64` words + 4 cap
//! handles). Requests flow client->server; events flow server->client (over the
//! per-client event Endpoint). Each direction is a tagged union whose variants
//! *carry their own typed args*, so an opcode can never exist without its arguments
//! and a caller cannot assemble a malformed request where the wire's illegal states
//! are unrepresentable.
//!
//! Opcodes (the union tag) are append-only ABI: never renumber a variant; add
//! new ones with fresh numbers. Requests occupy 1.., events 0x100.. so a stray
//! cross-direction message is obvious in a trace.

const std = @import("std");

const geometry = @import("geometry.zig");
const caps = @import("../capabilities.zig");

const Message = caps.Message;
const Handle = caps.Handle;
const Rect = geometry.Rect;
const SurfaceId = geometry.SurfaceId;

/// Pixel format of a surface buffer. Open enum (append, never renumber).
/// `bgrx8888` matches the scanout (display.zig): blue in bits [7:0].
pub const Format = enum(u32) { bgrx8888 = 0, _ };

/// A received message did not name a known opcode for its direction. Field
/// values ride in open enums/fixed-width ints, so only the opcode can be
/// unrecognised (forward/backward protocol skew), whereas everything else decodes.
pub const DecodeError = error{UnknownOpcode};

// word packing: The wire carries `4u64` words, so a pair of signed pixel coordinates (x,y or
// w,h) shares one word: low half = first, high half = second.

fn packXY(a: i32, b: i32) u64 {
    return @as(u64, @as(u32, @bitCast(a))) | (@as(u64, @as(u32, @bitCast(b))) << 32);
}
fn loI32(w: u64) i32 {
    return @bitCast(@as(u32, @truncate(w)));
}
fn hiI32(w: u64) i32 {
    return @bitCast(@as(u32, @truncate(w >> 32)));
}
fn sidWord(id: SurfaceId) u64 {
    return @intFromEnum(id);
}
fn wordSid(w: u64) SurfaceId {
    return @enumFromInt(@as(u32, @truncate(w)));
}

pub const RequestTag = enum(u64) {
    connect = 1,
    create_surface = 2,
    attach_buffer = 3,
    commit = 4,
    set_position = 5,
    destroy_surface = 6,
};

pub const Request = union(RequestTag) {
    /// Register the connecting client. caps[0] = the client's *event* Endpoint
    /// (server->client); the server keeps it to push `Event`s back.
    connect: struct { event_endpoint: Handle },

    /// Ask for a fresh surface; the server answers with `Event.surface_created`.
    create_surface: void,

    /// Bind a buffer to a surface. caps[0] = the buffer cap (a read-only copy of
    /// the client's `gpu_buffer`/`Frame`). `width`x`height` is the pixel geometry
    /// the buffer holds, in `format`.
    attach_buffer: struct { surface: SurfaceId, buffer: Handle, width: u32, height: u32, format: Format },

    /// Make the attached buffer current and repaint `damage` (surface-local).
    commit: struct { surface: SurfaceId, damage: Rect },

    /// Reposition a surface's top-left (native-WM move; xdg configure later).
    set_position: struct { surface: SurfaceId, x: i32, y: i32 },

    /// Drop a surface and release its resources.
    destroy_surface: struct { surface: SurfaceId },

    /// Serialize onto an IPC `Message` (tag = opcode; words/caps = the args).
    pub fn encode(self: Request) Message {
        var msg: Message = .{ .tag = @intFromEnum(std.meta.activeTag(self)) };
        switch (self) {
            .connect => |r| msg.caps[0] = @intFromEnum(r.event_endpoint),
            .create_surface => {},
            .attach_buffer => |r| {
                msg.words[0] = sidWord(r.surface);
                msg.words[1] = r.width;
                msg.words[2] = r.height;
                msg.words[3] = @intFromEnum(r.format);
                msg.caps[0] = @intFromEnum(r.buffer);
            },
            .commit => |r| {
                msg.words[0] = sidWord(r.surface);
                msg.words[1] = packXY(r.damage.x, r.damage.y);
                msg.words[2] = packXY(r.damage.w, r.damage.h);
            },
            .set_position => |r| {
                msg.words[0] = sidWord(r.surface);
                msg.words[1] = packXY(r.x, r.y);
            },
            .destroy_surface => |r| msg.words[0] = sidWord(r.surface),
        }
        return msg;
    }

    /// Parse a received `Message`. Errors only on an unknown opcode.
    pub fn decode(msg: Message) DecodeError!Request {
        const tag = std.enums.fromInt(RequestTag, msg.tag) orelse return error.UnknownOpcode;
        return switch (tag) {
            .connect => .{ .connect = .{ .event_endpoint = @enumFromInt(msg.caps[0]) } },
            .create_surface => .{ .create_surface = {} },
            .attach_buffer => .{ .attach_buffer = .{
                .surface = wordSid(msg.words[0]),
                .buffer = @enumFromInt(msg.caps[0]),
                .width = @truncate(msg.words[1]),
                .height = @truncate(msg.words[2]),
                .format = @enumFromInt(@as(u32, @truncate(msg.words[3]))),
            } },
            .commit => .{ .commit = .{
                .surface = wordSid(msg.words[0]),
                .damage = .{ .x = loI32(msg.words[1]), .y = hiI32(msg.words[1]), .w = loI32(msg.words[2]), .h = hiI32(msg.words[2]) },
            } },
            .set_position => .{ .set_position = .{
                .surface = wordSid(msg.words[0]),
                .x = loI32(msg.words[1]),
                .y = hiI32(msg.words[1]),
            } },
            .destroy_surface => .{ .destroy_surface = .{ .surface = wordSid(msg.words[0]) } },
        };
    }
};

pub const EventTag = enum(u64) {
    surface_created = 0x100,
    configure = 0x101,
    frame_done = 0x102,
    pointer = 0x103,
    key = 0x104,
    buffer_released = 0x105,
    closed = 0x106,
};

pub const Event = union(EventTag) {
    /// Answer to `create_surface`: the assigned id + a per-surface frame `Notify`
    /// (caps[0]) the client waits on for `frame_done`-style pacing.
    surface_created: struct { surface: SurfaceId, frame: Handle },

    /// The server asks the client to assume size `width`x`height`.
    configure: struct { surface: SurfaceId, width: u32, height: u32 },

    /// A frame for `surface` completed at `time_ms` (uptime); draw the next one.
    frame_done: struct { surface: SurfaceId, time_ms: u64 },

    /// Pointer is at surface-local (`x`,`y`); `buttons` bit0=left/1=right/2=mid.
    pointer: struct { surface: SurfaceId, x: i32, y: i32, buttons: u8 },

    /// Key `code` transitioned to `pressed` for the focused surface.
    key: struct { surface: SurfaceId, code: u32, pressed: bool },

    /// The server finished reading buffer slot `index`; the client may reuse it.
    buffer_released: struct { surface: SurfaceId, index: u32 },

    /// The server closed the surface (e.g. user closed the window); stop drawing.
    closed: struct { surface: SurfaceId },

    /// Serialize onto an IPC `Message` (tag = opcode; words/caps = the args).
    pub fn encode(self: Event) Message {
        var msg: Message = .{ .tag = @intFromEnum(std.meta.activeTag(self)) };
        switch (self) {
            .surface_created => |e| {
                msg.words[0] = sidWord(e.surface);
                msg.caps[0] = @intFromEnum(e.frame);
            },
            .configure => |e| {
                msg.words[0] = sidWord(e.surface);
                msg.words[1] = e.width;
                msg.words[2] = e.height;
            },
            .frame_done => |e| {
                msg.words[0] = sidWord(e.surface);
                msg.words[1] = e.time_ms;
            },
            .pointer => |e| {
                msg.words[0] = sidWord(e.surface);
                msg.words[1] = packXY(e.x, e.y);
                msg.words[2] = e.buttons;
            },
            .key => |e| {
                msg.words[0] = sidWord(e.surface);
                msg.words[1] = e.code;
                msg.words[2] = @intFromBool(e.pressed);
            },
            .buffer_released => |e| {
                msg.words[0] = sidWord(e.surface);
                msg.words[1] = e.index;
            },
            .closed => |e| msg.words[0] = sidWord(e.surface),
        }
        return msg;
    }

    /// Parse a received `Message`. Errors only on an unknown opcode.
    pub fn decode(msg: Message) DecodeError!Event {
        const tag = std.enums.fromInt(EventTag, msg.tag) orelse return error.UnknownOpcode;
        return switch (tag) {
            .surface_created => .{ .surface_created = .{ .surface = wordSid(msg.words[0]), .frame = @enumFromInt(msg.caps[0]) } },
            .configure => .{ .configure = .{ .surface = wordSid(msg.words[0]), .width = @truncate(msg.words[1]), .height = @truncate(msg.words[2]) } },
            .frame_done => .{ .frame_done = .{ .surface = wordSid(msg.words[0]), .time_ms = msg.words[1] } },
            .pointer => .{ .pointer = .{
                .surface = wordSid(msg.words[0]),
                .x = loI32(msg.words[1]),
                .y = hiI32(msg.words[1]),
                .buttons = @truncate(msg.words[2]),
            } },
            .key => .{ .key = .{
                .surface = wordSid(msg.words[0]),
                .code = @truncate(msg.words[1]),
                .pressed = msg.words[2] != 0,
            } },
            .buffer_released => .{ .buffer_released = .{ .surface = wordSid(msg.words[0]), .index = @truncate(msg.words[1]) } },
            .closed => .{ .closed = .{ .surface = wordSid(msg.words[0]) } },
        };
    }
};

fn sid(n: u32) SurfaceId {
    return @enumFromInt(n);
}
fn handle(n: u32) Handle {
    return @enumFromInt(n);
}

test "Request: every variant round-trips through a Message" {
    const cases = [_]Request{
        .{ .connect = .{ .event_endpoint = handle(7) } },
        .{ .create_surface = {} },
        .{ .attach_buffer = .{ .surface = sid(3), .buffer = handle(9), .width = 640, .height = 480, .format = .bgrx8888 } },
        .{ .commit = .{ .surface = sid(3), .damage = .{ .x = -5, .y = 12, .w = 100, .h = 50 } } },
        .{ .set_position = .{ .surface = sid(3), .x = -1920, .y = 1080 } },
        .{ .destroy_surface = .{ .surface = sid(3) } },
    };
    for (cases) |req| {
        const decoded = try Request.decode(req.encode());
        try std.testing.expectEqual(req, decoded);
    }
}

test "Event: every variant round-trips through a Message" {
    const cases = [_]Event{
        .{ .surface_created = .{ .surface = sid(1), .frame = handle(42) } },
        .{ .configure = .{ .surface = sid(1), .width = 800, .height = 600 } },
        .{ .frame_done = .{ .surface = sid(1), .time_ms = 0xDEAD_BEEF_1234 } },
        .{ .pointer = .{ .surface = sid(1), .x = -3, .y = 7, .buttons = 0b101 } },
        .{ .key = .{ .surface = sid(1), .code = 65, .pressed = true } },
        .{ .key = .{ .surface = sid(1), .code = 65, .pressed = false } },
        .{ .buffer_released = .{ .surface = sid(1), .index = 1 } },
        .{ .closed = .{ .surface = sid(1) } },
    };
    for (cases) |ev| {
        const decoded = try Event.decode(ev.encode());
        try std.testing.expectEqual(ev, decoded);
    }
}

test "decode rejects an unknown opcode in each direction" {
    var msg: Message = .{ .tag = 0xFFFF };
    try std.testing.expectError(error.UnknownOpcode, Request.decode(msg));
    try std.testing.expectError(error.UnknownOpcode, Event.decode(msg));
    // A request opcode is not a valid event opcode and vice-versa.
    msg.tag = @intFromEnum(RequestTag.commit);
    try std.testing.expectError(error.UnknownOpcode, Event.decode(msg));
}

test "encode writes the opcode into the message tag" {
    const req: Request = .{ .commit = .{ .surface = sid(2), .damage = .{} } };
    try std.testing.expectEqual(@intFromEnum(RequestTag.commit), req.encode().tag);
    const ev: Event = .{ .closed = .{ .surface = sid(2) } };
    try std.testing.expectEqual(@intFromEnum(EventTag.closed), ev.encode().tag);
}
