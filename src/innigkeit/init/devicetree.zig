// FIXME: we assume #address-cells and #size-cells are both two

const std = @import("std");

const boot = @import("boot");
const innigkeit = @import("innigkeit");
const uart = innigkeit.init.Output.uart;

pub const DeviceTree = @import("DeviceTree");

const log = innigkeit.debug.log.scoped(.devicetree);

pub fn tryGetSerialOutput(memory_system_available: bool) ?uart.Uart {
    return tryGetSerialOutputInner(memory_system_available) catch |err| {
        switch (err) {
            error.BadOffset => {
                log.warn("attempted to use a bad offset into the device tree", .{});
            },
            error.Truncated => {
                log.warn("the device tree blob is truncated", .{});
            },
            error.DivisorTooLarge => {
                log.warn("baud divisor too large", .{});
            },
            error.SizeNotMultiple => {
                log.warn("the regs property size is not a multiple of the address-cells + size-cells", .{});
            },
            error.NoError => {},
            else => log.err("failed to initialize serial output: {}", .{err}),
        }

        return null;
    };
}

fn tryGetSerialOutputInner(memory_system_available: bool) !uart.Uart {
    const dt = getDeviceTree() orelse return error.NoError;

    if (try getSerialOutputFromChosenNode(dt, memory_system_available)) |output_uart| return output_uart;

    var iter = try dt.nodeCompatibleMatchIteratorAdvanced(
        .root,
        .all_children,
        {},
        matchFunction,
    );

    while (try iter.next(dt)) |compatible_match| {
        const func = compatible_lookup.get(compatible_match.compatible).?;
        if (try func(dt, compatible_match.node.node, memory_system_available)) |output_uart| return output_uart;
    }

    return error.NoError;
}

fn getDeviceTree() ?DeviceTree {
    const address = boot.deviceTreeBlob() orelse return null;
    const ptr = address.toPtr([*]align(8) const u8);
    return DeviceTree.fromPtr(ptr) catch |err| {
        log.warn("failed to parse device tree blob: {t}", .{err});
        return null;
    };
}

fn getSerialOutputFromChosenNode(dt: DeviceTree, memory_system_available: bool) GetSerialOutputError!?uart.Uart {
    const chosen_node = blk: {
        var node_iter = try dt.nodeIterator(
            .root,
            .direct_children,
            .{ .name = "chosen" },
        );
        break :blk (try node_iter.next(dt)) orelse return null;
    };

    const stdout_path_property = blk: {
        var property_iter = try chosen_node.node.propertyIterator(
            dt,
            .{ .name = "stdout-path" },
        );
        break :blk (try property_iter.next()) orelse return null;
    };

    const stdout_path = stdout_path_property.value.toString();

    const node = (dt.nodeFromPath(stdout_path) catch |err| switch (err) {
        error.BadOffset, error.Truncated => |e| return e,
        error.BadPath => {
            log.warn("the chosen nodes stdout-path property is not a valid path", .{});
            return null;
        },
    }) orelse return null;

    var compatible_iter = try node.node.compatibleIterator(dt);

    while (try compatible_iter.next()) |compatible| {
        if (compatible_lookup.get(compatible)) |getSerialOutputFn| {
            return try getSerialOutputFn(dt, node.node, memory_system_available);
        }
    }

    return null;
}

fn getSerialOutputFromNS16550a(dt: DeviceTree, node: DeviceTree.Node, memory_system_available: bool) GetSerialOutputError!?uart.Uart {
    if (!memory_system_available) return null;

    const clock_frequency = blk: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "clock-frequency" },
        );

        const clock_frequency_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no clock-frequency property found for ns16550a", .{});
            return null;
        };

        break :blk clock_frequency_property.value.toU32();
    };
    const address = blk: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "reg" },
        );

        const reg_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no reg property found for ns16550a", .{});
            return null;
        };

        // FIXME: rather than assume address-cells and size-cells are both two, we should actually look at the parent
        var reg_iter = try reg_property.value.regIterator(2, 2);

        const reg = reg_iter.next() orelse {
            log.warn("no reg property found for ns16550a", .{});
            return null;
        };
        break :blk reg.address;
    };

    const register_range = try innigkeit.memory.heap.allocateSpecial(
        .{
            .physical_range = .from(
                .from(address),
                uart.Memory16550.register_region_size,
            ),
            .protection = .{ .read = true, .write = true },
            .cache = .uncached,
        },
    );
    errdefer innigkeit.memory.heap.deallocateSpecial(register_range);

    const device = try uart.Memory16550.create(
        register_range.address.toPtr([*]volatile u8),
        .{
            .clock_frequency = @enumFromInt(clock_frequency),
            .baud_rate = .@"115200",
        },
    );

    return .{ .memory_16550 = device };
}

