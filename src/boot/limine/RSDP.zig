//! RSDP Feature

const root = @import("root.zig");
const boot = @import("boot");

pub const Request = extern struct {
    id: [4]u64 = root.id(0xc5e77b6b397e7b43, 0x27637845accdcf3c),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    _address: boot.Address.Raw,

    /// Address of the RSDP table. Physical for base revision 3.
    pub fn address(response: *const Response, revision: root.BaseRevison.Revison) boot.Address {
        return switch (revision) {
            .@"3" => .{ .physical = response._address.physical },
            else => .{ .virtual = response._address.virtual },
        };
    }
};
