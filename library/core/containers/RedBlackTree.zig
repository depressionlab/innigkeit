const std = @import("std");

root: ?*Node = null,

/// cached first node
first: ?*Node = null,

/// cached last node
last: ?*Node = null,

size: usize = 0,

const Color = enum(u1) {
    black,
    red,
};

const Side = enum(u1) {
    left,
    right,

    fn flip(self: Side) Side {
        return @enumFromInt(1 - @intFromEnum(self));
    }
};

const ColorSideAndParent = packed struct {
    color: Color = .black,
    side: Side = .left,
    isolated: bool = true,
    pointer: u61 = 0,
};

pub const Node = struct {
    left: ?*Node = null,
    right: ?*Node = null,

    // parent pointerless red-black trees can't have simple
    // and efficient iterators and memory saving isn't very great
    extra: ColorSideAndParent = .{},
};
