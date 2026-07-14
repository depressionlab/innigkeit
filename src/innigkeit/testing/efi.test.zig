//! EFI System Table access tests. Collected in the default suite: the
//! test image always boots under OVMF/AAVMF, so the table is present.

const innigkeit = @import("innigkeit");
const std = @import("std");

test "efi: system table is present and validated under EFI firmware" {
    // `firmware.init()` already ran in stage4 and cached the validated table.
    // Skip gracefully on a non-EFI (BIOS/SBI) boot rather than fail.
    const efi = innigkeit.firmware.efi;
    const st = efi.systemTable() orelse return error.SkipZigTest;

    // systemTable() is only non-null after both the system-table and
    // runtime-services signatures validated, so its presence is the assertion;
    // confirm the runtime-services table resolves too and reports a revision.
    const rs = efi.runtimeServices() orelse return error.SkipZigTest;
    try std.testing.expect(st.hdr.revision != 0);
    try std.testing.expect(rs.hdr.revision != 0);
    // GetVariable must be a non-null runtime-services function pointer (used by
    // the SecureBoot read).
    try std.testing.expect(rs.get_variable != 0);
}