fn getSerialOutputFromPL011(dt: DeviceTree, node: DeviceTree.Node, memory_system_available: bool) GetSerialOutputError!?uart.Uart {
    if (!memory_system_available) return null;

    const clock_frequency = clock_frequency: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "clocks" },
        );

        const clocks_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no clocks property found for pl011", .{});
            return null;
        };

        // there are multiple clocks, but the first one happens to be the one we want
        var clocks_iter = try clocks_property.value.pHandleListIterator();
        const clock_phandle = clocks_iter.next() orelse {
            log.warn("no clocks phandle found for pl011", .{});
            return null;
        };

        const clock_node = (try clock_phandle.node(dt)) orelse {
            log.warn("no clock node found for pl011", .{});
            return null;
        };

        property_iter = try clock_node.node.propertyIterator(
            dt,
            .{ .name = "clock-frequency" },
        );

        const clock_frequency_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no clock-frequency property found for pl011", .{});
            return null;
        };

        break :clock_frequency clock_frequency_property.value.toU32();
    };
    const address = blk: {
        var property_iter = try node.propertyIterator(
            dt,
            .{ .name = "reg" },
        );

        const reg_property = if (try property_iter.next()) |prop| prop else {
            log.warn("no reg property found for pl011", .{});
            return null;
        };

        // FIXME: rather than assume address-cells and size-cells are both two, we should actually look at the parent
        var reg_iter = try reg_property.value.regIterator(2, 2);

        const reg = reg_iter.next() orelse {
            log.warn("no reg property found for pl011", .{});
            return null;
        };
        break :blk reg.address;
    };

    const register_range = try innigkeit.memory.heap.allocateSpecial(
        .{
            .physical_range = .from(
                .from(address),
                uart.PL011.register_region_size,
            ),
            .protection = .{ .read = true, .write = true },
            .cache = .uncached,
        },
    );
    errdefer innigkeit.memory.heap.deallocateSpecial(register_range);

    const device = try uart.PL011.create(
        register_range.address.toPtr([*]volatile u32),
        .{
            .clock_frequency = @enumFromInt(clock_frequency),
            .baud_rate = .@"115200",
        },
    );

    return .{ .pl011 = device };
}

fn matchFunction(_: void, compatible: [:0]const u8) bool {
    return compatible_lookup.get(compatible) != null;
}

/// A PCI address-space window described by a pcie node's `ranges` entry.
pub const PciRange = struct {
    /// PCI-side address (the value programmed into a BAR is an offset into this).
    pci_base: u64,
    /// CPU physical address the window maps to.
    cpu_base: u64,
    /// Window size in bytes.
    size: u64,
};

/// Find the host PCIe bridge's I/O-space `ranges` window from the device tree.
///
/// On the QEMU `virt` machine there is no CPU port I/O; a legacy virtio-pci
/// device's I/O BAR is an offset into a PCI I/O aperture that the host bridge
/// maps to a fixed CPU physical address. The pcie node's `ranges` property
/// describes that aperture. Each entry is `<child(3 cells) parent(2 cells)
/// size(2 cells)>`; the high cell of the child address encodes the space type
/// in bits [25:24] (0b01 = I/O space). We return the I/O-space entry's
/// PCI-side base, the CPU physical base it maps to, and its size.
///
/// Returns null if there is no device tree or no I/O-space range (the caller
/// should fall back to a machine-known default).
pub fn pciIoWindow() ?PciRange {
    const dt = getDeviceTree() orelse return null;
    return pciIoWindowInner(dt) catch |err| {
        log.warn("failed to parse pcie ranges for the I/O window: {t}", .{err});
        return null;
    };
}

fn pciIoWindowInner(dt: DeviceTree) DeviceTree.IteratorError!?PciRange {
    // Find a node whose device_type is "pci" (the host bridge). On virt this is
    // `/pcie@...`; matching on device_type avoids hardcoding the unit address.
    var node_iter = try dt.nodeIterator(
        .root,
        .all_children,
        .{ .property_value = .{
            .name = "device_type",
            .value = .fromString("pci"),
        } },
    );

    const pci_node = (try node_iter.next(dt)) orelse return null;

    var property_iter = try pci_node.node.propertyIterator(dt, .{ .name = "ranges" });
    const ranges = (try property_iter.next()) orelse return null;

    // ranges layout: child PCI address = 3 cells, parent (CPU) address = 2
    // cells, size = 2 cells => 7 cells (28 bytes) per entry. The pcie node
    // declares #address-cells = 3 / #size-cells = 2; the parent (root) bus
    // uses 2 address cells on virt.
    const raw = ranges.value._raw;
    const entry_cells = 7;
    const entry_bytes = entry_cells * @sizeOf(u32);
    if (raw.len % entry_bytes != 0) return null;

    var off: usize = 0;
    while (off + entry_bytes <= raw.len) : (off += entry_bytes) {
        const cell = struct {
            fn read(bytes: []const u8, i: usize) u32 {
                const p: *align(1) const u32 = @ptrCast(bytes[i * 4 ..].ptr);
                return std.mem.bigToNative(u32, p.*);
            }
        }.read;

        const hi = cell(raw[off..], 0); // child address high cell (space code)
        const space: u32 = (hi >> 24) & 0x3; // bits [25:24]
        const pci_base: u64 = (@as(u64, cell(raw[off..], 1)) << 32) | cell(raw[off..], 2);
        const cpu_base: u64 = (@as(u64, cell(raw[off..], 3)) << 32) | cell(raw[off..], 4);
        const size: u64 = (@as(u64, cell(raw[off..], 5)) << 32) | cell(raw[off..], 6);

        if (space == 0b01) { // I/O space
            return .{ .pci_base = pci_base, .cpu_base = cpu_base, .size = size };
        }
    }

    return null;
}

const compatible_lookup = std.StaticStringMap(GetSerialOutputFn).initComptime(.{
    .{ "ns16550a", getSerialOutputFromNS16550a },
    .{ "arm,pl011", getSerialOutputFromPL011 },
});

const GetSerialOutputError = DeviceTree.IteratorError ||
    DeviceTree.Property.Value.ListIteratorError ||
    uart.CreateError ||
    innigkeit.memory.heap.AllocateSpecialOptions.Error;
const GetSerialOutputFn = *const fn (dt: DeviceTree, node: DeviceTree.Node, memory_system_available: bool) GetSerialOutputError!?uart.Uart;
