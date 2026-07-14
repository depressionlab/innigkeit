const _boot = @import("boot");
const limine = @import("limine/interface.zig");

pub const CpuDescriptors = union {
    unknown: void,
    limine: limine.CpuDescriptorIterator,

    pub fn count(self: *const CpuDescriptors) usize {
        return switch (_boot.bootloader_api) {
            .limine => self.limine.count(),
            .unknown => 0,
        };
    }

    /// Returns the next cpu descriptor from the iterator, if any remain.
    pub fn next(self: *CpuDescriptors) ?Descriptor {
        return switch (_boot.bootloader_api) {
            .limine => self.limine.next(),
            .unknown => null,
        };
    }

    pub const Descriptor = union {
        unknown: void,
        limine: limine.CpuDescriptorIterator.Descriptor,

        pub fn boot(
            self: *const Descriptor,
            user_data: *anyopaque,
            target_fn: fn (user_data: *anyopaque) anyerror!noreturn,
        ) void {
            switch (_boot.bootloader_api) {
                .limine => self.limine.bootFn(user_data, target_fn),
                .unknown => unreachable,
            }
        }

        pub fn acpiProcessorId(self: *const Descriptor) u32 {
            return switch (_boot.bootloader_api) {
                .limine => self.limine.acpiProcessorId(),
                .unknown => unreachable,
            };
        }

        pub fn architectureProcessorId(self: *const Descriptor) u64 {
            return switch (_boot.bootloader_api) {
                .limine => self.limine.architectureProcessorId(),
                .unknown => unreachable,
            };
        }
    };
};
