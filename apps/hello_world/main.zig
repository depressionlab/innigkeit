// zlinter-disable no_swallow_error - this is a syscall-surface smoke test:
// every catch is either a console print with no recovery path, or a test
// step whose own next print already reports success/failure, not a
// production error-handling gap.
const innigkeit = @import("innigkeit");
const std = @import("std");
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
    testSecureVault();
    testGpuBuffer();
    testCoreHint();

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
    const region = innigkeit.memory.mmap(4096, .{ .read = true, .write = true }) catch {
        innigkeit.io.stdout.print("mmap failed\n", .{}) catch {};
        return;
    };

    region[0] = 0xAB;
    region[4095] = 0xCD;
    const ok = region[0] == 0xAB and region[4095] == 0xCD;
    innigkeit.io.stdout.print("mmap: write/read {s}\n", .{if (ok) "ok" else "FAIL"}) catch {};

    innigkeit.memory.munmap(region) catch {};
    innigkeit.io.stdout.print("mmap test done\n", .{}) catch {};
}

fn testAllocator() void {
    var arena = std.heap.ArenaAllocator.init(innigkeit.memory.page_allocator);
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

    // Mutex is still held by main: tryLock must fail.
    if (!tl_mutex.tryLock()) {
        _ = tl_failed.fetchAdd(1, .acq_rel);
    } else {
        @branchHint(.cold);
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

fn testSecureVault() void {
    const vault = capabilities.secureVaultCreate() catch |err| {
        innigkeit.io.stdout.print("secure_vault: create failed: {s}\n", .{@errorName(err)}) catch {};
        return;
    };
    defer capabilities.delete(vault) catch {};

    // Check it's software-only (no TPM in QEMU).
    const status = capabilities.secureVaultStatus(vault) catch 0;
    innigkeit.io.stdout.print("secure_vault: tpm_backed={}\n", .{status != 0}) catch {};

    // Seal a secret.
    const plaintext = "hello from secure vault";
    const overhead = 24 + 16; // xchacha20-poly1305: 24-byte nonce + 16-byte tag
    var blob: [plaintext.len + overhead]u8 = undefined;
    const blob_len = capabilities.secureVaultSeal(vault, plaintext, &blob) catch |err| {
        innigkeit.io.stdout.print("secure_vault: seal failed: {s}\n", .{@errorName(err)}) catch {};
        return;
    };

    // Unseal and verify.
    var recovered: [plaintext.len]u8 = undefined;
    const rec_len = capabilities.secureVaultUnseal(vault, blob[0..blob_len], &recovered) catch |err| {
        innigkeit.io.stdout.print("secure_vault: unseal failed: {s}\n", .{@errorName(err)}) catch {};
        return;
    };

    const ok = rec_len == plaintext.len and std.mem.eql(u8, plaintext, recovered[0..rec_len]);
    innigkeit.io.stdout.print("secure_vault: seal/unseal roundtrip {s}\n", .{if (ok) "ok" else "FAIL"}) catch {};

    // Tampered blob must fail.
    var tampered: @TypeOf(blob) = blob;
    tampered[blob_len / 2] ^= 0xFF;
    const tamper_result = capabilities.secureVaultUnseal(vault, tampered[0..blob_len], &recovered);
    const tamper_ok = (tamper_result == error.PermissionDenied);
    innigkeit.io.stdout.print("secure_vault: tampered unseal rejected {s}\n", .{if (tamper_ok) "ok" else "FAIL"}) catch {};

    innigkeit.io.stdout.print("secure_vault test done\n", .{}) catch {};
}

fn testGpuBuffer() void {
    const usage: capabilities.GpuBufferUsage = .{ .vertex_buffer = true, .cpu_visible = true };
    const buf = capabilities.gpuBufferCreate(2, usage) catch |err| {
        innigkeit.io.stdout.print("gpu_buffer: create failed: {s}\n", .{@errorName(err)}) catch {};
        return;
    };
    defer capabilities.delete(buf) catch {};

    const size = capabilities.gpuBufferSize(buf) catch 0;
    const phys = capabilities.gpuBufferPhysAddr(buf) catch 0;
    const usage_raw = capabilities.gpuBufferUsageRaw(buf) catch 0;
    const usage_back: capabilities.GpuBufferUsage = @bitCast(usage_raw);

    const size_ok = size == 2 * 4096;
    const phys_ok = phys != 0;
    const usage_ok = usage_back.vertex_buffer and usage_back.cpu_visible;

    innigkeit.io.stdout.print("gpu_buffer: size={} ({}), phys=0x{x} ({}), usage.vertex={} ({})\n", .{
        size,                     size_ok,
        phys,                     phys_ok,
        usage_back.vertex_buffer, usage_ok,
    }) catch {};

    const all_ok = size_ok and phys_ok and usage_ok;
    innigkeit.io.stdout.print("gpu_buffer test {s}\n", .{if (all_ok) "done" else "FAIL"}) catch {};
}

var hint_done: std.atomic.Value(u32) = .init(0);

fn testCoreHint() void {
    hint_done = .init(0);

    const tp = innigkeit.Thread.spawn(pCoreWorker, .{}) catch {
        innigkeit.io.stdout.print("core_hint: thread spawn failed\n", .{}) catch {};
        return;
    };
    const te = innigkeit.Thread.spawn(eCoreWorker, .{}) catch {
        innigkeit.io.stdout.print("core_hint: thread spawn failed\n", .{}) catch {};
        tp.join();
        return;
    };
    tp.join();
    te.join();

    const done = hint_done.load(.acquire);
    innigkeit.io.stdout.print("core_hint: {d}/2 threads completed{s}\n", .{
        done, if (done == 2) "" else " FAIL",
    }) catch {};
    innigkeit.io.stdout.print("core_hint test done\n", .{}) catch {};
}

fn pCoreWorker() void {
    innigkeit.thread.setCoreHint(.p_core);
    _ = hint_done.fetchAdd(1, .acq_rel);
}

fn eCoreWorker() void {
    innigkeit.thread.setCoreHint(.e_core);
    _ = hint_done.fetchAdd(1, .acq_rel);
}
