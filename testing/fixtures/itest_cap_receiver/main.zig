const innigkeit = @import("innigkeit");
const capabilities = innigkeit.capabilities;

/// Granted at spawn time: handle 0 is a read-only Endpoint shared with
/// `itest_cap_sender`. The Notify this fixture signals below is never
/// granted directly: it only exists in this process's capability table
/// because `endpointRecv` copied it in from the sender's transferred
/// handle, proving IPC-mediated capability delegation actually works end
/// to end, not just that a handle number round-trips.
const endpoint_handle: capabilities.Handle = @enumFromInt(0);

pub fn main() void {
    var msg: capabilities.Message = undefined;
    capabilities.endpointRecv(endpoint_handle, &msg) catch @panic("endpointRecv failed");

    if (msg.caps[0] == 0) @panic("sender did not transfer a capability");
    const notify_handle: capabilities.Handle = @enumFromInt(msg.caps[0]);

    // Bit 0 = signaled, bits 8..15 = a magic payload byte the kernel test
    // checks to confirm this signal reached the *same* Notify object the
    // kernel itself is still holding a reference to, not a coincidentally
    // matching handle number.
    capabilities.notifySignal(notify_handle, 0x1 | (@as(u64, 0xAB) << 8)) catch
        @panic("notifySignal on the transferred capability failed");

    innigkeit.process.exit(66);
}
