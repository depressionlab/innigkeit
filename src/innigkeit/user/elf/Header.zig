const Header = @This();

const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

const RawHeader = @import("RawHeader.zig");

is_64: bool,
endian: std.builtin.Endian,

/// Object file type.
type: innigkeit.user.elf.ObjectType,

/// The required architecture.
machine: innigkeit.user.elf.Machine,

/// The virtual address to which the system first transfers control, thus starting the process.
///
/// Zero if the file has no associated entry point.
entry: innigkeit.VirtualAddress,

/// The program header tables file offset in bytes.
///
/// Zero if the file has no program header table.
program_header_offset: core.Size,

/// Size in bytes of one entry in the program header table.
program_header_entry_size: core.Size,

/// The number of entries in the program header table.
program_header_entry_count: u16,

/// The section header tables file offset in bytes.
///
/// Zero if the file has no section header table.
section_header_offset: core.Size,

/// Size in bytes of one entry in the section header table.
section_header_entry_size: core.Size,

/// The number of entries in the section header table.
section_header_entry_count: u16,

/// Section header table index of the entry associated with the section name string table.
section_name_string_table_index: u16,

pub const ParseError = RawHeader.ParseError;

/// Parse the given slice into an ELF header.
///
/// The slice must be atleast 64 bytes long.
pub fn parse(elf_header_slice: []const u8) ParseError!Header {
    const raw = try RawHeader.parse(elf_header_slice);

    return .{
        .is_64 = raw.is_64,
        .endian = raw.endian,
        .type = @enumFromInt(raw.type),
        .machine = @enumFromInt(raw.machine),
        .entry = .from(raw.entry),
        .program_header_offset = .from(raw.program_header_offset, .byte),
        .program_header_entry_size = .from(raw.program_header_entry_size, .byte),
        .program_header_entry_count = raw.program_header_entry_count,
        .section_header_offset = .from(raw.section_header_offset, .byte),
        .section_header_entry_size = .from(raw.section_header_entry_size, .byte),
        .section_header_entry_count = raw.section_header_entry_count,
        .section_name_string_table_index = raw.section_name_string_table_index,
    };
}

pub const TableLocation = struct {
    /// Byte offset of the table from the start of the file.
    offset: core.Size,
    /// Total size of the table in bytes.
    size: core.Size,
};

pub fn programHeaderTableLocation(self: *const Header) TableLocation {
    return .{
        .offset = self.program_header_offset,
        // `multiplyScalar` widens internally, so the u16*u16 product that would
        // overflow-panic on a malformed header is computed safely (it always
        // fits well within u64).
        .size = self.program_header_entry_size.multiplyScalar(self.program_header_entry_count),
    };
}

/// Iterates over the program header table and returns a `LoadableRegion` for each region that must be loaded.
///
/// The provided slice must match the location and size given by `programHeaderTableLocation`.
pub fn loadableRegionIterator(self: *const Header, program_header_table: []const u8) IterateError!innigkeit.user.elf.LoadableRegion.Iterator {
    return .{ .program_header_iterator = try self.iterateProgramHeaders(program_header_table) };
}

pub const IterateError = error{
    /// The file declares a per-entry size (`e_phentsize`) too small to hold the fields this
    /// parser reads for the file's ELF class. Trusting it would read past the entry into the
    /// next one (or past the table).
    ProgramHeaderEntryTooSmall,
    /// `program_header_table` is shorter than `program_header_entry_size * program_header_entry_count`
    /// and the caller-provided slice doesn't actually match `programHeaderTableLocation`.
    ProgramHeaderTableTruncated,
};

/// Iterates over the program header table.
///
/// The provided slice must match the location and size given by `programHeaderTableLocation`.
pub fn iterateProgramHeaders(self: *const Header, program_header_table: []const u8) IterateError!innigkeit.user.elf.ProgramHeader.Iterator {
    if (self.program_header_entry_size.value < innigkeit.user.elf.ProgramHeader.requiredEntrySize(self.is_64)) {
        return error.ProgramHeaderEntryTooSmall;
    }
    if (program_header_table.len < self.program_header_entry_size.multiplyScalar(self.program_header_entry_count).value) {
        return error.ProgramHeaderTableTruncated;
    }

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
    try writer.print("entry: 0x{x},\n", .{self.entry.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("program_header_offset: 0x{x},\n", .{self.program_header_offset.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("program_header_entry_size: 0x{x},\n", .{self.program_header_entry_size.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("program_header_entry_count: {},\n", .{self.program_header_entry_count});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("section_header_offset: 0x{x},\n", .{self.section_header_offset.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("section_header_entry_size: 0x{x},\n", .{self.section_header_entry_size.value});

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
