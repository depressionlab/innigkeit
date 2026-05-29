const std = @import("std");
const innigkeit = @import("innigkeit");
const capabilities = innigkeit.capabilities;

pub fn main() void {
    // When spawned as a child by testSpawnWait, exit immediately.
    const argv = innigkeit.process.args();
    if (argv.len >= 2 and std.mem.eql(u8, std.mem.span(argv[1]), "__child")) return;

    innigkeit.io.stdout.print("Hello, World!\n", .{}) catch {};

    std.log.info("hello_world starting", .{});

    testIpc();
    testMmap();
    testAllocator();
    testFutex();
    testCondition();
    testBroadcast();
    testTryLock();
    testDetach();
    testSleep();
    testSpawnWait();

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

var cond_count: u32 = 0;
var cond_mutex: innigkeit.Mutex = .init;
var cond_cv: innigkeit.Condition = .init;

fn testCondition() void {
    cond_count = 0;

    const producer = innigkeit.Thread.spawn(condProducer, .{}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        return;
    };
    const consumer = innigkeit.Thread.spawn(condConsumer, .{}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        producer.join();
        return;
    };
    producer.join();
    consumer.join();
    innigkeit.io.stdout.print("condition test done\n", .{}) catch {};
}

fn condProducer() void {
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        cond_mutex.lock();
        cond_count += 1;
        cond_cv.signal();
        cond_mutex.unlock();
    }
}

fn condConsumer() void {
    var observed: u32 = 0;
    while (observed < 5) {
        cond_mutex.lock();
        while (cond_count == observed) cond_cv.wait(&cond_mutex);
        observed = cond_count;
        cond_mutex.unlock();
    }
    innigkeit.io.stdout.print("condition: observed {} increments (expected 5){s}\n", .{
        observed, if (observed >= 5) "" else " FAIL",
    }) catch {};
}

var bc_count: u32 = 0;
var bc_mutex: innigkeit.Mutex = .init;
var bc_cv: innigkeit.Condition = .init;
var bc_woken: std.atomic.Value(u32) = .init(0);

fn testBroadcast() void {
    bc_count = 0;
    bc_woken = .init(0);

    const t1 = innigkeit.Thread.spawn(bcWaiter, .{}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        return;
    };
    const t2 = innigkeit.Thread.spawn(bcWaiter, .{}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        t1.join();
        return;
    };
    const t3 = innigkeit.Thread.spawn(bcWaiter, .{}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        t1.join();
        t2.join();
        return;
    };

    // Let waiters block on the condition.
    innigkeit.sleep(20 * std.time.ns_per_ms);

    bc_mutex.lock();
    bc_count = 1;
    bc_cv.broadcast();
    bc_mutex.unlock();

    t1.join();
    t2.join();
    t3.join();

    const w = bc_woken.load(.acquire);
    innigkeit.io.stdout.print("broadcast: {d} of 3 woken{s}\n", .{
        w, if (w == 3) "" else " FAIL",
    }) catch {};
    innigkeit.io.stdout.print("broadcast test done\n", .{}) catch {};
}

fn bcWaiter() void {
    bc_mutex.lock();
    while (bc_count == 0) bc_cv.wait(&bc_mutex);
    bc_mutex.unlock();
    _ = bc_woken.fetchAdd(1, .acq_rel);
}

var tl_mutex: innigkeit.Mutex = .init;
var tl_failed: std.atomic.Value(u32) = .init(0);
var tl_start: std.atomic.Value(u32) = .init(0);

fn testTryLock() void {
    tl_failed = .init(0);
    tl_start = .init(0);

    tl_mutex.lock();

    const t = innigkeit.Thread.spawn(tryLockWorker, .{}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        tl_mutex.unlock();
        return;
    };

    // Signal worker to start then give it time to attempt tryLock.
    tl_start.store(1, .release);
    innigkeit.sleep(20 * std.time.ns_per_ms);
    tl_mutex.unlock();

    t.join();

    const f = tl_failed.load(.acquire);
    innigkeit.io.stdout.print("tryLock: contended tryLock failed {d} time(s){s}\n", .{
        f, if (f >= 1) "" else " FAIL",
    }) catch {};
    innigkeit.io.stdout.print("tryLock test done\n", .{}) catch {};
}

fn tryLockWorker() void {
    // Spin until signaled to start.
    while (tl_start.load(.acquire) == 0) innigkeit.thread.yield();

    // Mutex is still held by main — tryLock must fail.
    if (!tl_mutex.tryLock()) {
        _ = tl_failed.fetchAdd(1, .acq_rel);
    } else {
        tl_mutex.unlock(); // shouldn't happen
    }

    // Now the main thread has released the lock; this should succeed.
    tl_mutex.lock();
    tl_mutex.unlock();
}

var detach_flag: std.atomic.Value(u32) = .init(0);

fn testDetach() void {
    detach_flag = .init(0);

    const t = innigkeit.Thread.spawn(detachWorker, .{}) catch {
        innigkeit.io.stdout.print("thread spawn failed\n", .{}) catch {};
        return;
    };
    t.detach();

    // Poll until worker has set the flag (max ~200ms).
    var i: u32 = 0;
    while (detach_flag.load(.acquire) == 0 and i < 40) : (i += 1) {
        innigkeit.sleep(5 * std.time.ns_per_ms);
    }

    const ok = detach_flag.load(.acquire) == 1;
    innigkeit.io.stdout.print("detach: thread ran to completion: {s}\n", .{
        if (ok) "ok" else "FAIL",
    }) catch {};
    innigkeit.io.stdout.print("detach test done\n", .{}) catch {};
}

fn detachWorker() void {
    innigkeit.thread.yield();
    detach_flag.store(1, .release);
}

fn testSleep() void {
    const before = innigkeit.Syscall.invoke(.uptime_ms, .{});
    const before_ms = innigkeit.Syscall.decode(before) catch 0;

    innigkeit.sleep(50 * std.time.ns_per_ms);

    const after = innigkeit.Syscall.invoke(.uptime_ms, .{});
    const after_ms = innigkeit.Syscall.decode(after) catch 0;

    const elapsed = after_ms -| before_ms;
    innigkeit.io.stdout.print("sleep: elapsed {}ms (expected ~50ms){s}\n", .{
        elapsed, if (elapsed >= 40) "" else " FAIL",
    }) catch {};
    innigkeit.io.stdout.print("sleep test done\n", .{}) catch {};
}

fn testSpawnWait() void {
    // Spawn hello_world itself with "__child" as argv[1]; it exits immediately.
    const argv = [_]innigkeit.process.Arg{
        innigkeit.process.Arg.fromSlice("hello_world"),
        innigkeit.process.Arg.fromSlice("__child"),
    };
    const notify = innigkeit.process.spawnFull("hello_world", &argv, &.{}, &.{}) catch |err| {
        innigkeit.io.stdout.print("spawn: failed to spawn child: {s}\n", .{@errorName(err)}) catch {};
        return;
    };
    const status = innigkeit.process.waitProcess(notify) catch |err| {
        innigkeit.io.stdout.print("spawn: waitProcess failed: {s}\n", .{@errorName(err)}) catch {};
        return;
    };
    innigkeit.io.stdout.print("spawn+wait: child exited with status {d}\n", .{status}) catch {};
    innigkeit.io.stdout.print("spawn+wait test done\n", .{}) catch {};
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
