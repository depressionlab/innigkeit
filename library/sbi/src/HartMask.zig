pub const HartMask = union(enum) {
    /// all available ids must be considered
    all,
    mask: struct {
        /// a scalar bit-vector containing hartids
        mask: usize,
        /// the starting hartid from which the bit-vector must be computed
        base: usize,
    },

    fn toMaskAndBase(self: HartMask) struct { isize, isize } {
        return switch (self) {
            .all => .{ 0, -1 },
            .mask => |m| .{ @bitCast(m.mask), @bitCast(m.base) },
        };
    }
};
