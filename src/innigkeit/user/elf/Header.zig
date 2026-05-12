const Header = @This();

const std = @import("std");
const builtin = @import("builtin");

const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");

const log = innigkeit.debug.log.scoped(.user);

is_64: bool,
endian: std.builtin.Endian,

/// Object file type.
type: innigkeit.user.elf.ObjectType,

/// The required architecture.
machine: innigkeit.user.elf.Machine,

/// The virtual address to which the system first transfers control, thus starting the process.
///
/// Zero if the file has no associated entry point.
entry: u64,

/// The program header tables file offset in bytes.
///
/// Zero if the file has no program header table.
program_header_offset: u64,

/// Size in bytes of one entry in the program header table.
program_header_entry_size: u16,

/// The number of entries in the program header table.
program_header_entry_count: u16,

/// The section header tables file offset in bytes.
///
/// Zero if the file has no section header table.
section_header_offset: u64,

/// Size in bytes of one entry in the section header table.
section_header_entry_size: u16,

/// The number of entries in the section header table.
section_header_entry_count: u16,

/// Section header table index of the entry associated with the section name string table.
section_name_string_table_index: u16,

pub const ParseError = error{
    InvalidMagic,
    InvalidVersion,
    InvalidEndian,
    InvalidClass,
};

/// Parse the given slice into an ELF header.
///
/// The slice must be atleast 64 bytes long.
pub fn parse(elf_header_slice: []const u8) ParseError!Header {
    if (builtin.mode == .Debug) std.debug.assert(elf_header_slice.len >= 64);

    const ident: HeaderIdent = .from(elf_header_slice);
    if (!std.mem.eql(u8, ident.magic(), HeaderIdent.MAGIC)) return error.InvalidMagic;
    if (ident.version() != .current) return error.InvalidVersion;

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

fn innerParse(elf_header_slice: []const u8, comptime is_64: bool, endian: std.builtin.Endian) ParseError!Header {
    const HeaderT = if (is_64) RawElf64Header else RawElf32Header;
    const FileOffset = if (is_64) u64 else u32;
    const raw_elf_header: *align(1) const HeaderT = std.mem.bytesAsValue(HeaderT, elf_header_slice);

    return .{
        .is_64 = is_64,
        .endian = endian,
        .type = @enumFromInt(std.mem.toNative(u16, raw_elf_header.e_type, endian)),
        .machine = @enumFromInt(std.mem.toNative(u16, raw_elf_header.e_machine, endian)),
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

pub const TableLocation = struct {
    base: u64,
    length: u32, // as number and size of entries are both u16 the length cannot be larger than u32
};

pub fn programHeaderTableLocation(self: *const Header) TableLocation {
    return .{
        .base = self.program_header_offset,
        .length = self.program_header_entry_count * self.program_header_entry_size,
    };
}

/// Iterates over the program header table and returns a `LoadableRegion` for each region that must be loaded.
///
/// The provided slice must match the location and size given by `programHeaderTableLocation`.
pub fn loadableRegionIterator(self: *const Header, program_header_table: []const u8) innigkeit.user.elf.LoadableRegion.Iterator {
    return .{
        .program_header_iterator = self.iterateProgramHeaders(program_header_table),
    };
}

/// Iterates over the program header table.
///
/// The provided slice must match the location and size given by `programHeaderTableLocation`.
pub fn iterateProgramHeaders(self: *const Header, program_header_table: []const u8) innigkeit.user.elf.ProgramHeader.Iterator {
    if (builtin.mode == .Debug) std.debug.assert(
        program_header_table.len >= self.program_header_entry_count * self.program_header_entry_size,
    );

    return .{
        .header = self,
        .program_header_table = program_header_table,
    };
}

pub fn print(self: *const Header, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    try writer.writeAll("Header{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("is_64: {},\n", .{self.is_64});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("endian: {t},\n", .{self.endian});

    try writer.splatByteAll(' ', new_indent);
    switch (self.type) {
        _ => |value| try writer.print("type: 0x{x},\n", .{value}),
        else => |tag| try writer.print("type: {t},\n", .{tag}),
    }

    try writer.splatByteAll(' ', new_indent);
    switch (self.machine) {
        _ => |value| try writer.print("machine: 0x{x},\n", .{value}),
        else => |tag| try writer.print("machine: {t},\n", .{tag}),
    }

    try writer.splatByteAll(' ', new_indent);
    try writer.print("entry: 0x{x},\n", .{self.entry});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("program_header_offset: 0x{x},\n", .{self.program_header_offset});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("program_header_entry_size: 0x{x},\n", .{self.program_header_entry_size});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("program_header_entry_count: {},\n", .{self.program_header_entry_count});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("section_header_offset: 0x{x},\n", .{self.section_header_offset});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("section_header_entry_size: 0x{x},\n", .{self.section_header_entry_size});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("section_header_entry_count: {},\n", .{self.section_header_entry_count});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("section_name_string_table_index: {},\n", .{self.section_name_string_table_index});

    try writer.splatByteAll(' ', indent);
    try writer.writeByte('}');
}

pub fn format(self: *const Header, writer: *std.Io.Writer) !void {
    return self.print(writer, 0);
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

    fn version(self: *const HeaderIdent) innigkeit.user.elf.Version {
        return @enumFromInt(self.value[6]);
    }

    fn osABI(self: *const HeaderIdent) innigkeit.user.elf.OSABI {
        return @enumFromInt(self.value[7]);
    }

    fn abiVersion(self: *const HeaderIdent) u8 {
        return self.value[8];
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
