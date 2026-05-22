pub const ObjectType = enum(u8) {
    null = 0,
    frame = 1,
    notify = 2,
    endpoint = 3,
    /// Single-use reply token created by recv_call.
    reply = 4,
};
