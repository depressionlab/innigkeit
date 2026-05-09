const core = @import("core");
const x64 = @import("../x64.zig");

/// The method used to save extended state.
///
/// UNDEFINED: xsave is asserted to be supported
pub var method: Method = undefined;

/// The value that each executor sets XCr0 to, also used on extended state save/restore.
///
/// UNDEFINED: xsave is asserted to be supported
pub var xcr0_value: x64.registers.XCr0 = undefined;

/// The size of the xsave area.
///
/// UNDEFINED: xsave is asserted to be supported
pub var xsave_area_size: core.Size = undefined;

pub const Method = enum {
    xsave,
    xsaveopt,
};
