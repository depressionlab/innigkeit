//! The debug console extension defines a generic mechanism for debugging and boot-time early prints from
//! supervisor-mode software.
//!
//! This extension replaces the legacy console putchar (EID #0x01) and console getchar (EID #0x02) extensions.
//!
//! The debug console extension allows supervisor-mode software to write or read multiple bytes in a single SBI call.
//!
//! If the underlying physical console has extra bits for error checking (or correction) then these extra bits should be
//! handled by the SBI implementation.
//!
//! Note: It is recommended that bytes sent/received using the debug console extension follow UTF-8 character encoding.
const base = @import("base.zig");
const ecall = @import("ecall.zig");

pub fn available() bool {
    return base.probeExtension(.DBCN);
}

pub const WriteError = error{
    /// The memory pointed to by the `num_bytes` and `base_address parameters does not satisfy the requirements.
    InvalidParameter,

    /// Writes to the debug console is not allowed.
    Denied,

    /// Failed to write due to I/O errors.
    Failed,
};

/// Write bytes to the debug console from input memory.
///
/// The `num_bytes` parameter specifies the number of bytes in the input memory.
///
/// This is a non-blocking SBI call and it may do partial/no writes if the debug console is not able to accept more
/// bytes.
///
/// Returns the number of bytes written to the debug console.
///
/// Available from SBI v2.0.
pub fn write(base_address: BaseAddress, num_bytes: usize) WriteError!usize {
    return @bitCast(try ecall.threeArgsWithReturnWithError(
        .DBCN,
        @backingInt(DBCN_FID.CONSOLE_WRITE),
        @bitCast(num_bytes),
        @bitCast(base_address.physical_address_low),
        @bitCast(base_address.physical_address_high),
        WriteError,
    ));
}

pub const ReadError = error{
    /// The memory pointed to by the `num_bytes` and `base_address parameters does not satisfy the requirements.
    InvalidParameter,

    /// Reads from the debug console is not allowed.
    Denied,

    /// Failed to read due to I/O errors.
    Failed,
};

/// Read bytes from the debug console into an output memory.
///
/// The `num_bytes` parameter specifies the maximum number of bytes which can be written into the output memory.
///
/// This is a non-blocking SBI call and it will not write anything into the output memory if there are no bytes to
/// be read in the debug console.
///
/// Returns the number of bytes read from the debug console.
///
/// Available from SBI v2.0.
pub fn read(base_address: BaseAddress, num_bytes: usize) ReadError!usize {
    return @bitCast(try ecall.threeArgsWithReturnWithError(
        .DBCN,
        @backingInt(DBCN_FID.CONSOLE_READ),
        @bitCast(num_bytes),
        @bitCast(base_address.physical_address_low),
        @bitCast(base_address.physical_address_high),
        ReadError,
    ));
}

pub const WriteByteError = error{
    /// Write to the debug console is not allowed.
    Denied,

    /// Failed to write the byte due to I/O errors.
    Failed,
};

/// Write a single byte to the debug console.
///
/// This is a blocking SBI call and it will only return after writing the specified byte to the debug console.
///
/// Available from SBI v2.0.
pub fn writeByte(byte: u8) WriteByteError!void {
    try ecall.oneArgsNoReturnWithError(
        .DBCN,
        @backingInt(DBCN_FID.CONSOLE_WRITE_BYTE),
        byte,
        WriteByteError,
    );
}

pub const BaseAddress = struct {
    physical_address_low: usize,
    physical_address_high: usize,
};

const DBCN_FID = enum(i32) {
    CONSOLE_WRITE = 0x0,
    CONSOLE_READ = 0x1,
    CONSOLE_WRITE_BYTE = 0x2,
};
