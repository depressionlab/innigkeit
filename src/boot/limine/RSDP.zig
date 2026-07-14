//! RSDP Feature

const boot = @import("boot");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0xC5E77B6B397E7B43, 0x27637845ACCDCF3C),
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
