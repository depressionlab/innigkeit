const PageFaultDetails = @This();

const std = @import("std");
const innigkeit = @import("innigkeit");

faulting_address: innigkeit.VirtualAddress,
access_type: AccessType,
fault_type: FaultType,

/// The context that the fault was triggered from.
///
/// This is not necessarily the same as the context of the task that triggered the fault as a user task may have
/// triggered the fault while running in kernelspace.
faulting_context: FaultingContext,

pub const FaultingContext = union(innigkeit.Context.Type) {
    kernel: struct {
        access_to_user_memory_enabled: bool,
    },
    user,
};

pub const AccessType = enum {
    read,
    write,
    execute,
};

pub const FaultType = enum {
    /// Either the page was not present or the mapping is invalid.
    invalid,

    /// The access was not permitted by the page protection.
    protection,
};

pub fn print(details: PageFaultDetails, writer: *std.Io.Writer, indent: usize) !void {
    const new_indent = indent + 2;

    try writer.writeAll("PageFaultDetails{\n");

    try writer.splatByteAll(' ', new_indent);
    try writer.print("faulting_address: {f},\n", .{details.faulting_address});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("access_type: {t},\n", .{details.access_type});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("fault_type: {t},\n", .{details.fault_type});

    try writer.splatByteAll(' ', new_indent);
    try writer.print("faulting_context: {t},\n", .{details.faulting_context});

    try writer.splatByteAll(' ', indent);
    try writer.writeByte('}');
}

pub inline fn format(
    details: PageFaultDetails,
    writer: *std.Io.Writer,
) !void {
    return details.print(writer, 0);
}
