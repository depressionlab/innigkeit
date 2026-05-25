//! VirtIO-blk, NVMe, ATA, USB mass storage all speak this protocol.
//! Filesystem drivers consume it. Every layer boundary is a capability (Endpoint).
//! New drivers just implement the Handler interface and call serve().
//!
//! Message encoding:
//!   Request:  tag = @intFromEnum(Op), words[0..] = args, caps[0..] = cap args
//!   Success:  tag = 0, words[0..] = return values, caps[0..] = returned caps
//!   Error:    tag = error_code (non-zero Error enum value), all others zero

const innigkeit = @import("innigkeit");
const std = @import("std");

/// Operation tags (used as message tag field).
pub const Op = enum(u64) {
    get_info = 0, // -> BlockInfo
    read = 1, // lba: u64, count: u32 -> caps[0]=Frame (data)
    write = 2, // lba: u64, count: u32, caps[0]=data Frame -> void
    flush = 3, // -> void (drain volatile write cache)
    discard = 4, // lba: u64, count: u64 -> void (TRIM hint)
    _,
};

/// Information about a block device.
pub const BlockInfo = extern struct {
    block_size: u32, // logical sector size (512 or 4096)
    phys_block_size: u32, // physical sector size (for alignment)
    block_count: u64, // total logical sectors
    max_transfer_blocks: u32, // max blocks per read/write request
    flags: BlockFlags,
    _pad: u32 = 0,
};

/// Feature flags for a block device.
pub const BlockFlags = packed struct(u32) {
    read_only: bool = false,
    flush: bool = false, // flush/fsync supported
    discard: bool = false, // TRIM supported
    write_zeroes: bool = false,
    atomic_writes: bool = false,
    zoned: bool = false, // Zoned Namespace (ZNS/SMR) storage
    _: u26 = 0,
};

/// Error codes returned in response tag (non-zero = error).
pub const Error = enum(u64) {
    none = 0,
    not_ready = 1,
    io_error = 2,
    out_of_range = 3,
    read_only = 4,
    not_supported = 5,
};

/// Thin client wrapper around endpointCall for each block operation.
pub const Client = struct {
    handle: innigkeit.capabilities.Handle,

    /// Query block device information.
    pub fn getInfo(self: Client) !BlockInfo {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(Op.get_info),
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(Error.none)) return error.BlockError;
        // BlockInfo fits in 4 words (32 bytes): block_size(4)+phys_block_size(4)+block_count(8)+max_transfer_blocks(4)+flags(4)+pad(4) = 28 bytes
        var info: BlockInfo = undefined;
        @memcpy(
            @as([*]u8, @ptrCast(&info))[0..@sizeOf(BlockInfo)],
            @as([*]const u8, @ptrCast(&msg.words))[0..@sizeOf(BlockInfo)],
        );
        return info;
    }

    /// Read `count` blocks starting at `lba`. Returns a Frame capability handle
    /// containing the data. The caller is responsible for unmapping and deleting
    /// the Frame when done.
    pub fn read(self: Client, lba: u64, count: u32) !innigkeit.capabilities.Handle {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(Op.read),
            .words = .{ lba, @as(u64, count), 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(Error.none)) return error.BlockError;
        const frame_handle = msg.caps[0];
        if (frame_handle == 0) return error.BlockError;
        return frame_handle;
    }

    /// Write `count` blocks starting at `lba` from the provided Frame.
    pub fn write(self: Client, lba: u64, count: u32, frame: innigkeit.capabilities.Handle) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(Op.write),
            .words = .{ lba, @as(u64, count), 0, 0 },
            .caps = .{ frame, 0, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(Error.none)) return error.BlockError;
    }

    /// Flush the device's volatile write cache.
    pub fn flush(self: Client) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(Op.flush),
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(Error.none)) return error.BlockError;
    }

    /// Send a TRIM/discard hint for `count` blocks starting at `lba`.
    pub fn discard(self: Client, lba: u64, count: u64) !void {
        var msg: innigkeit.capabilities.Message = .{
            .tag = @intFromEnum(Op.discard),
            .words = .{ lba, count, 0, 0 },
        };
        try innigkeit.capabilities.endpointCall(self.handle, &msg);
        if (msg.tag != @intFromEnum(Error.none)) return error.BlockError;
    }
};

