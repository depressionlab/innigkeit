//! MP (Multiprocessor) Feature
//!
//! Notes:
//! - The presence of this request will prompt the bootloader to bootstrap
//!   the secondary processors. This will not be done if this request is not present.
//! - On x86-64, if firmware has already enabled x2APIC and bit 0 is clear, the
//!   bootloader will try to disable x2APIC before handoff. If the MP request is
//!   present and x2APIC cannot be disabled, the bootloader will fail to boot the
//!   executable.

const root = @import("root.zig");
const std = @import("std");

pub const Request = extern struct {
    id: [4]u64 = root.id(0x95A67B819A1B857E, 0xA0B61B723B6A73E0),
    revision: u64 = 0,

    response: ?*const Response = null,
    flags: Flags = .{},
};

pub const Flags = packed struct(u64) {
    /// Enable x2APIC, if possible. (x86-64 only)
    x2apic: bool = false,

    _: u63 = 0,
};

pub const Response = switch (root.arch) {
    .aarch64 => aarch64,
    .loongarch64 => loongarch64,
    .riscv64 => riscv64,
    .x86_64 => x86_64,
};

pub const aarch64 = extern struct {
    revision: u64,

    /// Always zero.
    flags: u64,

    /// MPIDR of the bootstrap processor (as read from MPIDR_EL1, with Res1 masked off).
    bsp_mpidr: u64,

    _cpu_count: u64,
    _cpus: [*]*MPInfo,

    pub fn cpus(self: *const aarch64) []*MPInfo {
        return self._cpus[0..self._cpu_count];
    }

    pub fn print(self: *const aarch64, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("MP{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("bsp_mpidr: {}\n", .{self.bsp_mpidr});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("cpus:\n");

        for (self.cpus()) |cpu| {
            try writer.splatByteAll(' ', new_indent + 2);
            try cpu.print(writer, new_indent + 2);
            try writer.writeByte('\n');
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const aarch64, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }

    pub const MPInfo = extern struct {
        /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems)
        processor_id: u32,

        _reserved1: u32,

        /// MPIDR of the processor as specified by the MADT or device tree
        mpidr: u64,

        _reserved2: u64,

        /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB (or Stack Size Request size)
        /// stack.
        ///
        /// A pointer to the `MPInfo` structure of the CPU is passed in X0.
        ///
        /// Other than that, the CPU state will be the same as described for the bootstrap processor.
        ///
        /// This field is unused for the structure describing the bootstrap processor.
        ///
        /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap processor.
        goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.c) noreturn,

        /// A free for use field.
        extra_argument: u64,

        pub fn print(self: *const MPInfo, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("CPU{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("processor_id: {}\n", .{self.processor_id});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("mpidr: {}\n", .{self.mpidr});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(self: *const MPInfo, writer: *std.Io.Writer) !void {
            return self.print(writer, 0);
        }
    };
};

pub const loongarch64 = extern struct {
    revision: u64,

    /// Always zero.
    flags: u64,

    /// Physical CPU ID of the bootstrap processor (as read from CSR.CPUID).
    bsp_phys_id: u64,

    _cpu_count: u64,
    _cpus: [*]*MPInfo,

    pub fn cpus(self: *const loongarch64) []*MPInfo {
        return self._cpus[0..self._cpu_count];
    }

    pub fn print(self: *const loongarch64, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("MP{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("bsp_phys_id: {}\n", .{self.bsp_phys_id});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("cpus:\n");

        for (self.cpus()) |cpu| {
            try writer.splatByteAll(' ', new_indent + 2);
            try cpu.print(writer, new_indent + 2);
            try writer.writeByte('\n');
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const loongarch64, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }

    pub const MPInfo = extern struct {
        /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems).
        processor_id: u64,

        /// Physical CPU ID of the processor as specified by the MADT or device tree.
        phys_id: u64,

        _reserved: u64,

        /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB (or Stack Size Request size)
        /// stack.
        ///
        /// A pointer to the `MPInfo` structure of the CPU is passed in $a0.
        ///
        /// Other than that, the CPU state will be the same as described for the bootstrap processor.
        ///
        /// This field is unused for the structure describing the bootstrap processor.
        ///
        /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap processor.
        goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.c) noreturn,

        /// A free for use field.
        extra_argument: u64,

        pub fn print(self: *const MPInfo, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("CPU{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("processor_id: {}\n", .{self.processor_id});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("phys_id: {}\n", .{self.phys_id});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(self: *const MPInfo, writer: *std.Io.Writer) !void {
            return self.print(writer, 0);
        }
    };
};

pub const riscv64 = extern struct {
    revision: u64,

    /// Always zero.
    flags: u64,

    /// Hart ID of the bootstrap processor as reported by the UEFI RISC-V Boot Protocol or the SBI.
    bsp_hartid: u64,

    _cpu_count: u64,
    _cpus: [*]*MPInfo,

    pub fn print(self: *const riscv64, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("MP{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("bsp_hartid: {}\n", .{self.bsp_hartid});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("cpus:\n");

        for (self.cpus()) |cpu| {
            try writer.splatByteAll(' ', new_indent + 2);
            try cpu.print(writer, new_indent + 2);
            try writer.writeByte('\n');
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const riscv64, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }

    pub fn cpus(self: *const riscv64) []*MPInfo {
        return self._cpus[0..self._cpu_count];
    }

    pub const MPInfo = extern struct {
        /// ACPI Processor UID as specified by the MADT (always 0 on non-ACPI systems).
        processor_id: u64,

        /// Hart ID of the processor as specified by the MADT or Device Tree.
        hartid: u64,

        _reserved: u64,

        /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB (or Stack Size Request size)
        /// stack.
        ///
        /// A pointer to the `MPInfo` structure of the CPU is passed in x10(a0).
        ///
        /// Other than that, the CPU state will be the same as described for the bootstrap processor.
        ///
        /// This field is unused for the structure describing the bootstrap processor.
        ///
        /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap processor.
        goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.c) noreturn,

        /// A free for use field.
        extra_argument: u64,

        pub fn print(self: *const MPInfo, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("CPU{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("processor_id: {}\n", .{self.processor_id});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("hartid: {}\n", .{self.hartid});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(self: *const MPInfo, writer: *std.Io.Writer) !void {
            return self.print(writer, 0);
        }
    };
};

test "MP Response.format compiles and runs for the current architecture" {
    // These format()/print() chains are never called by anything in the
    // kernel itself (this is a debug-dump helper) so calling them here is
    // the only thing that forces Zig to actually analyze their bodies (a
    // mere `_ = &Response.format;` reference does not, since `format` is
    // `inline`; confirmed empirically before relying on this). Catches the
    // exact bug class found in this file (an inline format() that
    // mis-called its own print(), and aarch64/loongarch64's calls to
    // `Io.Writer.any()`, a method that doesn't exist in this Zig version).
    const resp: Response = switch (root.arch) {
        .x86_64 => .{
            .revision = 0,
            .flags = .{},
            .bsp_lapic_id = 0,
            ._cpu_count = 0,
            ._cpus = &.{},
        },
        .aarch64 => .{
            .revision = 0,
            .flags = 0,
            .bsp_mpidr = 0,
            ._cpu_count = 0,
            ._cpus = &.{},
        },
        .loongarch64 => .{
            .revision = 0,
            .flags = 0,
            .bsp_phys_id = 0,
            ._cpu_count = 0,
            ._cpus = &.{},
        },
        .riscv64 => .{
            .revision = 0,
            .flags = 0,
            .bsp_hartid = 0,
            ._cpu_count = 0,
            ._cpus = &.{},
        },
    };

    var buf: [256]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);
    try writer.print("{f}", .{resp});
}

pub const x86_64 = extern struct {
    revision: u64,

    flags: ResponseFlags,

    /// The Local APIC ID of the bootstrap processor.
    bsp_lapic_id: u32,

    _cpu_count: u64,
    _cpus: [*]*MPInfo,

    pub const ResponseFlags = packed struct(u32) {
        /// x2APIC has been enabled
        x2apic_enabled: bool = false,
        _: u31 = 0,
    };

    pub fn cpus(self: *const x86_64) []*MPInfo {
        return self._cpus[0..self._cpu_count];
    }

    pub fn print(self: *const x86_64, writer: *std.Io.Writer, indent: usize) !void {
        const new_indent = indent + 2;

        try writer.writeAll("MP{\n");

        try writer.splatByteAll(' ', new_indent);
        try writer.print("bsp_lapic_id: {}\n", .{self.bsp_lapic_id});

        try writer.splatByteAll(' ', new_indent);
        try writer.print("x2apic_enabled: {}\n", .{self.flags.x2apic_enabled});

        try writer.splatByteAll(' ', new_indent);
        try writer.writeAll("cpus:\n");

        for (self.cpus()) |cpu| {
            try writer.splatByteAll(' ', new_indent + 2);
            try cpu.print(writer, new_indent + 2);
            try writer.writeByte('\n');
        }

        try writer.splatByteAll(' ', indent);
        try writer.writeByte('}');
    }

    pub inline fn format(self: *const x86_64, writer: *std.Io.Writer) !void {
        return self.print(writer, 0);
    }

    pub const MPInfo = extern struct {
        /// ACPI Processor UID as specified by the MADT
        processor_id: u32,

        /// Local APIC ID of the processor as specified by the MADT
        lapic_id: u32,

        /// Reserved for bootloader use.
        _reserved: u64,

        /// An atomic write to this field causes the parked CPU to jump to the written address, on a 64KiB (or Stack Size Request size)
        /// stack.
        ///
        /// A pointer to the `MPInfo` structure of the CPU is passed in RDI.
        ///
        /// Other than that, the CPU state will be the same as described for the bootstrap processor.
        ///
        /// This field is unused for the structure describing the bootstrap processor.
        ///
        /// For all CPUs, this field is guaranteed to be `null` when control is first passed to the bootstrap processor.
        goto_address: ?*const fn (smp_info: *const MPInfo) callconv(.c) noreturn,

        /// A free for use field.
        extra_argument: u64,

        pub fn print(self: *const MPInfo, writer: *std.Io.Writer, indent: usize) !void {
            const new_indent = indent + 2;

            try writer.writeAll("CPU{\n");

            try writer.splatByteAll(' ', new_indent);
            try writer.print("processor_id: {}\n", .{self.processor_id});

            try writer.splatByteAll(' ', new_indent);
            try writer.print("lapic_id: {}\n", .{self.lapic_id});

            try writer.splatByteAll(' ', indent);
            try writer.writeByte('}');
        }

        pub inline fn format(self: *const MPInfo, writer: *std.Io.Writer) !void {
            return self.print(writer, 0);
        }
    };
};
