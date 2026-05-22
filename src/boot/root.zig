const architecture = @import("architecture");
const innigkeit = @import("innigkeit");
const limine = @import("limine/interface.zig");

pub const MemoryMap = @import("MemoryMap.zig").MemoryMap;
pub const Framebuffer = @import("Framebuffer.zig");
pub const UsableRangeIterator = @import("UsableRangeIterator.zig");
pub const Address = @import("Address.zig").Address;
pub const CpuDescriptors = @import("CpuDescriptors.zig").CpuDescriptors;
pub const KernelBaseAddress = @import("KernelBaseAddress.zig");

/// Returns the kernel virtual and physical base addresses provided by the bootloader, if any.
pub fn kernelBaseAddress() ?KernelBaseAddress {
    return switch (bootloader_api) {
        .limine => limine.kernelBaseAddress(),
        .unknown => null,
    };
}

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

/// Returns the direct map address provided by the bootloader, if any.
pub fn directMapAddress() ?innigkeit.KernelVirtualAddress {
    return switch (bootloader_api) {
        .limine => limine.directMapAddress(),
        .unknown => null,
    };
}

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
