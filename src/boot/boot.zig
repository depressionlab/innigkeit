const std = @import("std");
const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const core = @import("core");
const limine = @import("limine/interface.zig");

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() ?KernelBaseAddress {
    return switch (bootloader_api) {
        .limine => limine.kernelBaseAddress(),
        .unknown => null,
    };
}

pub const KernelBaseAddress = struct {
    virtual: innigkeit.KernelVirtualAddress,
    physical: innigkeit.PhysicalAddress,
};

/// Returns the kernel's ELF executable file provided by the bootloader, if any.
pub fn kernelExecutableFile() ?[]align(architecture.paging.standard_page_size_alignment.toByteUnits()) const u8 {
    return switch (bootloader_api) {
        .limine => limine.kernelExecutableFile(),
        .unknown => null,
    };
}

/// Returns an iterator over the memory map entries.
pub fn memoryMap() error{NoMemoryMap}!MemoryMap {
    return switch (bootloader_api) {
        .limine => limine.memoryMap(),
        .unknown => error.NoMemoryMap,
    };
}

pub const MemoryMap = union {
    unknown: void,
    limine: limine.MemoryMapIterator,

    pub fn next(memory_map: *MemoryMap) ?Entry {
        return switch (bootloader_api) {
            .limine => memory_map.limine.next(),
            .unknown => null,
        };
    }

    /// An entry in the memory map provided by the bootloader.
    pub const Entry = struct {
        range: innigkeit.PhysicalRange,
        type: Type,

        pub const Type = enum {
            free,
            in_use,
            reserved,
            bootloader_reclaimable,
            acpi_reclaimable,
            acpi_nvs,
            framebuffer,
            reserved_mapped,

            unusable,
            unknown,

            pub fn isUsableForAllocation(entry_type: Type) bool {
                return switch (entry_type) {
                    .free, .in_use, .bootloader_reclaimable, .acpi_reclaimable => true,
                    .framebuffer, .acpi_nvs, .reserved, .unusable, .unknown, .reserved_mapped => false,
                };
            }
        };

        pub inline fn format(
            entry: Entry,
            writer: *std.Io.Writer,
        ) !void {
            try writer.print("{t} - {f}", .{ entry.type, entry.range });
        }
    };
};

/// Iterate over the ranges of physical memory that are usable for allocation.
///
/// Includes all memory map entries that return true for `MemoryMap.Entry.type.isUsableForAllocation`.
///
/// Contiguous ranges are merged together.
///
/// Ensures the ranges are aligned to the standard page size.
pub fn usableRangeIterator() error{NoMemoryMap}!UsableRangeIterator {
    return .{ .memory_map = try memoryMap() };
}

pub const UsableRangeIterator = struct {
    memory_map: MemoryMap,

    opt_current_range: ?innigkeit.PhysicalRange = null,

    pub fn next(iter: *UsableRangeIterator) ?innigkeit.PhysicalRange {
        while (true) {
            const opt_entry_range: ?innigkeit.PhysicalRange = while (iter.memory_map.next()) |entry| {
                if (entry.type.isUsableForAllocation()) break entry.range;
            } else null;

            const entry_range = (opt_entry_range orelse {
                const current_range = iter.opt_current_range;
                iter.opt_current_range = null;
                return current_range;
            }).pageAlign();

            const current_range = iter.opt_current_range orelse {
                iter.opt_current_range = entry_range;
                continue;
            };

            if (current_range.after().equal(entry_range.address)) {
                iter.opt_current_range.?.size.addInPlace(entry_range.size);
                continue;
            }

            iter.opt_current_range = entry_range;

            return current_range;
        }
    }
};

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() ?innigkeit.KernelVirtualAddress {
    return switch (bootloader_api) {
        .limine => limine.directMapAddress(),
        .unknown => null,
    };
}

pub const Address = union(enum) {
    physical: innigkeit.PhysicalAddress,
    virtual: innigkeit.KernelVirtualAddress,

    pub const Raw = extern union {
        physical: innigkeit.PhysicalAddress,
        virtual: innigkeit.KernelVirtualAddress,
    };
};

