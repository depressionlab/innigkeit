// The "mixins" in this file have signatures only to help ZLS realize they are "methods".

pub const VirtualAddress = @import("VirtualAddress.zig").VirtualAddress;
pub const KernelVirtualAddress = @import("KernelVirtualAddress.zig").KernelVirtualAddress;
pub const UserVirtualAddress = @import("UserVirtualAddress.zig").UserVirtualAddress;
pub const PhysicalAddress = @import("PhysicalAddress.zig").PhysicalAddress;
pub const VirtualRange = @import("VirtualRange.zig").VirtualRange;
pub const KernelVirtualRange = @import("KernelVirtualRange.zig").KernelVirtualRange;
pub const UserVirtualRange = @import("UserVirtualRange.zig").UserVirtualRange;
pub const PhysicalRange = @import("PhysicalRange.zig").PhysicalRange;
pub const AddressMixin = @import("AddressMixin.zig").AddressMixin;
pub const RangeMixin = @import("RangeMixin.zig").RangeMixin;
