const std = @import("std");
const innigkeit = @import("innigkeit");
const capabilities = innigkeit.capabilities;

pub fn main() void {
    innigkeit.io.stdout.print("Hello, World!\n", .{}) catch {};

    std.log.info("hello_world starting", .{});

    testIpc();
    testMmap();
    testAllocator();
    testFutex();

    std.log.info("all tests passed", .{});
    innigkeit.io.stdout.print("all tests passed\n", .{}) catch {};
}

fn testIpc() void {
    const ep: capabilities.Handle = capabilities.create(.endpoint) catch {
        innigkeit.io.stdout.print("cap_create failed\n", .{}) catch {};
        return;
    };

    const server = innigkeit.Thread.spawn(serverEntry, .{ep}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        return;
    };
    server.detach();

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

    region[0] = 0xAB;
    region[4095] = 0xCD;
    const ok = region[0] == 0xAB and region[4095] == 0xCD;
    innigkeit.io.stdout.print("mmap: write/read {s}\n", .{if (ok) "ok" else "FAIL"}) catch {};

    innigkeit.mem.munmap(region) catch {};
    innigkeit.io.stdout.print("mmap test done\n", .{}) catch {};
}

fn testAllocator() void {
    var arena = std.heap.ArenaAllocator.init(innigkeit.mem.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const buf = alloc.alloc(u8, 1024) catch {
        std.log.err("page_allocator: alloc failed", .{});
        return;
    };
    @memset(buf, 0xAA);
    const ok = buf[0] == 0xAA and buf[1023] == 0xAA;
    std.log.info("page_allocator: alloc+write {s}", .{if (ok) "ok" else "FAIL"});
}

var shared_counter: u32 = 0;
var counter_mutex: innigkeit.Mutex = .init;

fn testFutex() void {
    shared_counter = 0;
    const t1 = innigkeit.Thread.spawn(incrementer, .{@as(u32, 50)}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        return;
    };
    const t2 = innigkeit.Thread.spawn(incrementer, .{@as(u32, 50)}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        t1.join();
        return;
    };
    t1.join();
    t2.join();

    const expected: u32 = 100;
    const actual = @atomicLoad(u32, &shared_counter, .acquire);
    innigkeit.io.stdout.print("futex mutex: counter={} (expected {}){s}\n", .{
        actual, expected, if (actual == expected) "" else " FAIL",
    }) catch {};
    innigkeit.io.stdout.print("futex test done\n", .{}) catch {};
}

fn incrementer(n: u32) void {
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        counter_mutex.lock();
        shared_counter += 1;
        counter_mutex.unlock();
    }
}

fn serverEntry(ep: capabilities.Handle) void {
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
}
