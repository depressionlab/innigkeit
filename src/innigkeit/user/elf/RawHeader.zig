//! Pure byte-decode of the fixed-size ELF header, deliberately free of any
//! kernel-module import (`innigkeit`/`architecture`/`core`) so it can be
//! compiled and fuzzed on the host via `zig build test_native --fuzz`.
//!
//! `Header.zig` wraps this into the richer, typed `Header` (`ObjectType`,
//! `Machine`, `innigkeit.VirtualAddress`, `core.Size`) that the rest of the
//! kernel depends on. Referencing any of those types would force the whole
//! `innigkeit` module to resolve.
const std = @import("std");

pub const ParseError = error{
    TruncatedInput,
    InvalidMagic,
    InvalidVersion,
    InvalidEndian,
    InvalidClass,
};

/// Raw ELF header fields, decoded but not yet reinterpreted as this
/// project's own typed wrappers.
pub const RawHeader = struct {
    is_64: bool,
    endian: std.builtin.Endian,
    type: u16,
    machine: u16,
    entry: u64,
    program_header_offset: u64,
    program_header_entry_size: u16,
    program_header_entry_count: u16,
    section_header_offset: u64,
    section_header_entry_size: u16,
    section_header_entry_count: u16,
    section_name_string_table_index: u16,
};

/// Parse the given slice into a `RawHeader`.
///
/// The slice must be atleast 64 bytes long.
pub fn parse(elf_header_slice: []const u8) ParseError!RawHeader {
    if (elf_header_slice.len < 64) return error.TruncatedInput;

    const ident: HeaderIdent = .from(elf_header_slice);
    if (!std.mem.eql(u8, ident.magic(), HeaderIdent.MAGIC)) return error.InvalidMagic;
    if (ident.version() != current_version) return error.InvalidVersion;

    const endian: std.builtin.Endian = switch (ident.endian()) {
        .little => .little,
        .big => .big,
        else => return error.InvalidEndian,
    };

    const is_64: bool = switch (ident.class()) {
        .@"32" => false,
        .@"64" => true,
        else => return error.InvalidClass,
    };

    return if (is_64)
        innerParse(elf_header_slice, true, endian)
    else
        innerParse(elf_header_slice, false, endian);
}

/// EI_VERSION's only defined value (matches `innigkeit.user.elf.Version.current`).
const current_version = 1;

fn innerParse(elf_header_slice: []const u8, comptime is_64: bool, endian: std.builtin.Endian) ParseError!RawHeader {
    const HeaderT = if (is_64) RawElf64Header else RawElf32Header;
    const FileOffset = if (is_64) u64 else u32;
    const raw_elf_header: *align(1) const HeaderT = std.mem.bytesAsValue(HeaderT, elf_header_slice);

    return .{
        .is_64 = is_64,
        .endian = endian,
        .type = std.mem.toNative(u16, raw_elf_header.e_type, endian),
        .machine = std.mem.toNative(u16, raw_elf_header.e_machine, endian),
        .entry = std.mem.toNative(FileOffset, raw_elf_header.e_entry, endian),
        .program_header_offset = std.mem.toNative(FileOffset, raw_elf_header.e_phoff, endian),
        .program_header_entry_size = std.mem.toNative(u16, raw_elf_header.e_phentsize, endian),
        .program_header_entry_count = std.mem.toNative(u16, raw_elf_header.e_phnum, endian),
        .section_header_offset = std.mem.toNative(FileOffset, raw_elf_header.e_shoff, endian),
        .section_header_entry_size = std.mem.toNative(u16, raw_elf_header.e_shentsize, endian),
        .section_header_entry_count = std.mem.toNative(u16, raw_elf_header.e_shnum, endian),
        .section_name_string_table_index = std.mem.toNative(u16, raw_elf_header.e_shstrndx, endian),
    };
}

const RawElf64Header = extern struct {
    e_ident: HeaderIdent,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u64,
    e_phoff: u64,
    e_shoff: u64,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const RawElf32Header = extern struct {
    e_ident: HeaderIdent,
    e_type: u16,
    e_machine: u16,
    e_version: u32,
    e_entry: u32,
    e_phoff: u32,
    e_shoff: u32,
    e_flags: u32,
    e_ehsize: u16,
    e_phentsize: u16,
    e_phnum: u16,
    e_shentsize: u16,
    e_shnum: u16,
    e_shstrndx: u16,
};

const HeaderIdent = extern struct {
    value: [header_ident_size]u8,

    inline fn from(slice: []const u8) HeaderIdent {
        return .{ .value = slice[0..header_ident_size].* };
    }

    const MAGIC = "\x7fELF";

    fn magic(self: *const HeaderIdent) []const u8 {
        return self.value[0..4];
    }

    fn class(self: *const HeaderIdent) Class {
        return @enumFromInt(self.value[4]);
    }

    fn endian(self: *const HeaderIdent) Endian {
        return @enumFromInt(self.value[5]);
    }

    fn version(self: *const HeaderIdent) u8 {
        return self.value[6];
    }

    const Class = enum(u8) {
        none = 0,
        @"32" = 1,
        @"64" = 2,
    };

    const Endian = enum(u8) {
        none = 0,
        little = 1,
        big = 2,
    };

    const header_ident_size = 16;
};

test "parse rejects a truncated header" {
    const buf: [63]u8 = @splat(0);
    try std.testing.expectError(error.TruncatedInput, parse(&buf));
}

test "parse rejects a bad magic" {
    var buf: [64]u8 = @splat(0);
    buf[0..4].* = "\x00ELF".*;
    try std.testing.expectError(error.InvalidMagic, parse(&buf));
}

test "parse accepts a well-formed 64-bit little-endian header" {
    var buf: [64]u8 = @splat(0);
    buf[0..4].* = HeaderIdent.MAGIC.*;
    buf[4] = 2; // EI_CLASS = 64-bit
    buf[5] = 1; // EI_DATA = little-endian
    buf[6] = current_version; // EI_VERSION
    std.mem.writeInt(u16, buf[16..18], 2, .little); // e_type
    std.mem.writeInt(u16, buf[18..20], 0x3E, .little); // e_machine (x86-64)
    std.mem.writeInt(u64, buf[24..32], 0x1000, .little); // e_entry
    std.mem.writeInt(u16, buf[54..56], 56, .little); // e_phentsize
    std.mem.writeInt(u16, buf[56..58], 3, .little); // e_phnum

    const raw = try parse(&buf);
    try std.testing.expect(raw.is_64);
    try std.testing.expectEqual(std.builtin.Endian.little, raw.endian);
    try std.testing.expectEqual(@as(u16, 2), raw.type);
    try std.testing.expectEqual(@as(u16, 0x3E), raw.machine);
    try std.testing.expectEqual(@as(u64, 0x1000), raw.entry);
    try std.testing.expectEqual(@as(u16, 56), raw.program_header_entry_size);
    try std.testing.expectEqual(@as(u16, 3), raw.program_header_entry_count);
}

test "fuzz: parse never panics on arbitrary input" {
    try std.testing.fuzz({}, fuzzParse, .{});
}

fn fuzzParse(context: void, smith: *std.testing.Smith) !void {
    _ = context;

    var buf: [512]u8 = undefined;
    const len = smith.value(u9); // 0..511
    const input = buf[0..len];
    smith.bytes(input);

    _ = parse(input) catch return;
}
