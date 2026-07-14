const core = @import("core");
const std = @import("std");

/// Base protocol revisions change certain behaviours of the Limine boot protocol outside any specific feature.
///
/// The specifics are going to be described as needed throughout this specification.
pub const BaseRevison = extern struct {
    id: [2]u64 = [_]u64{ 0xF9562B2D5C95A6C8, 0x6A7B384944536BDC },

    /// The Limine boot protocol comes in several base revisions; so far, 7 base revisions are specified: 0 through 6.
    ///
    /// Base revision 0 through 5 are considered deprecated.
    ///
    /// Base revision 0 is the default base revision an executable is assumed to be requesting and complying to if no base revision tag is
    /// provided by the executable, for backwards compatibility.
    ///
    /// A base revision tag is a set of 3 64-bit values placed somewhere in the loaded executable image on an 8-byte aligned boundary;
    /// the first 2 values are a magic number for the bootloader to be able to identify the tag, and the last value is the requested base
    /// revision number.
    ///
    /// If a bootloader drops support for an older base revision, the bootloader must fail to boot an executable requesting such base
    /// revision.
    ///
    /// If a bootloader does not yet support a requested base revision (i.e. if the requested base revision is higher than the
    /// maximum base revision supported), it may boot the executable using any arbitrary revision it supports, and communicate failure to
    /// comply to the executable by *leaving the 3rd component of the base revision tag unchanged*.
    ///
    /// The bootloader may also refuse to boot executables requesting a base revision that it does not yet support, and this is the expected
    /// and strongly recommended behaviour for bootloaders moving forward, but it is not guaranteed since older bootloaders may not support
    /// base revisions at all.
    ///
    /// On the other hand, if the executable's requested base revision is supported, *the 3rd component of the base revision tag must be
    /// set to 0 by the bootloader*.
    ///
    /// Note: this means that unlike when the bootloader drops support for an older base revision and *it* is responsible for failing to
    /// boot the executable, in case the bootloader does not yet support the executable's requested base revision, it is up to the executable
    /// itself to fail (or handle the condition otherwise), in order to deal with older bootloader implementations.
    ///
    /// For any Limine-compliant bootloader supporting base revision 3 or greater, if choosing to boot an executable expecting a base
    /// revision the bootloader does not yet support (which is discouraged for new bootloader implementations), it is *mandatory* to load
    /// such executables using at least base revision 3, and it is mandatory for it to always set the 2nd component of the base revision tag
    /// to the base revision actually used to load the executable, regardless of whether it was the requested one or not.
    ///
    /// **WARNING**: if the requested revision is supported this is set to 0
    revison: Revison,

    pub const Revison = enum(u64) {
        @"0" = 0,
        @"1" = 1,
        @"2" = 2,
        @"3" = 3,
        @"4" = 4,
        @"5" = 5,
        @"6" = 6,

        _,

        pub fn equalToOrGreaterThan(revision: Revison, other: Revison) bool {
            return @intFromEnum(revision) >= @intFromEnum(other);
        }
    };

    /// Returns the revision that the bootloader is providing or `null` if the requested revision is unknown to the bootloader.
    pub fn loadedRevision(base_revision: *const BaseRevison) ?Revison {
        if (base_revision.id[1] == 0x6A7B384944536BDC) return null;
        return @enumFromInt(base_revision.id[1]);
    }

    comptime {
        core.testing.expectSize(BaseRevison, core.Size.of(u64).multiplyScalar(3));
    }
};

comptime {
    std.testing.refAllDecls(@This());
}
