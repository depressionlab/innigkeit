//! EFI System Table Feature

const root = @import("root.zig");
const boot = @import("boot");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x5ceba5163eaaf6d6, 0x0a6981610cf65fcc),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    _address: boot.Address.Raw,

    /// Address of EFI system table. Physical for base revision 3 or 4.
    pub fn address(self: *const Response, revision: root.BaseRevison.Revison) boot.Address {
        return switch (revision) {
            .@"3", .@"4" => .{ .physical = self._address.physical },
            else => .{ .virtual = self._address.virtual },
        };
    }
};
