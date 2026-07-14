//! Accessor for a legacy virtio-pci device's register window.
//!
//! On x86-64 the legacy registers live behind an **I/O-space** BAR, so this is
//! a thin wrapper around a 16-bit I/O port base (`in`/`out` instructions). On
//! AArch64 (e.g. the QEMU `virt` machine) there is no port I/O: the same legacy
//! registers are exposed through a **memory** BAR, so this wraps a kernel
//! virtual base address mapped Device-nGnRE and accesses it with plain MMIO
//! loads/stores. The register offsets and semantics are identical either way.
//!
//! Zero cost: all methods are `inline`, emitting the same instructions as if
//! they were written directly in each driver.
const PortIo = @This();

const architecture = @import("architecture");
const builtin = @import("builtin");
const innigkeit = @import("innigkeit");

/// Register-window base. On x86-64 this is the 16-bit I/O port base (only the
/// low 16 bits are meaningful); on AArch64 it is the kernel virtual address of
/// the device's memory BAR.
base: u64,

/// AArch64 (and any non-x86 target) reaches the legacy registers via MMIO.
const is_mmio = builtin.cpu.arch != .x86_64;

inline fn portBase(self: PortIo) u16 {
    return @truncate(self.base);
}

/// MMIO path uses the architecture's PCI-config MMIO accessors: those are
/// already plain Device-memory loads/stores at a kernel virtual address, which
/// is exactly what a virtio memory BAR needs (and they work for any MMIO
/// address, not just config space).
inline fn mmioAddress(self: PortIo, offset: u16) innigkeit.KernelVirtualAddress {
    return .{ .value = self.base + offset };
}

pub inline fn r8(self: PortIo, offset: u16) u8 {
    if (is_mmio) return architecture.io.pci.read(u8, self.mmioAddress(offset));
    const p = architecture.io.Port.from(self.portBase() + offset) catch unreachable;
    return p.read(u8);
}
pub inline fn r16(self: PortIo, offset: u16) u16 {
    if (is_mmio) return architecture.io.pci.read(u16, self.mmioAddress(offset));
    const p = architecture.io.Port.from(self.portBase() + offset) catch unreachable;
    return p.read(u16);
}
pub inline fn r32(self: PortIo, offset: u16) u32 {
    if (is_mmio) return architecture.io.pci.read(u32, self.mmioAddress(offset));
    const p = architecture.io.Port.from(self.portBase() + offset) catch unreachable;
    return p.read(u32);
}
pub inline fn w8(self: PortIo, offset: u16, v: u8) void {
    if (is_mmio) return architecture.io.pci.write(u8, self.mmioAddress(offset), v);
    const p = architecture.io.Port.from(self.portBase() + offset) catch unreachable;
    p.write(u8, v);
}
pub inline fn w16(self: PortIo, offset: u16, v: u16) void {
    if (is_mmio) return architecture.io.pci.write(u16, self.mmioAddress(offset), v);
    const p = architecture.io.Port.from(self.portBase() + offset) catch unreachable;
    p.write(u16, v);
}
pub inline fn w32(self: PortIo, offset: u16, v: u32) void {
    if (is_mmio) return architecture.io.pci.write(u32, self.mmioAddress(offset), v);
    const p = architecture.io.Port.from(self.portBase() + offset) catch unreachable;
    p.write(u32, v);
}
