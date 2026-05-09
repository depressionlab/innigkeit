//! This module contains the definitions of the Limine protocol as of 6f3fafe337c30f94e7c2f5c4a21498346c5604bf.
//!
//! [PROTOCOL DOC](https://github.com/Limine-Bootloader/limine-protocol/blob/6f3fafe337c30f94e7c2f5c4a21498346c5604bf/PROTOCOL.md)

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const boot = @import("boot");
const UUID = @import("uuid").UUID;

pub const BootloaderInfo = @import("BootloaderInfo.zig");
pub const BootloaderPerformance = @import("BootloaderPerformance.zig");
pub const DateAtBoot = @import("DateAtBoot.zig");
pub const DeviceTreeBlob = @import("DeviceTreeBlob.zig");
pub const EFIMemoryMap = @import("EFIMemoryMap.zig");
pub const EFISystemTable = @import("EFISystemTable.zig");
pub const EntryPoint = @import("EntryPoint.zig");
pub const ExecutableAddress = @import("ExecutableAddress.zig");
pub const ExecutableCommandline = @import("ExecutableCommandline.zig");
pub const ExecutableFile = @import("ExecutableFile.zig");
pub const FirmwareType = @import("FirmwareType.zig");
pub const FlantermFramebuffer = @import("FlantermFramebuffer.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const HHDM = @import("HHDM.zig");
pub const KeepIOMMU = @import("KeepIOMMU.zig");
pub const MemoryMap = @import("MemoryMap.zig");
pub const Module = @import("Module.zig");
pub const MP = @import("MP.zig");
pub const PagingMode = @import("PagingMode.zig");
pub const BSPHartID = @import("BSPHartID.zig");
pub const RSDP = @import("RSDP.zig");
pub const SMBIOS = @import("SMBIOS.zig");
pub const StackSize = @import("StackSize.zig");
pub const TSCFrequency = @import("TSCFrequency.zig");

/// Generates a Limine protocol request identifier.
pub fn id(a: u64, b: u64) [4]u64 {
    return .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b };
}

/// Base protocol revisions change certain behaviours of the Limine boot protocol outside any specific feature.
///
/// The specifics are going to be described as needed throughout this specification.
pub const BaseRevison = extern struct {
    id: [2]u64 = [_]u64{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc },

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
        if (base_revision.id[1] == 0x6a7b384944536bdc) return null;
        return @enumFromInt(base_revision.id[1]);
    }

    comptime {
        core.testing.expectSize(BaseRevison, core.Size.of(u64).multiplyScalar(3));
    }
};

/// The bootloader can be told to start and/or stop searching for requests (including base revision tags) in an executable's loaded image
/// by placing start and/or end markers, on an 8-byte aligned boundary.
///
/// The bootloader will only accept requests placed between the last start marker found (if there happen to be more than 1, which there
/// should not, ideally) and the first end marker found.
///
/// For base revisions 0 and 1, the requests delimiters are *hints*. The bootloader can still search for requests and base revision tags
/// outside the delimited area if it doesn't support the hints.
///
/// Base revision 2's sole difference compared to base revision 1 is that support for request delimiters has to be provided and the
/// delimiters must be honoured, if present, rather than them just being a hint.
pub const RequestDelimiters = struct {
    pub const start_marker = extern struct {
        id: [4]u64 = [_]u64{
            0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf,
            0x785c6ed015d3e316, 0x181e920a7852b9d9,
        },
    };

    pub const end_marker = extern struct {
        id: [2]u64 = [_]u64{
            0xadc0e0531bb10d03, 0x9572709f31764c62,
        },
    };
};

pub const Uuid = extern struct {
    a: u32,
    b: u16,
    c: u16,
    d: [8]u8,
};

pub const MediaType = enum(u32) {
    generic = 0,
    optical = 1,
    tftp = 2,
    _,
};

