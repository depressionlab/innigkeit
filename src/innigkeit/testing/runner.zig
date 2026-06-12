const builtin = @import("builtin");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.test_runner);

/// Run all collected test functions, returning the number of failures.
///
/// `error.SkipZigTest` follows standard Zig test semantics: the test is
/// reported as skipped and does not count as a failure (used e.g. by SMP
/// tests on single-executor configurations and disk tests without a boot
/// device).
pub fn runAll() u32 {
    const test_fns = builtin.test_functions;
    log.info("running {d} test(s)", .{test_fns.len});
    var failed: u32 = 0;
    var skipped: u32 = 0;
    for (test_fns) |t| {
        log.info("trying {s}", .{t.name});
        t.func() catch |err| {
            if (err == error.SkipZigTest) {
                log.info("skip  {s}", .{t.name});
                skipped += 1;
                continue;
            }
            log.err("FAIL  {s}: {}", .{ t.name, err });
            failed += 1;
            continue;
        };
        log.info("pass  {s}", .{t.name});
    }

    if (failed == 0) {
        if (skipped == 0) {
            log.info("ALL {d} TEST(S) PASSED", .{test_fns.len});
        } else {
            log.info("ALL {d} TEST(S) PASSED ({d} skipped)", .{ test_fns.len, skipped });
        }
    } else {
        log.err("{d}/{d} TEST(S) FAILED ({d} skipped)", .{ failed, test_fns.len, skipped });
    }

    return failed;
}
