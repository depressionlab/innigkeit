const ProgramHeader = @import("ProgramHeader.zig");

const core = @import("core");
const innigkeit = @import("innigkeit");
const std = @import("std");

/// What kind of segment this describes or how to interpret the information.
type: Type,

flags: Flags,

/// The offset from the beginning of the file at which the first byte of the segment resides.
offset: core.Size,

/// The number of bytes in the file image of the segment; it may be zero.
file_size: core.Size,

/// The virtual address at which the first byte of the segment resides in memory.
virtual_address: innigkeit.VirtualAddress,

/// On systems for which physical addressing is relevant, this member is reserved for the segment’s physical address.
///
/// Because System V ignores physical addressing for application programs, this member has unspecified contents for
/// executable files and shared objects.
physical_address: u64,

/// The number of bytes in the memory image of the segment; it may be zero.
memory_size: core.Size,

/// Loadable process segments must have congruent values for `virtual_address` and `offset`, modulo the page size.
///
/// This member gives the value to which the segments are aligned in memory and in the file.
///
/// Values 0 and 1 mean no alignment is required.
///
/// Otherwise, `alignment` should be a positive, integral power of 2, and `virtual_address` should equal `offset`
/// modulo `alignment`.
alignment: u64,

/// The minimum `program_header_entry_size` this parser can read: the native raw struct size for
/// the given ELF class. A file whose `e_phentsize` is smaller than this cannot actually hold one
/// of the fields `Iterator.next` reads, and must be rejected before iterating rather than trusted.
pub fn requiredEntrySize(is_64: bool) u64 {
    return if (is_64)
        @sizeOf(RawElf64ProgramHeader)
    else
        @sizeOf(RawElf32ProgramHeader);
}

pub const Iterator = struct {
    header: *const innigkeit.user.elf.Header,
    index: usize = 0,
    program_header_table: []const u8,

    pub fn next(it: *Iterator) ?ProgramHeader {
        const index = it.index;
        const header = it.header;
        if (index >= header.program_header_entry_count) return null;
        defer it.index += 1;

        var reader: std.Io.Reader = .fixed(it.program_header_table[header.program_header_entry_size.multiplyScalar(index).value..]);

        if (header.is_64) {
            const raw_header = reader.takeStruct(
                RawElf64ProgramHeader,
                header.endian,
            ) catch unreachable; // `iterateProgramHeaders` ensures the slice is long enough

            return .{
                .type = @enumFromInt(raw_header.p_type),
                .flags = @bitCast(raw_header.p_flags),
                .offset = .from(raw_header.p_offset, .byte),
                .virtual_address = .from(raw_header.p_vaddr),
                .physical_address = raw_header.p_paddr,
                .file_size = .from(raw_header.p_filesz, .byte),
                .memory_size = .from(raw_header.p_memsz, .byte),
                .alignment = raw_header.p_align,
            };
        } else {
            const raw_header = reader.takeStruct(
                RawElf32ProgramHeader,
                header.endian,
            ) catch unreachable; // `iterateProgramHeaders` ensures the slice is long enough

            return .{
                .type = @enumFromInt(raw_header.p_type),
                .flags = @bitCast(raw_header.p_flags),
                .offset = .from(raw_header.p_offset, .byte),
                .virtual_address = .from(raw_header.p_vaddr),
                .physical_address = raw_header.p_paddr,
                .file_size = .from(raw_header.p_filesz, .byte),
                .memory_size = .from(raw_header.p_memsz, .byte),
                .alignment = raw_header.p_align,
            };
        }
    }
};

