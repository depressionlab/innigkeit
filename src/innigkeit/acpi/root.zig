const std = @import("std");

// TODO: make acpi less terrible

const architecture = @import("architecture");
const innigkeit = @import("innigkeit");

pub const Address = @import("Address.zig").Address;
pub const tables = @import("tables/tables.zig");
const uacpi = @import("uacpi.zig");

const log = innigkeit.debug.log.scoped(.acpi);

pub fn rsdpTable() *const tables.RSDP {
    return globals.rsdp;
}

pub fn tryShutdown() !void {
    if (!globals.acpi_initialized) return;
    try uacpi.prepareForSleep(.S5);
    try uacpi.sleep(.S5);
}

const globals = struct {
    /// Pointer to the RSDP table.
    ///
    /// Set by `init.earlyInitialize`.
    var rsdp: *const tables.RSDP = undefined;

    /// Set by `init.initialize`.
    var acpi_initialized: bool = false;
};

pub const init = struct {
    const boot = @import("boot");
    const init_log = innigkeit.debug.log.scoped(.acpi_init);

    /// Initializes ACPI table access early.
    ///
    /// NOP if ACPI is not present.
    pub fn earlyInitialize() !AcpiTablesHandle {
        const static = struct {
            var buffer: [architecture.paging.standard_page_size.value]u8 align(@sizeOf(usize)) = undefined;
        };

        const rsdp = switch (boot.rsdp() orelse return .{}) {
            .physical => |phys_addr| phys_addr.toDirectMap().toPtr(*const tables.RSDP),
            .virtual => |virt_addr| virt_addr.toPtr(*const tables.RSDP),
        };
        if (!rsdp.isValid()) return error.InvalidRSDP;
        globals.rsdp = rsdp;

        try uacpi.setupEarlyTableAccess(&static.buffer);
        init_globals.acpi_present = true;

        return .{};
    }

    pub const AcpiTablesHandle = struct {
        pub fn log(_: AcpiTablesHandle) !void {
            if (!init_log.levelEnabled(.debug) or !init_globals.acpi_present) return;

            const sdt_header = globals.rsdp.sdtAddress().toDirectMap().toPtr(*const tables.SharedHeader);

            if (!sdt_header.isValid()) return error.InvalidSDT;

            var iter = tableIterator(sdt_header);

            init_log.debug("ACPI tables:", .{});

            while (iter.next()) |table| {
                if (table.isValid()) {
                    init_log.debug("  {s}", .{table.signatureAsString()});
                } else {
                    init_log.debug("  {s} - INVALID", .{table.signatureAsString()});
                }
            }
        }
    };

    /// Initialize the ACPI subsystem.
    ///
    /// NOP if ACPI is not present.
    pub fn initialize() !void {
        if (!init_globals.acpi_present) {
            init_log.debug("ACPI not present", .{});
            return;
        }

        init_log.debug("entering ACPI mode", .{});
        try uacpi.initialize(.{});

        try uacpi.FixedEvent.power_button.installHandler(
            void,
            earlyPowerButtonHandler,
            null,
        );

        init_log.debug("loading namespace", .{});
        try uacpi.namespaceLoad();

        if (architecture.current_arch == .x64) {
            try uacpi.setInterruptModel(.ioapic);
        }

        init_log.debug("initializing namespace", .{});
        try uacpi.namespaceInitialize();

        init_log.debug("finializing GPEs", .{});
        try uacpi.finializeGpeInitialization();

        globals.acpi_initialized = true;
    }

    fn earlyPowerButtonHandler(_: ?*void) uacpi.InterruptReturn {
        log.warn("power button pressed", .{});
        tryShutdown() catch |err| {
            std.debug.panic("failed to shutdown: {t}!", .{err});
        };
        @panic("shutdown failed!");
    }

    pub fn AcpiTable(comptime T: type) type {
        return struct {
            table: *const T,

            handle: uacpi.Table,

            const AcpiTableT = @This();

            /// Get the `n`th matching ACPI table if present.
            ///
            /// Uses the `SIGNATURE_STRING: *const [4]u8` decl on the given `T` to find the table.
            pub fn get(n: usize) ?AcpiTable(T) {
                if (!init_globals.acpi_present) return null;

                var table = uacpi.Table.findBySignature(T.SIGNATURE_STRING) catch null orelse return null;

                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const found_next = table.nextWithSameSignature() catch return null;
                    if (!found_next) return null;
                }

                return .{
                    .table = @ptrCast(@alignCast(table.table.ptr)),
                    .handle = table,
                };
            }

            pub fn deinit(self: AcpiTableT) void {
                self.handle.unref() catch unreachable;
            }

            pub inline fn format(self: AcpiTableT, writer: *std.Io.Writer) !void {
                try writer.print(
                    "AcpiTable{{ signature: {s}, revision: {d} }}",
                    .{ self.table.header.signatureAsString(), self.table.header.revision },
                );
            }
        };
    }

    fn tableIterator(sdt_header: *const tables.SharedHeader) TableIterator {
        const sdt_ptr: [*]const u8 = @ptrCast(sdt_header);

        const is_xsdt = sdt_header.signatureIs("XSDT");
        std.debug.assert(is_xsdt or sdt_header.signatureIs("RSDT")); // Invalid SDT signature.

        return .{
            .ptr = sdt_ptr + @sizeOf(tables.SharedHeader),
            .end_ptr = sdt_ptr + sdt_header.length,
            .is_xsdt = is_xsdt,
        };
    }

    const TableIterator = struct {
        ptr: [*]const u8,
        end_ptr: [*]const u8,

        is_xsdt: bool,

        pub fn next(self: *TableIterator) ?*const tables.SharedHeader {
            const opt_phys_addr = if (self.is_xsdt)
                self.nextTablePhysicalAddressImpl(u64)
            else
                self.nextTablePhysicalAddressImpl(u32);

            const phys_addr = opt_phys_addr orelse return null;

            return phys_addr.toDirectMap().toPtr(*const tables.SharedHeader);
        }

        fn nextTablePhysicalAddressImpl(self: *TableIterator, comptime T: type) ?innigkeit.PhysicalAddress {
            if (@intFromPtr(self.ptr) + @sizeOf(T) >= @intFromPtr(self.end_ptr)) return null;

            const physical_address = std.mem.readInt(T, @ptrCast(self.ptr), .little);

            self.ptr += @sizeOf(T);

            return .from(physical_address);
        }
    };

    const init_globals = struct {
        /// If this is true, the ACPI tables have been initialized and the RSDP pointer is valid.
        var acpi_present: bool = false;
    };
};

comptime {
    _ = @import("uacpi_kernel_api.zig"); // ensure kernel api is exported
}
