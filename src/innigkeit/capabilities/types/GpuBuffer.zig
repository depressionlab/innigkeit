//! UMA (Unified Memory Architecture) zero-copy GPU buffer capability.
//!
//! ## Design
//! On Apple M-series and similar UMA SoCs, the CPU and GPU share the same
//! physical memory. A `GpuBuffer` wraps a contiguous run of physical pages that
//! is simultaneously accessible from both the CPU (via a VMA in the process
//! address space) and the GPU (via IOMMU / GPU page table mapping).
//!
//! This removes the CPU -> GPU DMA copy that discrete-GPU systems require.
//!
//! ## Capability operations (cap_invoke)
//! - phys_addr (Op.phys_addr): return base physical address as a u64
//! - size (Op.size): return buffer size in bytes
//! - usage (Op.usage): return Usage bitmask
//!
//! ## Implementation status
//! Stub: wires capability infrastructure (refcount, ObjectType, Op dispatch).

const GpuBuffer = @This();

const innigkeit = @import("innigkeit");
const std = @import("std");

generation: std.atomic.Value(u32) = .init(0),
refcount: std.atomic.Value(usize) = .init(1),

/// Base physical address of the contiguous buffer region.
phys_base: innigkeit.PhysicalAddress,

/// Buffer size in bytes (always a multiple of 4 KiB).
size_bytes: usize,

/// Intended GPU use cases (bitmask of `Usage` values).
usage: Usage,

pub const Usage = packed struct(u32) {
    /// Buffer may be used as a vertex / index buffer.
    vertex_buffer: bool = false,
    /// Buffer may be used as a texture / sampled image.
    texture: bool = false,
    /// Buffer may be used as a render target / framebuffer attachment.
    render_target: bool = false,
    /// Buffer may be used for GPU -> CPU readback.
    readback: bool = false,
    /// Buffer may be mapped into CPU address space simultaneously.
    cpu_visible: bool = true,
    _pad: u27 = 0,
};

/// Allocate a GpuBuffer backed by `page_count` contiguous physical pages.
///
/// Physical pages must be contiguous for IOMMU mapping. This stub records the
/// base address of the *first* allocated page; real implementation must use a
/// contiguous-page allocator.
pub fn create(page_count: usize, usage: Usage) error{OutOfMemory}!*GpuBuffer {
    if (page_count == 0) return error.OutOfMemory;
    // Contiguous-page allocator not yet implemented. Silently allowing
    // page_count > 1 would produce a struct claiming N pages of memory while
    // only one page is actually allocated, so any GPU access past the first page
    // corrupts unrelated physical memory. Reject until the allocator exists.
    if (page_count > 1) return error.OutOfMemory;

    // Allocate the metadata struct from the kernel heap.
    const self = try innigkeit.memory.heap.allocator.create(GpuBuffer);

    // TODO(gpu_buffer): replace single-page alloc with contiguous allocator.
    const first_page = innigkeit.memory.PhysicalPage.allocator.allocate() catch {
        innigkeit.memory.heap.allocator.destroy(self);
        return error.OutOfMemory;
    };

    self.* = .{
        .phys_base = first_page.baseAddress(),
        .size_bytes = @import("architecture").paging.standard_page_size.value,
        .usage = usage,
    };
    return self;
}

pub fn ref(self: *GpuBuffer) void {
    _ = self.refcount.fetchAdd(1, .acq_rel);
}

pub fn unref(self: *GpuBuffer) void {
    if (self.refcount.fetchSub(1, .acq_rel) != 1) return;
    // TODO(gpu_buffer): free all contiguous pages, not just the first one.
    var list: innigkeit.memory.PhysicalPage.List = .{};
    list.prepend(.fromAddress(self.phys_base));
    innigkeit.memory.PhysicalPage.allocator.deallocate(list);
    innigkeit.memory.heap.allocator.destroy(self);
}

/// Selectors for cap_invoke on a GpuBuffer capability.
pub const Op = enum(u64) {
    /// Return base physical address as word[0].
    phys_addr = 0,
    /// Return buffer size in bytes as word[0].
    size = 1,
    /// Return Usage bitmask as word[0].
    usage = 2,
};

fn pageSize() usize {
    return @import("architecture").paging.standard_page_size.value;
}

test "gpu_buffer: create returns non-null with correct size" {
    const buf = try GpuBuffer.create(1, .{ .cpu_visible = true });
    defer buf.unref();

    try std.testing.expect(buf.size_bytes == pageSize());
    try std.testing.expect(buf.usage.cpu_visible);
    try std.testing.expect(!buf.usage.vertex_buffer);
    try std.testing.expect(buf.phys_base.value != 0);
}

test "gpu_buffer: multi-page create returns OutOfMemory (contiguous allocator not implemented)" {
    try std.testing.expectError(error.OutOfMemory, GpuBuffer.create(4, .{ .vertex_buffer = true, .cpu_visible = true }));
}

test "gpu_buffer: single-page has correct size and usage" {
    const buf = try GpuBuffer.create(1, .{ .vertex_buffer = true, .cpu_visible = true });
    defer buf.unref();

    try std.testing.expectEqual(pageSize(), buf.size_bytes);
    try std.testing.expect(buf.usage.vertex_buffer);
    try std.testing.expect(buf.usage.cpu_visible);
    try std.testing.expect(!buf.usage.texture);
}

test "gpu_buffer: refcount increments and decrements" {
    const buf = try GpuBuffer.create(1, .{});
    try std.testing.expectEqual(@as(usize, 1), buf.refcount.load(.acquire));

    buf.ref();
    try std.testing.expectEqual(@as(usize, 2), buf.refcount.load(.acquire));

    buf.unref(); // back to 1; should NOT free
    try std.testing.expectEqual(@as(usize, 1), buf.refcount.load(.acquire));

    buf.unref(); // drops to 0 -> freed; no crash = pass
}

test "gpu_buffer: usage bitcast round-trips through u32" {
    const u: Usage = .{ .vertex_buffer = true, .texture = false, .render_target = true, .readback = false, .cpu_visible = true };
    const raw: u32 = @bitCast(u);
    const recovered: Usage = @bitCast(raw);
    try std.testing.expectEqual(u, recovered);
}
