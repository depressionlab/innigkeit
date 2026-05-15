pub const Rights = packed struct(u16) {
    /// Can read from / receive messages through this capability.
    read: bool = false,
    /// Can write to / send messages through this capability.
    write: bool = false,
    /// Can transfer a copy of this capability to another process.
    grant: bool = false,
    _pad: u13 = 0,

    pub const all: Rights = .{ .read = true, .write = true, .grant = true };
    pub const read_only: Rights = .{ .read = true };
    pub const write_only: Rights = .{ .write = true };
};
