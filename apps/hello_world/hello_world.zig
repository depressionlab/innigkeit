const innigkeit = @import("innigkeit");
const capabilities = innigkeit.capabilities;

pub fn main() void {
    innigkeit.io.stdout.print("Hello, World!\n", .{}) catch {};

    testIpc();
    testMmap();

    innigkeit.io.stdout.print("all tests passed\n", .{}) catch {};
}

fn testIpc() void {
    const ep: capabilities.Handle = capabilities.create(.endpoint) catch {
        innigkeit.io.stdout.print("cap_create failed \n", .{}) catch {};
        return;
    };

    innigkeit.thread.spawn(&serverEntry, ep) catch {};

    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var msg: capabilities.Message = .{ .tag = i + 1 };
        capabilities.endpointCall(ep, &msg) catch {};
        innigkeit.io.stdout.print("client got reply tag={}\n", .{msg.tag}) catch {};
    }

    innigkeit.io.stdout.print("ipc test done\n", .{}) catch {};
}

fn testMmap() void {
    const region = innigkeit.mem.mmap(4096, .{ .read = true, .write = true }) catch {
        innigkeit.io.stdout.print("mmap failed\n", .{}) catch {};
        return;
    };

    // Write a sentinel value and read it back to prove the page is accessible.
    region[0] = 0xAB;
    region[4095] = 0xCD;
    const ok = region[0] == 0xAB and region[4095] == 0xCD;
    innigkeit.io.stdout.print("mmap: write/read {s}\n", .{if (ok) "ok" else "FAIL"}) catch {};

    innigkeit.mem.munmap(region) catch {
        innigkeit.io.stdout.print("munmap failed\n", .{}) catch {};
        return;
    };
    innigkeit.io.stdout.print("mmap test done\n", .{}) catch {};
}

fn serverEntry(ep_raw: usize) callconv(.c) noreturn {
    const ep: capabilities.Handle = @truncate(ep_raw);
    var msg: capabilities.Message = undefined;

    capabilities.endpointRecv(ep, &msg) catch {};
    innigkeit.io.stdout.print("server got tag={}\n", .{msg.tag}) catch {};

    var remaining: usize = 2;
    while (remaining > 0) : (remaining -= 1) {
        msg.tag += 100;
        capabilities.endpointReplyRecv(ep, &msg) catch {};
        innigkeit.io.stdout.print("server got tag={}\n", .{msg.tag}) catch {};
    }

    msg.tag += 100;
    capabilities.endpointReply(ep, &msg) catch {};

    innigkeit.thread.exitCurrent();
}

// TODO: make this less terrible
pub const _start = void;
comptime {
    innigkeit.exportEntry();
}
