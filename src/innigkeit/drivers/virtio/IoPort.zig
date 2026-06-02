//! Shared I/O port accessor for legacy virtio PCI drivers.
//!
//! Both virtio-blk and virtio-net use the same pattern of reading/writing
//! 8/16/32-bit values at io_base + offset. This module centralises that logic.

const architecture = @import("architecture");

/// Thin wrapper around a 16-bit I/O base address.
/// Zero cost: all methods are `inline`, emitting the same instructions as
/// if they were written directly in each driver.
pub const PortIo = struct {
    base: u16,

    pub inline fn r8(self: PortIo, offset: u16) u8 {
        const p = architecture.io.Port.from(self.base + offset) catch unreachable;
        return p.read(u8);
    }
    pub inline fn r16(self: PortIo, offset: u16) u16 {
        const p = architecture.io.Port.from(self.base + offset) catch unreachable;
        return p.read(u16);
    }
    pub inline fn r32(self: PortIo, offset: u16) u32 {
        const p = architecture.io.Port.from(self.base + offset) catch unreachable;
        return p.read(u32);
    }
    pub inline fn w8(self: PortIo, offset: u16, v: u8) void {
        const p = architecture.io.Port.from(self.base + offset) catch unreachable;
        p.write(u8, v);
    }
    pub inline fn w16(self: PortIo, offset: u16, v: u16) void {
        const p = architecture.io.Port.from(self.base + offset) catch unreachable;
        p.write(u16, v);
    }
    pub inline fn w32(self: PortIo, offset: u16, v: u32) void {
        const p = architecture.io.Port.from(self.base + offset) catch unreachable;
        p.write(u32, v);
    }
};
