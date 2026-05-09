const Module = @This();

const std = @import("std");
const Error = std.debug.SelfInfoError;
const Dwarf = std.debug.Dwarf;

const native_endian = @import("builtin").target.cpu.arch.endian();

load_offset: usize,

build_id: ?[]const u8,
gnu_eh_frame: ?[]const u8,

/// `null` means unwind information has not yet been loaded.
unwind: ?(Error!UnwindSections),

/// `null` means the ELF file has not yet been loaded.
loaded_elf: ?(Error!LoadedElf),

mapped_elf: []align(std.heap.page_size_min) const u8,

const LoadedElf = struct {
    file: ElfFile,
    scanned_dwarf: bool,
};

const ElfFile = @import("ElfFile.zig");

const UnwindSections = struct {
    buf: [2]Dwarf.Unwind,
    len: usize,
};

pub const Range = struct {
    start: usize,
    len: usize,
};

/// Assumes we already have the lock.
pub fn getUnwindSections(mod: *Module, gpa: std.mem.Allocator) Error![]Dwarf.Unwind {
    if (mod.unwind == null) mod.unwind = mod.loadUnwindSections(gpa);
    const us = &(mod.unwind.? catch |err| return err);
    return us.buf[0..us.len];
}
fn loadUnwindSections(mod: *Module, gpa: std.mem.Allocator) Error!UnwindSections {
    var us: UnwindSections = .{
        .buf = undefined,
        .len = 0,
    };
    if (mod.gnu_eh_frame) |section_bytes| {
        const section_vaddr: u64 = @intFromPtr(section_bytes.ptr) - mod.load_offset;
        const header = Dwarf.Unwind.EhFrameHeader.parse(section_vaddr, section_bytes, @sizeOf(usize), native_endian) catch |err| switch (err) {
            error.ReadFailed => unreachable, // it's all fixed buffers
            error.InvalidDebugInfo => |e| return e,
            error.EndOfStream, error.Overflow => return error.InvalidDebugInfo,
            error.UnsupportedAddrSize => return error.UnsupportedDebugInfo,
        };
        us.buf[us.len] = .initEhFrameHdr(header, section_vaddr, @ptrFromInt(@as(usize, @intCast(mod.load_offset + header.eh_frame_vaddr))));
        us.len += 1;
    } else {
        // There is no `.eh_frame_hdr` section. There may still be an `.eh_frame` or `.debug_frame`
        // section, but we'll have to load the binary to get at it.
        const loaded = try mod.getLoadedElf(gpa);
        // If both are present, we can't just pick one -- the info could be split between them.
        // `.debug_frame` is likely to be the more complete section, so we'll prioritize that one.
        if (loaded.file.debug_frame) |*debug_frame| {
            us.buf[us.len] = .initSection(.debug_frame, debug_frame.vaddr, debug_frame.bytes);
            us.len += 1;
        }
        if (loaded.file.eh_frame) |*eh_frame| {
            us.buf[us.len] = .initSection(.eh_frame, eh_frame.vaddr, eh_frame.bytes);
            us.len += 1;
        }
    }
    errdefer for (us.buf[0..us.len]) |*u| u.deinit(gpa);
    for (us.buf[0..us.len]) |*u| u.prepare(gpa, @sizeOf(usize), native_endian, true, false) catch |err| switch (err) {
        error.ReadFailed => unreachable, // it's all fixed buffers
        error.InvalidDebugInfo,
        error.MissingDebugInfo,
        error.OutOfMemory,
        => |e| return e,
        error.EndOfStream,
        error.Overflow,
        error.StreamTooLong,
        error.InvalidOperand,
        error.InvalidOpcode,
        error.InvalidOperation,
        => return error.InvalidDebugInfo,
        error.UnsupportedAddrSize,
        error.UnsupportedDwarfVersion,
        error.UnimplementedUserOpcode,
        => return error.UnsupportedDebugInfo,
    };
    return us;
}

/// Assumes we already have the lock.
pub fn getLoadedElf(mod: *Module, gpa: std.mem.Allocator) Error!*LoadedElf {
    if (mod.loaded_elf == null) mod.loaded_elf = loadElf(mod, gpa);
    return if (mod.loaded_elf.?) |*elf| elf else |err| err;
}

fn loadElf(mod: *Module, gpa: std.mem.Allocator) Error!LoadedElf {
    const load_result = ElfFile.load(gpa, mod.mapped_elf);

    var elf_file = load_result catch |err| switch (err) {
        error.OutOfMemory,
        error.Unexpected,
        error.Canceled,
        => |e| return e,

        error.Overflow,
        error.TruncatedElfFile,
        error.InvalidCompressedSection,
        error.InvalidElfMagic,
        error.InvalidElfVersion,
        error.InvalidElfClass,
        error.InvalidElfEndian,
        => return error.InvalidDebugInfo,

        error.SystemResources,
        error.MemoryMappingNotSupported,
        error.AccessDenied,
        error.LockedMemoryLimitExceeded,
        error.ProcessFdQuotaExceeded,
        error.SystemFdQuotaExceeded,
        error.Streaming,
        => return error.ReadFailed,
    };
    errdefer elf_file.deinit(gpa);

    if (elf_file.endian != native_endian) return error.InvalidDebugInfo;
    if (elf_file.is_64 != (@sizeOf(usize) == 8)) return error.InvalidDebugInfo;

    return .{
        .file = elf_file,
        .scanned_dwarf = false,
    };
}
