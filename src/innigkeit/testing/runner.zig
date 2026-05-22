const builtin = @import("builtin");
const innigkeit = @import("innigkeit");
const log = innigkeit.debug.log.scoped(.test_runner);

/// Run all collected test functions, returning the number of failures.
pub fn runAll() u32 {
    const test_fns = builtin.test_functions;
    log.info("running {d} test(s)", .{test_fns.len});
    var failed: u32 = 0;
    for (test_fns) |t| {
        log.info("trying {s}", .{t.name});
        t.func() catch |err| {
            log.err("FAIL  {s}: {}", .{ t.name, err });
            failed += 1;
            continue;
        };
        log.info("pass  {s}", .{t.name});
    }

    if (failed == 0) {
        log.info("ALL {d} TEST(S) PASSED", .{test_fns.len});
    } else {
        log.err("{d}/{d} TEST(S) FAILED", .{ failed, test_fns.len });
    }

    return failed;
}