/// Returns the ACPI RSDP address provided by the bootloader, if any.
pub fn rsdp() ?Address {
    return switch (bootloader_api) {
        .limine => limine.rsdp(),
        .unknown => null,
    };
}

pub fn x2apicEnabled() bool {
    if (architecture.current_arch != .x64) {
        @compileError("x2apicEnabled can only be called on x64");
    }

    return switch (bootloader_api) {
        .limine => limine.x2apicEnabled(),
        .unknown => return false,
    };
}

pub fn bootstrapArchitectureProcessorId() u64 {
    return switch (bootloader_api) {
        .limine => limine.bootstrapArchitectureProcessorId(),
        .unknown => unreachable,
    };
}

pub fn cpuDescriptors() ?CpuDescriptors {
    return switch (bootloader_api) {
        .limine => limine.cpuDescriptors(),
        .unknown => null,
    };
}

pub const CpuDescriptors = union {
    unknown: void,
    limine: limine.CpuDescriptorIterator,

    pub fn count(cpu_descriptors: *const CpuDescriptors) usize {
        return switch (bootloader_api) {
            .limine => cpu_descriptors.limine.count(),
            .unknown => 0,
        };
    }

    /// Returns the next cpu descriptor from the iterator, if any remain.
    pub fn next(cpu_descriptors: *CpuDescriptors) ?Descriptor {
        return switch (bootloader_api) {
            .limine => cpu_descriptors.limine.next(),
            .unknown => null,
        };
    }

    pub const Descriptor = union {
        unknown: void,
        limine: limine.CpuDescriptorIterator.Descriptor,

        pub fn boot(
            descriptor: *const Descriptor,
            user_data: *anyopaque,
            target_fn: fn (user_data: *anyopaque) anyerror!noreturn,
        ) void {
            switch (bootloader_api) {
                .limine => descriptor.limine.bootFn(user_data, target_fn),
                .unknown => unreachable,
            }
        }

        pub fn acpiProcessorId(descriptor: *const Descriptor) u32 {
            return switch (bootloader_api) {
                .limine => descriptor.limine.acpiProcessorId(),
                .unknown => unreachable,
            };
        }

        pub fn architectureProcessorId(descriptor: *const Descriptor) u64 {
            return switch (bootloader_api) {
                .limine => descriptor.limine.architectureProcessorId(),
                .unknown => unreachable,
            };
        }
    };
};

/// Each pixel of the framebuffer is a 32-bit RGB value.
pub const Framebuffer = struct {
    ptr: [*]volatile u32,
    /// Width of the framebuffer in pixels
    width: u64,
    /// Height of the framebuffer in pixels
    height: u64,
    /// Pitch in bytes
    pitch: u64,

    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
};

/// Returns the framebuffer provided by the bootloader, if any.
pub fn framebuffer() ?Framebuffer {
    return switch (bootloader_api) {
        .limine => limine.framebuffer(),
        .unknown => null,
    };
}

/// Returns the device tree blob provided by the bootloader, if any.
pub fn deviceTreeBlob() ?innigkeit.KernelVirtualAddress {
    return switch (bootloader_api) {
        .limine => limine.deviceTreeBlob(),
        .unknown => null,
    };
}

/// Exports bootloader entry points and any other required exported symbols.
pub fn exportEntryPoints() void {
    const unknownBootloaderEntryPoint = struct {
        /// The entry point that is exported as `_start` and acts as fallback entry point for unknown bootloaders.
        ///
        /// No bootloader is ever expected to call `_start` and instead should use bootloader specific entry points;
        /// meaning this function is not expected to ever be called.
        pub fn unknownBootloaderEntryPoint() callconv(.naked) noreturn {
            asm volatile (architecture.scheduling.cfi_prevent_unwinding);
            @call(.always_inline, architecture.interrupts.disableAndHalt, .{});
            unreachable;
        }
    }.unknownBootloaderEntryPoint;

    comptime {
        @export(&unknownBootloaderEntryPoint, .{ .name = "_start" });
        limine.exportRequests();
    }
}

pub var bootloader_api: BootloaderAPI = .unknown;

pub const BootloaderAPI = enum {
    unknown,
    limine,
};
