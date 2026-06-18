const std = @import("std");
const architecture = @import("architecture");
const boot = @import("boot");
const innigkeit = @import("innigkeit");
const root = @import("root.zig");

pub fn kernelBaseAddress() ?boot.KernelBaseAddress {
    const resp = requests.kernel_address.response orelse
        return null;

    return .{
        .virtual = resp.virtual_base,
        .physical = resp.physical_base,
    };
}

pub fn kernelExecutableFile() ?[]align(architecture.paging.standard_page_size_alignment.toByteUnits()) const u8 {
    const resp = requests.executable_file.response orelse return &.{};
    return @alignCast(resp.executable_file.getContents());
}

pub fn memoryMap() error{NoMemoryMap}!boot.MemoryMap {
    const resp = requests.memory_map.response orelse return error.NoMemoryMap;
    return .{ .limine = .{ .entries = resp.entries() } };
}

pub const MemoryMapIterator = struct {
    index: usize = 0,
    entries: []const *const root.MemoryMap.Entry,

    pub fn next(memory_map_iterator: *MemoryMapIterator) ?boot.MemoryMap.Entry {
        const limine_entry = blk: {
            if (memory_map_iterator.index >= memory_map_iterator.entries.len) return null;
            const entry = memory_map_iterator.entries[memory_map_iterator.index];
            memory_map_iterator.index += 1;
            break :blk entry;
        };

        return .{
            .range = .from(limine_entry.base, limine_entry.length),
            .type = switch (limine_entry.type) {
                .usable => .free,
                .executable_and_modules => .in_use,
                .reserved => .reserved,
                .acpi_nvs => .acpi_nvs,
                .bootloader_reclaimable => .bootloader_reclaimable,
                .acpi_reclaimable => .acpi_reclaimable,
                .reserved_mapped => .reserved_mapped,
                .framebuffer => .framebuffer,
                .bad_memory => .unusable,
                _ => .unknown,
            },
        };
    }
};

pub fn directMapAddress() ?innigkeit.KernelVirtualAddress {
    const resp = requests.hhdm.response orelse return null;

    return resp.address;
}

pub fn rsdp() ?boot.Address {
    const resp = requests.rsdp.response orelse return null;

    return resp.address(limine_revison);
}

pub fn x2apicEnabled() bool {
    std.debug.assert(architecture.current_arch == .x64);

    const resp: *const root.MP.x86_64 = requests.smp.response orelse return false;

    return resp.flags.x2apic_enabled;
}

pub fn bootstrapArchitectureProcessorId() u64 {
    const resp = requests.smp.response orelse return 0;

    return switch (architecture.current_arch) {
        .arm => resp.bsp_mpidr,
        .riscv => resp.bsp_hartid,
        .x64 => resp.bsp_lapic_id,
    };
}

pub fn cpuDescriptors() ?boot.CpuDescriptors {
    const resp = requests.smp.response orelse
        return null;

    return .{
        .limine = .{ .index = 0, .entries = resp.cpus() },
    };
}

pub const CpuDescriptorIterator = struct {
    index: usize,
    entries: []*root.MP.Response.MPInfo,

    pub fn count(descriptor_iterator: *const CpuDescriptorIterator) usize {
        return descriptor_iterator.entries.len;
    }

    pub fn next(descriptor_iterator: *CpuDescriptorIterator) ?boot.CpuDescriptors.Descriptor {
        if (descriptor_iterator.index >= descriptor_iterator.entries.len) return null;

        const smp_info = descriptor_iterator.entries[descriptor_iterator.index];

        descriptor_iterator.index += 1;

        return .{ .limine = .{ .smp_info = smp_info } };
    }

    pub const Descriptor = struct {
        smp_info: *root.MP.Response.MPInfo,

        pub fn bootFn(
            descriptor: *const Descriptor,
            user_data: *anyopaque,
            comptime targetFn: fn (user_data: *anyopaque) anyerror!noreturn,
        ) void {
            const trampolineFn = struct {
                fn trampolineFn(smp_info: *const root.MP.Response.MPInfo) callconv(.c) noreturn {
                    targetFn(@ptrFromInt(smp_info.extra_argument)) catch |err| {
                        std.debug.panic("unhandled error: {t}!", .{err});
                    };
                }
            }.trampolineFn;

            const smp_info = descriptor.smp_info;

            @atomicStore(
                usize,
                &smp_info.extra_argument,
                @intFromPtr(user_data),
                .release,
            );

            @atomicStore(
                ?*const fn (*const root.MP.Response.MPInfo) callconv(.c) noreturn,
                &smp_info.goto_address,
                &trampolineFn,
                .release,
            );
        }

        pub fn acpiProcessorId(
            descriptor: *const Descriptor,
        ) u32 {
            return descriptor.smp_info.processor_id;
        }

        pub fn architectureProcessorId(
            descriptor: *const Descriptor,
        ) u64 {
            return switch (architecture.current_arch) {
                .arm => descriptor.smp_info.mpidr,
                .riscv => descriptor.smp_info.hartid,
                .x64 => descriptor.smp_info.lapic_id,
            };
        }
    };
};