pub const File = extern struct {
    revision: u64,

    /// The address of the file. This is always at least 4KiB aligned.
    address: innigkeit.KernelVirtualAddress,

    /// The size of the file.
    ///
    /// Regardless of the file size, all loaded modules are guaranteed to have all 4KiB chunks of memory they cover for
    /// themselves exclusively.
    size: core.Size,

    /// The path of the file within the volume, with a leading slash
    _path: [*:0]const u8,

    /// A string associated with the file
    _string: ?[*:0]const u8,

    media_type: File.MediaType,

    unused: u32,

    /// If non-0, this is the IP of the TFTP server the file was loaded from.
    tftp_ip: u32,
    /// Likewise, but port.
    tftp_port: u32,

    /// 1-based partition index of the volume from which the file was loaded.
    ///
    /// If 0, it means invalid or unpartitioned.
    partition_index: u32,

    /// If non-0, this is the ID of the disk the file was loaded from as reported in its MBR.
    mbr_disk_id: u32,

    /// If non-0, this is the UUID of the disk the file was loaded from as reported in its GPT.
    gpt_disk_uuid: UUID,

    /// If non-0, this is the UUID of the partition the file was loaded from as reported in the GPT.
    gpt_part_uuid: UUID,

    /// If non-0, this is the UUID of the filesystem of the partition the file was loaded from.
    part_uuid: UUID,

    /// The path of the file within the volume, with a leading slash
    pub fn path(file: *const File) [:0]const u8 {
        return std.mem.sliceTo(file._path, 0);
    }

    /// A string associated with the file
    pub fn string(file: *const File) ?[:0]const u8 {
        const str = std.mem.sliceTo(
            file._string orelse return null,
            0,
        );
        return if (str.len == 0) null else str;
    }

    pub fn getContents(file: *const File) []const u8 {
        return innigkeit.KernelVirtualRange.from(file.address, file.size).byteSlice();
    }

    pub fn print(file: *const File, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("File{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("path: \"{s}\"\n", .{file.path()});

        if (file.string()) |s| {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("string: \"{s}\"\n", .{s});
        }

        try writer.splatByteAll(' ', new_indent);
        try writer.print("address: {f}\n", .{file.address});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("size: {f}\n", .{file.size});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("media_type: {t}\n", .{file.media_type});

        if (file.tftp_ip != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.writeAll("tftp: ");
            try formatIP(file.tftp_ip, file.tftp_port, writer);
            try writer.writeByte('\n');
        }

        if (file.partition_index != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("partition_index: {}\n", .{file.partition_index});
        }

        if (file.mbr_disk_id != 0) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("mbr_disk_id: {}\n", .{file.mbr_disk_id});
        }

        if (!file.gpt_disk_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_disk_uuid: {f}\n", .{file.gpt_disk_uuid});
        }

        if (!file.gpt_part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("gpt_part_uuid: {f}\n", .{file.gpt_part_uuid});
        }

        if (!file.part_uuid.eql(.nil)) {
            try writer.splatByteAll(' ', new_indent);
            try writer.print("part_uuid: {f}\n", .{file.part_uuid});
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    fn formatIP(ip: u32, port: u32, writer: *std.Io.Writer) !void {
        const bytes: *const [4]u8 = @ptrCast(&ip);
        try writer.print("{}.{}.{}.{}:{}", .{
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            port,
        });
    }

    pub inline fn format(file: *const File, writer: *std.Io.Writer) !void {
        return File.print(file, writer, 0);
    }

    pub const MediaType = enum(u32) {
        generic = 0,
        optical = 1,
        tftp = 2,
        _,
    };
};

const Arch = enum {
    aarch64,
    loongarch64,
    riscv64,
    x86_64,
};

pub const arch: Arch = switch (@import("builtin").cpu.arch) {
    .aarch64 => .aarch64,
    .loongarch64 => .loongarch64,
    .riscv64 => .riscv64,
    .x86_64 => .x86_64,
    else => |e| @compileError("unsupported architecture " ++ @tagName(e)),
};

comptime {
    std.testing.refAllDecls(@This());
}
