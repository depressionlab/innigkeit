//! A pure and host-testable byte-level walk over MADT interrupt-controller
//! entries.

/// entry_type: u8,
/// length: u8,
/// before the type-specific payload
const header_size = 2;

pub const RawEntry = struct {
    entry_type: u8,
    length: u8,
    /// Full entry bytes (the 2-byte header plus its type-specific payload),
    /// always exactly `length` bytes and always a subslice of the buffer
    /// `RawIterator` was given.
    bytes: []const u8,
};

pub const RawIterator = struct {
    bytes: []const u8,

    pub fn init(bytes: []const u8) RawIterator {
        return .{ .bytes = bytes };
    }

    /// `length` is firmware-supplied, so it's checked against what's
    /// actually left before being trusted, not just against zero. A
    /// zero-length entry would never advance `bytes`, hanging every
    /// caller's loop forever; an over-length entry would let a caller's
    /// payload read run past the table's mapped extent. Both are treated
    /// as end-of-table.
    pub fn next(self: *RawIterator) ?RawEntry {
        if (self.bytes.len < header_size) return null;
        const entry_type = self.bytes[0];
        const length = self.bytes[1];
        if (length == 0 or length > self.bytes.len) return null;

        const entry_bytes = self.bytes[0..length];
        self.bytes = self.bytes[length..];
        return .{ .entry_type = entry_type, .length = length, .bytes = entry_bytes };
    }
};

const std = @import("std");

test "RawIterator: rejects an entry whose length claims more than remains" {
    // 3 bytes remain but the entry claims 12!
    var buf = [_]u8{ 0x01, 12, 0xAA };
    var iter: RawIterator = .init(&buf);
    try std.testing.expect(iter.next() == null);
}

test "RawIterator: rejects a zero-length entry instead of hanging" {
    var buf = [_]u8{ 0x01, 0, 0xAA, 0xBB };
    var iter: RawIterator = .init(&buf);
    try std.testing.expect(iter.next() == null);
}

test "RawIterator: accepts a well-formed entry that exactly fills the remaining bytes" {
    var buf = [_]u8{ 0x01, 4, 0xAA, 0xBB };
    var iter: RawIterator = .init(&buf);
    const entry = iter.next() orelse return error.TestExpectedEntry;
    try std.testing.expectEqual(@as(u8, 0x01), entry.entry_type);
    try std.testing.expectEqual(@as(u8, 4), entry.length);
    try std.testing.expectEqualSlices(u8, &buf, entry.bytes);
    try std.testing.expect(iter.next() == null);
}

fn fuzzOne(_: void, smith: *std.testing.Smith) !void {
    var buf: [512]u8 = undefined;
    const len = smith.value(u9); // i.e. 0..511
    const input = buf[0..len];
    smith.bytes(input);

    var iter: RawIterator = .init(input);
    var entries: usize = 0;
    while (iter.next()) |entry| {
        // Every returned entry must be a real subslice of `input`: its
        // start and end both land within bounds, never past what was handed
        // in, regardless of what `length`/`entry_type` claim.
        const entry_start = @intFromPtr(entry.bytes.ptr);
        const entry_end = entry_start + entry.bytes.len;
        const input_start = @intFromPtr(input.ptr);
        const input_end = input_start + input.len;
        try std.testing.expect(entry_start >= input_start and entry_end <= input_end);
        try std.testing.expectEqual(entry.length, entry.bytes.len);

        // `bytes.len` strictly decreases every call (length >= 1 is
        // enforced above), so this can only run at most `input.len` times:
        // reaching that would itself indicate the strictly-decreasing
        // invariant broke.
        entries += 1;
        try std.testing.expect(entries <= input.len);
    }
}

test "fuzz: RawIterator.next never panics or hangs, and every entry stays within bounds" {
    try std.testing.fuzz({}, fuzzOne, .{});
}
