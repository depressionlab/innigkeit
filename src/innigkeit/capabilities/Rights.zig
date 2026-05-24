pub const Rights = packed struct(u16) {
    /// Can read from / receive messages through this capability.
    read: bool = false,
    /// Can write to / send messages through this capability.
    write: bool = false,
    /// Can transfer a copy of this capability to another process.
    grant: bool = false,
    /// Can revoke this capability for all holders (increments the object's generation counter).
    revoke: bool = false,
    _pad: u12 = 0,

    pub const all: Rights = .{ .read = true, .write = true, .grant = true, .revoke = true };
    pub const read_only: Rights = .{ .read = true };
    pub const write_only: Rights = .{ .write = true };
};