pub const Type = enum(u32) {
    /// The array element is unused; other members values are undefined.
    ///
    /// This type lets the program header table have ignored entries.
    null = 0,

    /// The array element specifies a loadable segment, described by `file_size` and `mem_size`.
    ///
    /// The bytes from the file are mapped to the beginning of the memory segment.
    ///
    /// If the segment’s memory size (`mem_size`) is larger than the file size (`file_size`), the "extra" bytes are
    /// defined to hold the value 0 and to follow the segment's initialized area.
    ///
    /// The file size may not be larger than the memory size.
    ///
    /// Loadable segment entries in the program header table appear in ascending order, sorted on the
    /// `virtual_address` member.
    load = 1,

    /// The array element specifies dynamic linking information.
    dynamic = 2,

    /// The array element specifies the location and size of a null-terminated path name to invoke as an interpreter.
    ///
    /// This segment type is meaningful only for executable files (though it may occur for shared objects); it may
    /// not occur more than once in a file.
    ///
    /// If it is present, it must precede any loadable segment entry.
    interpreter = 3,

    /// The array element specifies the location and size of auxiliary information.
    note = 4,

    /// This segment type is reserved but has unspecified semantics.
    ///
    /// Programs that contain an array element of this type do not conform to the ABI.
    shlib = 5,

    /// The array element, if present, specifies the location and size of the program header table itself, both in
    /// the file and in the memory image of the program.
    ///
    /// This segment type may not occur more than once in a file. Moreover, it may occur only if the program header
    /// table is part of the memory image of the program.
    ///
    /// If it is present, it must precede any loadable segment entry.
    phdr = 6,

    /// The array element specifies the Thread-Local Storage template.
    ///
    /// Implementations need not support this program table entry.
    tls = 7,

    /// .eh_frame_hdr segment
    gnu_eh_frame = 0x6474E550,

    _,

    /// Beginning of OS-specific types
    pub const LOOS = 0x60000000;

    /// End of OS-specific types
    pub const HIOS = 0x6FFFFFFF;

    /// Beginning of processor-specific types
    pub const LOPROC = 0x70000000;

    /// End of processor-specific types
    pub const HIPROC = 0x7FFFFFFF;
};

pub const Flags = packed struct(u32) {
    execute: bool,
    write: bool,
    read: bool,

    _reserved: u29,

    /// All bits included in the `MASKOS` mask are reserved for operating system-specific semantics.
    pub const MASKOS: u32 = 0x0FF00000;

    /// All bits included in the `MASKPROC` mask are reserved for processor-specific semantics.
    ///
    /// If meanings are specified, the psABI supplement explains them.
    pub const MASKPROC: u32 = 0xF0000000;

    pub fn print(self: *const Flags, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("Flags{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("execute: {},\n", .{self.execute});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("write: {},\n", .{self.write});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("read: {},\n", .{self.read});

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub fn format(self: *const Flags, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }
};

pub fn print(self: *const ProgramHeader, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    try writer.writeAll("ProgramHeader{\n");

    try writer.splatByteAll(' ', new_indent);
    switch (self.type) {
        _ => |value| try writer.print("type: 0x{x},\n", .{value}),
        else => |tag| try writer.print("type: {t},\n", .{tag}),
    }

    try writer.splatByteAll(' ', new_indent);
    try writer.print("flags: ", .{});
    try self.flags.print(writer, new_indent);
    try writer.writeAll(",\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("offset: 0x{x},\n", .{self.offset.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("file_size: 0x{x},\n", .{self.file_size.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("virtual_address: 0x{x},\n", .{self.virtual_address.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("physical_address: 0x{x},\n", .{self.physical_address});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("memory_size: 0x{x},\n", .{self.memory_size.value});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("alignment: 0x{x},\n", .{self.alignment});

    try writer.splatByteAll(' ', indent);
    try writer.writeByte('}');
}

pub fn format(self: *const ProgramHeader, writer: *std.Io.Writer) !void {
    return self.print(writer, 0);
}

const RawElf32ProgramHeader = extern struct {
    p_type: u32,
    p_offset: u32,
    p_vaddr: u32,
    p_paddr: u32,
    p_filesz: u32,
    p_memsz: u32,
    p_flags: u32,
    p_align: u32,
};

const RawElf64ProgramHeader = extern struct {
    p_type: u32,
    p_flags: u32,
    p_offset: u64,
    p_vaddr: u64,
    p_paddr: u64,
    p_filesz: u64,
    p_memsz: u64,
    p_align: u64,
};
