//! This module contains the definitions of the Limine protocol as of commit hash
//! `630686a3dd3ce40f9e510a7dd9fea6b4c60d952e`.
//!
//! https://github.com/Limine-Bootloader/limine-protocol/blob/630686a3dd3ce40f9e510a7dd9fea6b4c60d952e/PROTOCOL.md

const std = @import("std");

pub const BaseRevison = @import("BaseRevision.zig").BaseRevison;
pub const File = @import("File.zig").File;
pub const BootloaderInfo = @import("BootloaderInfo.zig");
pub const BootloaderPerformance = @import("BootloaderPerformance.zig");
pub const BSPHartID = @import("BSPHartID.zig");
pub const DateAtBoot = @import("DateAtBoot.zig");
pub const DeviceTreeBlob = @import("DeviceTreeBlob.zig");
pub const EFIMemoryMap = @import("EFIMemoryMap.zig");
pub const EFISystemTable = @import("EFISystemTable.zig");
pub const EntryPoint = @import("EntryPoint.zig");
pub const ExecutableAddress = @import("ExecutableAddress.zig");
pub const ExecutableCommandline = @import("ExecutableCommandline.zig");
pub const ExecutableFile = @import("ExecutableFile.zig");
pub const FirmwareType = @import("FirmwareType.zig");
pub const FlantermFramebuffer = @import("FlantermFramebuffer.zig");
pub const Framebuffer = @import("Framebuffer.zig");
pub const HHDM = @import("HHDM.zig");
pub const KeepIOMMU = @import("KeepIOMMU.zig");
pub const MemoryMap = @import("MemoryMap.zig");
pub const Module = @import("Module.zig");
pub const MP = @import("MP.zig");
pub const PagingMode = @import("PagingMode.zig");
pub const RequestDelimiters = @import("RequestDelimiters.zig");
pub const RSDP = @import("RSDP.zig");
pub const SMBIOS = @import("SMBIOS.zig");
pub const StackSize = @import("StackSize.zig");
pub const TPMEventLog = @import("TPMEventLog.zig");
pub const TSCFrequency = @import("TSCFrequency.zig");

/// Generates a Limine protocol request identifier.
pub fn id(a: u64, b: u64) [4]u64 {
    return .{ 0xC7B1DD30DF4C8B88, 0x0A82E883A194F07B, a, b };
}

const Arch = enum {
    aarch64,
    loongarch64,
    riscv64,
    x86_64,
};

pub const arch: Arch = switch (@import("builtin").cpu.arch) {
    .aarch64 => .aarch64,
    .loongarch64 => .loongarch64,
    .riscv64 => .riscv64,
    .x86_64 => .x86_64,
    else => |e| @compileError("unsupported architecture " ++ @tagName(e)),
};

comptime {
    std.testing.refAllDecls(@This());
}
