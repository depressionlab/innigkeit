const std = @import("std");

pub const MAX = 32;

const EnvEntry = struct {
    key: [32]u8,
    klen: u8,
    val: [128]u8,
    vlen: u8,
};

pub var table: [MAX]EnvEntry = undefined;
pub var count: usize = 0;

pub fn get(key: []const u8) ?[]const u8 {
    for (table[0..count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.klen], key)) return e.val[0..e.vlen];
    }
    return null;
}

pub fn set(key: []const u8, val: []const u8) void {
    for (table[0..count]) |*e| {
        if (std.mem.eql(u8, e.key[0..e.klen], key)) {
            const vl = @min(val.len, 127);
            @memcpy(e.val[0..vl], val[0..vl]);
            e.vlen = @intCast(vl);
            return;
        }
    }
    if (count >= MAX) return;
    var e = &table[count];
    const kl = @min(key.len, 31);
    const vl = @min(val.len, 127);
    @memcpy(e.key[0..kl], key[0..kl]);
    e.klen = @intCast(kl);
    @memcpy(e.val[0..vl], val[0..vl]);
    e.vlen = @intCast(vl);
    count += 1;
}

/// Expand $VARNAME at `input[pos]` (pos points at '$'). Copies the value into
/// storage[spos..], advances *pos past the name, advances *spos past the value.
pub fn expand(input: []const u8, pos: *usize, storage: []u8, spos: *usize) void {
    pos.* += 1; // skip '$'
    const vstart = pos.*;
    while (pos.* < input.len and isIdentChar(input[pos.*])) pos.* += 1;
    const varval = get(input[vstart..pos.*]) orelse "";
    const copy_len = @min(varval.len, storage.len - spos.*);
    @memcpy(storage[spos.*..][0..copy_len], varval[0..copy_len]);
    spos.* += copy_len;
}

/// True for chars that may appear in a shell variable name: [A-Za-z0-9_].
fn isIdentChar(c: u8) bool {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => true,
        else => false,
    };
}