/// Handler vtable: implementors fill this struct and call serve().
pub const Handler = struct {
    getInfo: *const fn (ctx: *anyopaque) BlockInfo,
    read: *const fn (ctx: *anyopaque, lba: u64, count: u32) Error!innigkeit.capabilities.Handle,
    write: *const fn (ctx: *anyopaque, lba: u64, count: u32, frame: innigkeit.capabilities.Handle) Error!void,
    flush: *const fn (ctx: *anyopaque) Error!void,
    discard: *const fn (ctx: *anyopaque, lba: u64, count: u64) Error!void,
    ctx: *anyopaque,
};

/// Serve requests on `endpoint` forever, dispatching to `handler`.
///
/// Uses endpointRecv + endpointReplyRecv hot path.
/// Never returns.
pub fn serve(endpoint: innigkeit.capabilities.Handle, handler: Handler) noreturn {
    var msg: innigkeit.capabilities.Message = .{};
    // Initial recv to get the first message.
    innigkeit.capabilities.endpointRecv(endpoint, &msg) catch @panic("block.serve: initial recv failed");

    while (true) {
        const op_raw = msg.tag;
        // Save request fields before we build the reply (reply reuses msg).
        const req_words = msg.words;
        const req_caps = msg.caps;
        var reply: innigkeit.capabilities.Message = .{};

        if (std.enums.fromInt(Op, op_raw)) |op| {
            switch (op) {
                .get_info => {
                    const info = handler.getInfo(handler.ctx);
                    reply.tag = @intFromEnum(Error.none);
                    @memcpy(
                        @as([*]u8, @ptrCast(&reply.words))[0..@sizeOf(BlockInfo)],
                        @as([*]const u8, @ptrCast(&info))[0..@sizeOf(BlockInfo)],
                    );
                },
                .read => {
                    const lba = req_words[0];
                    const count: u32 = @truncate(req_words[1]);
                    if (handler.read(handler.ctx, lba, count)) |frame_handle| {
                        reply.tag = @intFromEnum(Error.none);
                        reply.caps[0] = frame_handle;
                    } else |err| {
                        reply.tag = @intFromEnum(err);
                    }
                },
                .write => {
                    const lba = req_words[0];
                    const count: u32 = @truncate(req_words[1]);
                    const frame_handle = req_caps[0];
                    if (handler.write(handler.ctx, lba, count, frame_handle)) {
                        reply.tag = @intFromEnum(Error.none);
                    } else |err| {
                        reply.tag = @intFromEnum(err);
                    }
                },
                .flush => {
                    if (handler.flush(handler.ctx)) {
                        reply.tag = @intFromEnum(Error.none);
                    } else |err| {
                        reply.tag = @intFromEnum(err);
                    }
                },
                .discard => {
                    const lba = req_words[0];
                    const count = req_words[1];
                    if (handler.discard(handler.ctx, lba, count)) {
                        reply.tag = @intFromEnum(Error.none);
                    } else |err| {
                        reply.tag = @intFromEnum(err);
                    }
                },
                _ => {
                    reply.tag = @intFromEnum(Error.not_supported);
                },
            }
        } else {
            reply.tag = @intFromEnum(Error.not_supported);
        }

        // replyRecv atomically sends the reply and waits for the next request.
        // On return, `msg` is overwritten with the next incoming request.
        msg = reply;
        innigkeit.capabilities.endpointReplyRecv(endpoint, &msg) catch @panic("block.serve: replyRecv failed");
    }
}