pub fn framebuffer() ?boot.Framebuffer {
    const buffer = blk: {
        const resp = requests.framebuffer.response orelse return null;

        const framebuffers = resp.framebuffers();
        if (framebuffers.len == 0) return null;

        break :blk framebuffers[0];
    };

    std.debug.assert(buffer.bpp == 32);
    std.debug.assert(buffer.memory_model == .rgb);

    return .{
        .ptr = buffer.address.toPtr([*]volatile u32),
        .width = buffer.width,
        .height = buffer.height,
        .pitch = buffer.pitch,
        .red_mask_size = buffer.red_mask_size,
        .red_mask_shift = buffer.red_mask_shift,
        .green_mask_size = buffer.green_mask_size,
        .green_mask_shift = buffer.green_mask_shift,
        .blue_mask_size = buffer.blue_mask_size,
        .blue_mask_shift = buffer.blue_mask_shift,
    };
}

pub fn deviceTreeBlob() ?innigkeit.KernelVirtualAddress {
    const resp = requests.device_tree_blob.response orelse return null;
    return resp.address;
}

fn limineEntryPoint() callconv(.c) noreturn {
    asm volatile (architecture.scheduling.cfi_prevent_unwinding);

    architecture.earlyDebugWrite("innigkeit: limine entry\n");

    boot.bootloader_api = .limine;

    limine_revison = requests.limine_base_revison.loadedRevision() orelse {
        // TODO: attempt loading with limine revision 0 and log that the requested revision was not available
        @panic("bootloader does not supported requested limine revision!");
    };

    @call(.never_inline, innigkeit.init.bootstrap, .{}) catch |err| {
        std.debug.panic("unhandled error: {t}!", .{err});
    };
    @panic("`innigkeit.init.bootstrap` returned!");
}

const target_limine_revison: root.BaseRevison.Revison = .@"6";
var limine_revison: root.BaseRevison.Revison = .@"0";

pub fn exportRequests() void {
    @export(&requests.limine_base_revison, .{
        .name = "limine_base_revison_request",
    });
    @export(&requests.entry_point, .{
        .name = "limine_entry_point_request",
    });
    @export(&requests.kernel_address, .{
        .name = "limine_kernel_address_request",
    });
    @export(&requests.memory_map, .{
        .name = "limine_memmap_request",
    });
    @export(&requests.hhdm, .{
        .name = "limine_hhdm_request",
    });
    @export(&requests.rsdp, .{
        .name = "limine_rsdp_request",
    });
    @export(&requests.smp, .{
        .name = "limine_smp_request",
    });
    @export(&requests.framebuffer, .{
        .name = "limine_framebuffer_request",
    });
    @export(&requests.device_tree_blob, .{
        .name = "limine_device_tree_blob_request",
    });
    @export(&requests.executable_file, .{
        .name = "limine_executable_file_request",
    });
    @export(&requests.stack_size, .{
        .name = "limine_stack_size_request",
    });
}

const requests = struct {
    var limine_base_revison: root.BaseRevison = .{
        .revison = target_limine_revison,
    };
    var entry_point: root.EntryPoint.Request = .{
        .entry = limineEntryPoint,
    };
    var kernel_address: root.ExecutableAddress.Request = .{};
    var memory_map: root.MemoryMap.Request = .{};
    var hhdm: root.HHDM.Request = .{};
    var rsdp: root.RSDP.Request = .{};
    var smp: root.MP.Request = .{
        .flags = .{ .x2apic = true },
    };
    var framebuffer: root.Framebuffer.Request = .{};
    var device_tree_blob: root.DeviceTreeBlob.Request = .{};
    var executable_file: root.ExecutableFile.Request = .{};
    var stack_size: root.StackSize.Request = .{
        .stack_size = innigkeit.config.task.kernel_stack_size,
    };
};
