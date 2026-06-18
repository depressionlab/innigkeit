//! Module Feature
//!
//! When Secure Boot is active, every loaded file must have an associated blake2b hash,
//! and internal modules are no exception: a path lacking a #<hash> suffix will cause
//! the bootloader to panic, regardless of the LIMINE_INTERNAL_MODULE_REQUIRED flag.
//! There is no separate hash field on struct limine_internal_module; the hash must be
//! appended to the path string. Executables intended to be bootable under Secure Boot
//! must therefore embed the precomputed hash of each internal module in the path
//! they hand to the bootloader.

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x3e7e279702be32af, 0xca1c4f3bd1280cee),
    revision: u64 = 0,

    response: ?*const Response = null,

    /// Request revision 1 required
    _internal_module_count: u64 = 0,

    /// Request revision 1 required
    _internal_modules: ?[*]const *const InternalModule = null,

    /// Request revision 1 required
    pub fn withInternalModules(internal_modules: []const *const InternalModule) Request {
        return .{
            .revision = 1,
            ._internal_module_count = internal_modules.len,
            ._internal_modules = internal_modules.ptr,
        };
    }
};

pub const Response = extern struct {
    revision: u64,
    _module_count: u64,
    _modules: [*]const *const root.File,

    pub fn modules(self: *const Response) []const *const root.File {
        return self._modules[0..self._module_count];
    }

    pub fn print(self: *const Response, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        if (self._module_count == 0) {
            try writer.writeAll("Modules{}");
            return;
        }

        try writer.writeAll("Modules{\n");

        for (self.modules()) |module| {
            try writer.splatByteAll(' ', new_indent + 2);
            try module.print(writer, new_indent + 2);
            try writer.writeByte('\n');
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const Response, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

/// Internal Limine modules are guaranteed to be loaded before user-specified (configuration) modules, and thus they are guaranteed to
/// appear before user-specified modules in the modules array in the response.
///
/// When Secure Boot is active, every loaded file must have an associated blake2b hash, and internal modules are no exception: a `path`
/// lacking a `#<hash>` suffix will cause the bootloader to panic, regardless of the `LIMINE_INTERNAL_MODULE_REQUIRED` flag.
///
/// There is no separate hash field on `struct limine_internal_module`; the hash must be appended to the `path` string.
///
/// Executables intended to be bootable under Secure Boot must therefore embed the precomputed hash of each internal module in the path
/// they hand to the bootloader.
pub const InternalModule = extern struct {
    /// Path to the module to load.
    ///
    /// This path is relative to the location of the executable.
    ///
    /// The path may be suffixed with `#` followed by a 128-character hexadecimal blake2b hash of the file contents, in which case the
    /// bootloader will verify the hash before honouring the module.
    path: [*:0]const u8,

    /// String associated with the given module.
    _string: ?[*:0]const u8,

    /// Flags changing module loading behaviour
    flags: Flags,

    /// String associated with the given module.
    pub fn string(self: *const InternalModule) ?[:0]const u8 {
        return if (self._string) |s|
            std.mem.sliceTo(s, 0)
        else
            null;
    }

    pub const Flags = packed struct(u64) {
        /// If `true` then fail if the requested module is not found.
        required: bool = false,

        /// The module is GZ-compressed and should be decompressed by the bootloader.
        ///
        /// This is honoured if the response is revision 2 or greater.
        compressed: bool = false,

        _reserved: u62 = 0,
    };
};
