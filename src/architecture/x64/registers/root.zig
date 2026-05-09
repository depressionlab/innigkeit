const innigkeit = @import("innigkeit");

pub const RFlags = @import("RFlags.zig").RFlags;
pub const Cr0 = @import("Cr0.zig").Cr0;
pub const Cr2 = @import("Cr2.zig");
pub const Cr3 = @import("Cr3.zig");
pub const Cr4 = @import("Cr4.zig").Cr4;
pub const XCr0 = @import("XCr0.zig").XCr0;
pub const EFER = @import("EFER.zig").EFER;
pub const IA32_MTRRCAP = @import("IA32_MTRRCAP.zig").IA32_MTRRCAP;
pub const PAT = @import("PAT.zig").PAT;
pub const DR0 = DebugAddressRegister(.DR0);
pub const DR1 = DebugAddressRegister(.DR1);
pub const DR2 = DebugAddressRegister(.DR2);
pub const DR3 = DebugAddressRegister(.DR3);
pub const DR6 = @import("DR6.zig").DR6;
pub const DR7 = @import("DR7.zig").DR7;
pub const IA32_STAR = @import("IA32_STAR.zig").IA32_STAR;
pub const IA32_SFMASK = @import("IA32_SFMASK.zig").IA32_SFMASK;
pub const IA32_LSTAR = MSR(u64, 0xC0000082);
pub const FS_BASE = MSR(u64, 0xC0000100);
pub const GS_BASE = MSR(u64, 0xC0000101);
pub const KERNEL_GS_BASE = MSR(u64, 0xC0000102);

/// Processors based on Nehalem microarchitecture provide an auxiliary TSC register, IA32_TSC_AUX that is designed to
/// be used in conjunction with IA32_TSC.
///
/// IA32_TSC_AUX provides a 32-bit field that is initialized by privileged software with a signature value
/// (for example, a logical processor ID).
///
/// The primary usage of IA32_TSC_AUX in conjunction with IA32_TSC is to allow software to read the 64-bit time stamp in
/// IA32_TSC and signature value in IA32_TSC_AUX with the instruction RDTSCP in an atomic operation.
///
/// RDTSCP returns the 64-bit time stamp in EDX:EAX and the 32-bit TSC_AUX signature value in ECX.
///
/// The atomicity of RDTSCP ensures that no context switch can occur between the reads of the TSC and TSC_AUX values.
pub const IA32_TSC_AUX = MSR(u64, 0xC0000103);

pub inline fn readMSR(comptime T: type, register: u32) T {
    switch (T) {
        u64 => {
            var low: u32 = undefined;
            var high: u32 = undefined;
            asm ("rdmsr"
                : [low] "={eax}" (low),
                  [high] "={edx}" (high),
                : [register] "{ecx}" (register),
            );
            return (@as(u64, high) << 32) | @as(u64, low);
        },
        u32 => {
            return asm ("rdmsr"
                : [low] "={eax}" (-> u32),
                : [register] "{ecx}" (register),
                : .{ .edx = true });
        },
        else => @compileError("read not implemented for " ++ @typeName(T)),
    }
}

pub inline fn writeMSR(comptime T: type, register: u32, value: T) void {
    switch (T) {
        u64 => {
            asm volatile ("wrmsr"
                :
                : [reg] "{ecx}" (register),
                  [low] "{eax}" (@as(u32, @truncate(value))),
                  [high] "{edx}" (@as(u32, @truncate(value >> 32))),
            );
        },
        u32 => {
            asm volatile ("wrmsr"
                :
                : [reg] "{ecx}" (register),
                  [low] "{eax}" (value),
                  [high] "{edx}" (@as(u32, 0)),
            );
        },
        else => @compileError("write not implemented for " ++ @typeName(T)),
    }
}

pub fn MSR(comptime T: type, comptime register: u32) type {
    return struct {
        pub inline fn read() T {
            return readMSR(T, register);
        }

        pub inline fn write(value: T) void {
            writeMSR(T, register, value);
        }
    };
}

fn DebugAddressRegister(comptime register: enum { DR0, DR1, DR2, DR3 }) type {
    return struct {
        pub fn read() innigkeit.VirtualAddress {
            return switch (register) {
                .DR0 => .from(asm ("mov %%dr0, %[value]"
                    : [value] "=r" (-> u64),
                )),
                .DR1 => .from(asm ("mov %%dr1, %[value]"
                    : [value] "=r" (-> u64),
                )),
                .DR2 => .from(asm ("mov %%dr2, %[value]"
                    : [value] "=r" (-> u64),
                )),
                .DR3 => .from(asm ("mov %%dr3, %[value]"
                    : [value] "=r" (-> u64),
                )),
            };
        }

        pub fn write(address: innigkeit.VirtualAddress) void {
            switch (register) {
                .DR0 => asm volatile ("mov %[address], %%dr0"
                    :
                    : [address] "r" (address.value),
                ),
                .DR1 => asm volatile ("mov %[address], %%dr1"
                    :
                    : [address] "r" (address.value),
                ),
                .DR2 => asm volatile ("mov %[address], %%dr2"
                    :
                    : [address] "r" (address.value),
                ),
                .DR3 => asm volatile ("mov %[address], %%dr3"
                    :
                    : [address] "r" (address.value),
                ),
            }
        }
    };
}
