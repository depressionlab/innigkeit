//! Shared ELF-load-and-jump sequence. Each caller makes its own trust
//! decision *before* calling this.
//!
//! This function performs only the mechanical
//! `map -> copy -> protect -> AT_PHDR -> startProcess` sequence and does not
//! itself make or change either trust decision.

const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.elf_loader);
const validate = @import("../validate.zig");

/// `thread` must be the currently-executing thread: `startProcess` asserts
/// `current_task.task == &thread.task`, and the copy step below opens a
/// user-access window on the current task.
///
/// `proc_init` ownership transfers to `thread.startProcess` on success (it
/// frees the buffer before entering userspace); on error it is left to the
/// caller to free, matching `startProcess`'s own contract.
pub fn loadAndJump(thread: *innigkeit.user.Thread, elf_data: []const u8, proc_init: []const u8) !noreturn {
    const address_space = &thread.process.address_space;

    const header = try innigkeit.user.elf.Header.parse(elf_data);

    const entry_point = switch (header.entry.tagged()) {
        .user => |user| user,
        else => return error.InvalidEntryPoint,
    };

    const program_header_table: []const u8 = phdr: {
        const loc = header.programHeaderTableLocation();
        if (loc.offset.value > elf_data.len or loc.size.value > elf_data.len - loc.offset.value) {
            log.err("ELF program header table [{x}, +{x}) out of file bounds ({x})", .{
                loc.offset.value, loc.size.value, elf_data.len,
            });
            return error.ProgramHeaderTableOutOfBounds;
        }
        break :phdr elf_data[loc.offset.value..][0..loc.size.value];
    };

    // Map all loadable segments rw for initial population.
    {
        var iter = try header.loadableRegionIterator(program_header_table);
        while (try iter.next()) |region| {
            _ = try address_space.map(.{
                .base = region.virtual_range.address.toVirtualAddress(),
                .size = region.virtual_range.size,
                .protection = .{ .read = true, .write = true },
                .max_protection = .all,
                .type = .zero_fill,
            });
        }
    }

    // Copy ELF segment data into the destination ranges the kernel just
    // mapped into this (child) address space. `byteSlice()` requires a
    // `UserAccess` window to already be open (it asserts this), so the
    // window is held for the whole loop as before; `safe.memcpy` (not a raw
    // `@memcpy`) is still what actually performs each copy, turning an
    // unhandleable fault into `error.BadAddress` instead of a kernel panic.
    // Defense in depth: the destination is trusted, kernel-computed memory
    // (not attacker-controlled input), so a fault here would only ever
    // indicate an actual kernel mapping bug, but there's no reason to let
    // that class of bug panic when the fault-safe primitive already exists.
    {
        const access: validate.UserAccess = .acquire();
        defer access.release();

        var iter = try header.loadableRegionIterator(program_header_table);
        while (try iter.next()) |region| {
            if (region.source_length == 0) continue;
            // Bounds-check the source range against the ELF file before slicing.
            if (region.source_base >= elf_data.len or
                region.source_length > elf_data.len - region.source_base)
            {
                log.err("ELF segment [{x}, +{x}) out of file bounds ({x})", .{
                    region.source_base, region.source_length, elf_data.len,
                });
                return error.ElfSegmentOutOfBounds;
            }
            const dst = region.virtual_range.byteSlice()[region.destination_offset..];
            const src = elf_data[region.source_base..];
            try innigkeit.memory.safe.memcpy(.{
                .destination = .from(.from(@intFromPtr(dst.ptr)), .from(region.source_length, .byte)),
                .source = .from(.from(@intFromPtr(src.ptr)), .from(region.source_length, .byte)),
            });
        }
    }

    // Apply per-segment protections.
    {
        var iter = try header.loadableRegionIterator(program_header_table);
        while (try iter.next()) |region| {
            try address_space.changeProtection(
                region.virtual_range.toVirtualRange(),
                .{ .both = .{
                    .protection = region.protection,
                    .max_protection = region.protection,
                } },
            );
        }
    }

    // Compute AT_PHDR: find the PT_LOAD segment that covers e_phoff, then
    // adjust by the segment's file-to-virtual offset.
    const phdr_vaddr: usize = blk: {
        var iter = try header.iterateProgramHeaders(program_header_table);
        while (iter.next()) |phdr| {
            if (phdr.type != .load) continue;
            if (phdr.offset.value <= header.program_header_offset.value and
                header.program_header_offset.value < phdr.offset.value + phdr.file_size.value)
            {
                break :blk @intCast(phdr.virtual_address.value +
                    (header.program_header_offset.value - phdr.offset.value));
            }
        }
        break :blk 0; // phdrs not covered by any PT_LOAD; PIE relocation unavailable
    };

    try thread.startProcess(entry_point, .{
        .phdr_vaddr = phdr_vaddr,
        .phnum = header.program_header_entry_count,
        .entry = header.entry.value,
        .proc_init = proc_init,
    });
    unreachable;
}
