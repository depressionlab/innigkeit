//! SMBIOS Feature

const boot = @import("boot");
const root = @import("root.zig");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x9E9046F11E095391, 0xAA4A520FEFBDE5EE),
    revision: u64 = 0,

    response: ?*const Response = null,
};

pub const Response = extern struct {
    revision: u64,
    _entry_32: boot.Address.Raw,
    _entry_64: boot.Address.Raw,

    /// Address of the 32-bit SMBIOS entry point, `null` if not present. Physical for base revision 3 or 4.
    pub fn entry32(response: *const Response, revision: root.BaseRevison.Revison) boot.Address {
        return switch (revision) {
            .@"3", .@"4" => .{ .physical = response._entry_32.physical },
            else => .{ .virtual = response._entry_32.virtual },
        };
    }

    /// Address of the 64-bit SMBIOS entry point, `null` if not present. Physical for base revision 3 or 4.
    pub fn entry64(response: *const Response, revision: root.BaseRevison.Revison) boot.Address {
        return switch (revision) {
            .@"3", .@"4" => .{ .physical = response._entry_64.physical },
            else => .{ .virtual = response._entry_64.virtual },
        };
    }
};
