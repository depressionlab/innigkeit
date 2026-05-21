const LoadableRegion = @This();

const std = @import("std");
const architecture = @import("architecture");
const core = @import("core");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.user);

/// The virtual range to allocate in the address space.
///
/// Page aligned.
virtual_range: innigkeit.UserVirtualRange,

/// The protection to use for the mapping.
protection: innigkeit.mem.MapType.Protection,

/// The offset into the source data to copy from.
source_base: usize,

/// The number of bytes to copy from the source data.
///
/// May be zero.
source_length: usize,

/// The offset into the virtual range to copy the data to.
destination_offset: usize,

pub const Iterator = struct {
    program_header_iterator: innigkeit.user.elf.ProgramHeader.Iterator,

    pub fn next(it: *Iterator) !?LoadableRegion {
        while (it.program_header_iterator.next()) |program_header| {
            if (program_header.type != .load) continue;
            if (program_header.memory_size == 0) continue; // can this even happen with a loadable segment?

            if (program_header.file_size > program_header.memory_size) {
                log.warn("PT_LOAD segment has file_size > memory_size: {f}", .{program_header});
                return error.ProgramHeaderInvalidSize;
            }

            const address, const offset_due_to_alignment = blk: {
                const unaligned_address: innigkeit.VirtualAddress = .from(program_header.virtual_address);
                const aligned_address = unaligned_address.pageAlignBackward();
                break :blk .{ aligned_address, aligned_address.difference(unaligned_address) };
            };

            const range_size: core.Size = offset_due_to_alignment
                .add(.from(program_header.memory_size, .byte))
                .alignForward(architecture.paging.standard_page_size_alignment);

            const virtual_range: innigkeit.VirtualRange = .from(address, range_size);
            if (core.is_debug) std.debug.assert(virtual_range.pageAligned());

            if (virtual_range.getType() != .user) {
                log.warn("program header has invalid user virtual address range: {f}", .{program_header});
                return error.ProgramHeaderInvalidVirtualAddress;
            }

            const new_protection = blk: {
                var prot: innigkeit.mem.MapType.Protection = .{};

                if (program_header.flags.read) prot.read = true;
                if (program_header.flags.execute) prot.execute = true;
                if (program_header.flags.write) prot.write = true;

                if (prot.equal(.none)) {
                    log.warn("no protection flags set in program header", .{});
                    return error.ProgramHeaderInvalidProtection;
                }

                if (prot.write and prot.execute) {
                    log.warn("PT_LOAD segment is writable+executable (W^X violation): {f}", .{program_header});
                    return error.ProgramHeaderWritableExecutable;
                }

                break :blk prot;
            };

            return .{
                .virtual_range = virtual_range.toUser(),
                .destination_offset = offset_due_to_alignment.value,
                .source_base = program_header.offset,
                .source_length = program_header.file_size,
                .protection = new_protection,
            };
        }

        return null;
    }
};

pub fn print(self: LoadableRegion, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    try writer.writeAll("LoadableRegion{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("virtual_range: {f},\n", .{self.virtual_range});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("protection: {t},\n", .{self.protection});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("source_base: 0x{x},\n", .{self.source_base});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("source_length: 0x{x},\n", .{self.source_length});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("destination_offset: 0x{x},\n", .{self.destination_offset});

    try writer.splatByteAll(' ', indent);
    try writer.writeByte('}');
}

pub fn format(self: LoadableRegion, writer: *std.Io.Writer) !void {
    return self.print(writer, 0);
}
