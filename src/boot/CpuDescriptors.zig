const limine = @import("limine/interface.zig");
const _boot = @import("boot");

pub const CpuDescriptors = union {
    unknown: void,
    limine: limine.CpuDescriptorIterator,

    pub fn count(cpu_descriptors: *const CpuDescriptors) usize {
        return switch (_boot.bootloader_api) {
            .limine => cpu_descriptors.limine.count(),
            .unknown => 0,
        };
    }

    /// Returns the next cpu descriptor from the iterator, if any remain.
    pub fn next(cpu_descriptors: *CpuDescriptors) ?Descriptor {
        return switch (_boot.bootloader_api) {
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
            switch (_boot.bootloader_api) {
                .limine => descriptor.limine.bootFn(user_data, target_fn),
                .unknown => unreachable,
            }
        }

        pub fn acpiProcessorId(descriptor: *const Descriptor) u32 {
            return switch (_boot.bootloader_api) {
                .limine => descriptor.limine.acpiProcessorId(),
                .unknown => unreachable,
            };
        }

        pub fn architectureProcessorId(descriptor: *const Descriptor) u64 {
            return switch (_boot.bootloader_api) {
                .limine => descriptor.limine.architectureProcessorId(),
                .unknown => unreachable,
            };
        }
    };
};
