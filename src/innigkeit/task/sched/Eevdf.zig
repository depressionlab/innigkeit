//! EEVDF (Earliest Eligible Virtual Deadline First) scheduling class.
//!
//! Implements the algorithm described in:
//!   Stoica & Abdel-Wahab 1995, "Earliest Eligible Virtual Deadline First"
//! and as deployed in Linux 6.6+ (`kernel/sched/eevdf.c`).
//!
//! - https://en.wikipedia.org/wiki/Earliest_eligible_virtual_deadline_first_scheduling
//! - https://github.com/torvalds/linux/blob/master/Documentation/scheduler/sched-eevdf.rst
//! - https://web.archive.org/web/20251230112235/https://citeseerx.ist.psu.edu/document?repid=rep1&type=pdf&doi=805acf7726282721504c8f00575d91ebfd750564
//!
//! Augmentation O(log n) fixup
//! ---------------------------
//! After `tree.put` we walk from the inserted leaf up to the root via
//! `fixupAugmentationUp`, stopping early when a node's value is stable.
//! The leaf is initialised to `se.vruntime` (correct for a zero-child node),
//! so each ancestor only needs to take the min of its own vruntime and its
//! children's cached values.
//!
//! Conservative invariant after insert:
//!   se.subtree_min_vruntime <= true_min(se's subtree)
//!
//! This holds because `tree.put` rotations can only move nodes DOWN (away from
//! the root), and a node's old subtree always CONTAINED its new subtree. The
//! rotated-up node is always on the walk-up path and gets its smin recomputed
//! from (stale-small) children, giving a stale-small or exact result.
//!
//! Why not O(log n) for REMOVE:
//!   `tree.remove` calls `rebalanceAfterRemove` which can rotate a node UP
//!   inside the promoted node's subtree. That newly-promoted node gains
//!   descendants it didn't have before, so its smin (reflecting the old smaller
//!   subtree) can be LARGER than the new true minimum. `fixupAugmentationUp`
//!   from the promoted node starts at the top of that subtree and cannot see
//!   inside it — the stale-high value persists, causing `pickBest` to
//!   incorrectly prune that subtree and never schedule eligible tasks (hang).
//!   We therefore use a full O(n) `recomputeSubtreeMin` after every remove.
//!   For <=32 tasks per CPU this is negligible.
//!
//! Virtual time model
//! ------------------
//! Each task has a weight derived from its nice level.
//! Virtual time for task i advances at rate NICE_0_WEIGHT / weight_i.
//!
//! Heavy tasks (high weight) have virtual time advance slowly, earning more real CPU time.
//!
//! A task is *eligible* if its vruntime <= the weighted average vruntime of all
//! runnable tasks (i.e. it has been underserved relative to its fair share).
//!
//! Among eligible tasks, we pick the one with the earliest virtual deadline:
//!   `deadline = vruntime_at_enqueue + slice * NICE_0_WEIGHT / weight`
//!
//! This gives strong latency guarantees while maintaining fairness.
//!
//! Data structures
//! ---------------
//! Tasks are kept in an augmented red-black tree sorted by deadline. Each node
//! caches the minimum vruntime in its subtree (`subtree_min_vruntime`), allowing
//! `pickBest()` to prune ineligible subtrees and select the best eligible task
//! in O(log n). Insert uses O(log n) walk-up; remove uses O(n) full recompute
//! (see "Augmentation O(log n) fixup" above for why remove cannot be O(log n)
//! without augmentation callbacks in the RbTree rotation code).

const std = @import("std");
const innigkeit = @import("innigkeit");
const core = @import("core");
const Runqueue = @import("../Runqueue.zig");
const SchedClass = @import("../SchedClass.zig");
const RbTree = core.containers.RedBlackTree;
const wallclock = innigkeit.time.wallclock;

const log = innigkeit.debug.log.scoped(.eevdf);

/// sched_prio_to_weight[nice + 20], matching Linux exactly.
pub const weight_table: [40]u32 = .{
    88761, 71755, 56483, 46273, 36291,
    29154, 23254, 18705, 14949, 11916,
    9548,  7620,  6100,  4904,  3906,
    3121,  2501,  1991,  1586,  1277,
    1024,  820,   655,   526,   423,
    335,   272,   215,   172,   137,
    110,   87,    70,    56,    45,
    36,    29,    23,    18,    15,
};

pub const nice_0_weight: u32 = weight_table[20]; // 1024

/// Default time slice in nanoseconds (3 ms).
pub const default_slice_ns: u64 = 3_000_000;

pub const SchedEntity = struct {
    /// Scheduling weight derived from nice value.
    /// Default: nice 0 = 1024.
    weight: u32 = nice_0_weight,

    /// Virtual runtime in nanoseconds scaled by NICE_0_WEIGHT / weight.
    /// Tracks how much "fair" service this task has received.
    vruntime: u64 = 0,

    /// Virtual deadline: vruntime_at_enqueue + slice * NICE_0_WEIGHT / weight.
    /// Primary sort key in the run-queue tree.
    deadline: u64 = 0,

    /// Current time slice in real nanoseconds.
    slice: u64 = default_slice_ns,

    /// Wallclock tick when the task last started executing.
    exec_start: wallclock.Tick = .zero,

    /// Total real CPU time consumed in nanoseconds.
    sum_exec_runtime: u64 = 0,

    /// Approximated scheduling lag (positive = underserved, negative = overserved).
    vlag: i64 = 0,

    /// Whether this entity is currently on a run queue.
    on_rq: bool = false,

    /// User has set a custom slice via capability; don't override on deadline renewal.
    custom_slice: bool = false,

    // Utilization tracking (PELT-lite)

    /// Exponentially weighted moving average of CPU utilization.
    /// Range [0, NICE_0_WEIGHT].
    ///
    /// Updated every ~32 ms window.
    util_avg: u32 = 0,

    /// Value of sum_exec_runtime at the start of the current util window.
    /// CPU time in the window = sum_exec_runtime - util_runtime_at_window_start.
    util_runtime_at_window_start: u64 = 0,

    /// Wallclock tick when util tracking was last reset.
    util_window_start: wallclock.Tick = .zero,

    /// Embedded node in the per-executor EEVDF red-black tree.
    rq_node: RbTree.Node = .{},

    /// Minimum vruntime in this node's subtree (including `self`).
    ///
    /// After insert: maintained exactly on the walk-up path; conservative
    /// (<=true_min) elsewhere. After remove: exact everywhere (full recompute).
    /// Used by `pickBest` to prune ineligible subtrees in O(log n).
    subtree_min_vruntime: u64 = 0,

    pub fn fromNode(node: *RbTree.Node) *SchedEntity {
        return @fieldParentPtr("rq_node", node);
    }

    pub fn task(se: *SchedEntity) *innigkeit.Task {
        return @fieldParentPtr("sched", se);
    }

    /// Map nice value [-20, 19] to weight table index [0, 39].
    pub fn weightForNice(nice: i8) u32 {
        const idx: usize = @intCast(@as(i32, nice) + 20);
        return weight_table[idx];
    }
};

/// A per-executor EEVDF run queue
pub const EevdfRunqueue = struct {
    /// Red-black tree of runnable tasks, keyed by virtual deadline.
    tree: RbTree = .{},

    /// Number of tasks currently in `tree` (excludes `curr`).
    nr_queued: u32 = 0,

    /// The task presently executing on this executor.
    /// Not in `tree` while running.
    curr: ?*innigkeit.Task = null,

    // Weighted-average vruntime accounting
    //
    // We maintain:
    //   sum_w_vruntime = Σ weight_i * (vruntime_i - zero_vruntime)
    //   sum_weight     = Σ weight_i
    //
    // The weighted average is  sum_w_vruntime / sum_weight + zero_vruntime.
    // A task is eligible iff its vruntime ≤ that average.
    //
    // zero_vruntime is periodically re-anchored to prevent i64 overflow.

    sum_w_vruntime: i64 = 0,
    sum_weight: u64 = 0,
    zero_vruntime: u64 = 0,

    /// Monotonically increasing lower bound on vruntime across all queued tasks.
    /// Updated after every enqueue/dequeue. Used as the placement floor for
    /// waking tasks (prevents a long-sleeping task from hogging the CPU on wakeup).
    min_vruntime: u64 = 0,

    fn seKey(self: *const EevdfRunqueue, se: *const SchedEntity) i64 {
        return @as(i64, @bitCast(se.vruntime)) -% @as(i64, @bitCast(self.zero_vruntime));
    }

    fn addToAvg(self: *EevdfRunqueue, se: *const SchedEntity) void {
        const key = self.seKey(se);
        const w: i64 = @intCast(se.weight);
        self.sum_w_vruntime += key *% w;
        self.sum_weight += se.weight;
    }

    fn removeFromAvg(self: *EevdfRunqueue, se: *const SchedEntity) void {
        const key = self.seKey(se);
        const w: i64 = @intCast(se.weight);
        self.sum_w_vruntime -= key *% w;
        self.sum_weight -= se.weight;
    }

    fn updateMinVruntime(self: *EevdfRunqueue) void {
        var candidate: u64 = if (self.curr) |c| c.sched.vruntime else std.math.maxInt(u64);
        if (self.tree.root) |root| {
            const se = SchedEntity.fromNode(root);
            candidate = @min(candidate, se.subtree_min_vruntime);
        }
        if (candidate != std.math.maxInt(u64) and candidate > self.min_vruntime) {
            self.min_vruntime = candidate;
        }
    }

    /// Eligibility check: is se's vruntime <= weighted average?
    ///
    /// lag_i ≥ 0  <->  V >= v_i
    /// Using the exact Linux formula to avoid loss-of-precision from division:
    ///   eligible  <->  avg >= key * load
    /// where avg = sum_w_vruntime (+ curr contribution), load = sum_weight.
    fn vruntimeEligible(self: *const EevdfRunqueue, vruntime: u64) bool {
        var avg: i128 = self.sum_w_vruntime;
        var load: i128 = @intCast(self.sum_weight);

        // Include the currently-running task in the average.
        if (self.curr) |c| {
            const ckey: i64 = @as(i64, @bitCast(c.sched.vruntime)) -% @as(i64, @bitCast(self.zero_vruntime));
            const cw: i64 = @intCast(c.sched.weight);
            avg += @as(i128, ckey) * @as(i128, cw);
            load += c.sched.weight;
        }

        if (load == 0) return true; // empty queue; trivially eligible

        const key: i64 = @as(i64, @bitCast(vruntime)) -% @as(i64, @bitCast(self.zero_vruntime));
        return avg >= @as(i128, key) * load;
    }

    fn entityEligible(self: *const EevdfRunqueue, se: *const SchedEntity) bool {
        return self.vruntimeEligible(se.vruntime);
    }

    /// Tree comparator
    fn deadlineCmp(a_node: *const RbTree.Node, b_node: *const RbTree.Node) std.math.Order {
        const a = SchedEntity.fromNode(@constCast(a_node));
        const b = SchedEntity.fromNode(@constCast(b_node));
        if (a.deadline < b.deadline) return .lt;
        if (a.deadline > b.deadline) return .gt;
        // Tiebreak by task pointer for stable ordering.
        const ap = @intFromPtr(a.task());
        const bp = @intFromPtr(b.task());
        return std.math.order(ap, bp);
    }

    /// Core pick algorithm.
    ///
    /// Select the next task. Returns null if the queue is empty.
    /// May return `prev` to signal "keep running the current task".
    pub fn pickNext(self: *EevdfRunqueue, prev: ?*innigkeit.Task) ?*innigkeit.Task {
        if (self.nr_queued == 0) {
            // Only curr (if any) is available.
            return self.curr;
        }

        const best_queued = self.pickEevdf();

        const best: ?*innigkeit.Task = blk: {
            const curr = self.curr orelse break :blk best_queued;
            // If curr is eligible and has an earlier deadline than the best queued
            // task, keep running curr.
            if (self.entityEligible(&curr.sched)) {
                if (best_queued == null or curr.sched.deadline <= best_queued.?.sched.deadline) {
                    break :blk curr;
                }
            }
            break :blk best_queued;
        };

        _ = prev;
        return best;
    }

    /// Find the eligible task with the earliest virtual deadline.
    /// O(log n) via subtree_min_vruntime augmentation.
    fn pickEevdf(self: *EevdfRunqueue) ?*innigkeit.Task {
        return pickBest(self, self.tree.root);
    }
};

pub fn enqueue(rq: *Runqueue, task: *innigkeit.Task, flags: SchedClass.EnqueueFlags) void {
    const erq = &rq.eevdf;
    const se = &task.sched;

    std.debug.assert(!se.on_rq);

    placeEntity(erq, se, flags);

    erq.addToAvg(se);
    se.subtree_min_vruntime = se.vruntime; // initialize leaf before walk-up
    _ = erq.tree.put(EevdfRunqueue.deadlineCmp, &se.rq_node);
    fixupAugmentationUp(&se.rq_node);
    erq.nr_queued += 1;
    se.on_rq = true;
    erq.updateMinVruntime();

    if (core.is_debug) log.verbose("enqueue {f} vr={} dl={}", .{ task, se.vruntime, se.deadline });
}

pub fn dequeue(rq: *Runqueue, task: *innigkeit.Task, flags: SchedClass.DequeueFlags) void {
    const erq = &rq.eevdf;
    const se = &task.sched;

    std.debug.assert(se.on_rq);

    // Save the lag so wakeup placement is correct.
    se.vlag = lag(erq, se);

    erq.removeFromAvg(se);
    erq.tree.remove(&se.rq_node);
    _ = recomputeSubtreeMin(erq.tree.root);
    erq.nr_queued -= 1;
    se.on_rq = false;
    erq.updateMinVruntime();

    _ = flags;
    if (core.is_debug) log.verbose("dequeue {f} vlag={}", .{ task, se.vlag });
}

pub fn pickNext(rq: *Runqueue, prev: ?*innigkeit.Task) ?*innigkeit.Task {
    return rq.eevdf.pickNext(prev);
}

pub fn putPrev(rq: *Runqueue, prev: *innigkeit.Task) void {
    const erq = &rq.eevdf;
    const se = &prev.sched;
    const now = wallclock.read();
    updateCurr(erq, prev, now);

    erq.curr = null;

    // curr is always removed from the tree by setRunning before putPrev is called.
    if (core.is_debug) std.debug.assert(!se.on_rq);

    // Re-enqueue if still runnable (voluntary yield path).
    // Caller must have set prev.state = .ready before calling for this to trigger.
    if (prev.state == .ready) {
        // Renew the deadline if the slice was exhausted before re-enqueueing.
        // Without this, a task with vruntime >= deadline has a stale (earlier)
        // deadline than newly woken tasks, causing EEVDF to always re-select it.
        if (se.vruntime >= se.deadline) {
            if (!se.custom_slice) se.slice = default_slice_ns;
            se.deadline = se.vruntime + calcDeltaFair(se.slice, se.weight);
        }
        erq.addToAvg(se);
        se.subtree_min_vruntime = se.vruntime; // initialize leaf before walk-up
        _ = erq.tree.put(EevdfRunqueue.deadlineCmp, &se.rq_node);
        fixupAugmentationUp(&se.rq_node);
        erq.nr_queued += 1;
        se.on_rq = true;
        erq.updateMinVruntime();
        rq.nr_running += 1; // balance the setNextRunning decrement that will follow
    }

    if (core.is_debug) log.verbose("putPrev {f} vr={} dl={}", .{ prev, se.vruntime, se.deadline });
}

pub fn tick(rq: *Runqueue, curr: *innigkeit.Task, now: wallclock.Tick) bool {
    const erq = &rq.eevdf;
    const se = &curr.sched;

    updateCurr(erq, curr, now);
    updateUtil(se, now);

    // No competition, keep running.
    if (rq.nr_running == 0) return false;

    // Slice exhausted: a new deadline will be set and a switch is warranted.
    if (se.vruntime >= se.deadline) return true;

    // Check if a queued task with an earlier deadline is eligible.
    if (erq.pickEevdf()) |best| {
        if (best != curr and best.sched.deadline < se.deadline) return true;
    }

    return false;
}

pub fn taskNew(rq: *Runqueue, task: *innigkeit.Task) void {
    const se = &task.sched;
    const erq = &rq.eevdf;

    // A brand-new task starts at the current virtual time so it doesn't
    // immediately get a large windfall from accumulated lag.
    se.vruntime = if (erq.curr) |c| c.sched.vruntime else erq.min_vruntime;
    se.vlag = 0;
    if (se.slice == 0) se.slice = default_slice_ns;
    se.exec_start = wallclock.read();
}

pub fn taskWaking(task: *innigkeit.Task) void {
    // Placement (lag accounting) is deferred to enqueue with flags.wakeup=true.
    _ = task;
}

pub fn taskDead(task: *innigkeit.Task) void {
    _ = task;
}

/// Remove `task` from the EEVDF tree and mark it as the currently-running entity.
/// Called by Runqueue.setNextRunning() after pickNext() selects an EEVDF task.
///
/// This is called by `Runqueue` after pick.
pub fn setRunning(erq: *EevdfRunqueue, task: *innigkeit.Task) void {
    const se = &task.sched;
    if (se.on_rq) {
        erq.removeFromAvg(se);
        erq.tree.remove(&se.rq_node);
        _ = recomputeSubtreeMin(erq.tree.root);
        erq.nr_queued -= 1;
        se.on_rq = false;
        erq.updateMinVruntime();
    }
    erq.curr = task;
    se.exec_start = wallclock.read();
}

/// Scale real nanoseconds to virtual nanoseconds.
/// virtual = real * NICE_0_WEIGHT / weight
fn calcDeltaFair(delta_ns: u64, weight: u32) u64 {
    if (weight == nice_0_weight) return delta_ns;
    return @intCast(@min(
        @as(u128, delta_ns) * nice_0_weight / weight,
        std.math.maxInt(u64),
    ));
}

/// Current scheduling lag: positive = task is owed service.
///
/// lag = weighted_avg_vruntime - vruntime
///     = (sum_w_vruntime / sum_weight + zero_vruntime) - vruntime
fn lag(erq: *const EevdfRunqueue, se: *const SchedEntity) i64 {
    if (erq.sum_weight == 0) return 0;
    const sum_weight: i64 = @intCast(erq.sum_weight);
    const avg_key = @divTrunc(erq.sum_w_vruntime, sum_weight);
    const se_key: i64 = @as(i64, @bitCast(se.vruntime)) -% @as(i64, @bitCast(erq.zero_vruntime));
    return avg_key -% se_key;
}

/// O(log n) augmentation fixup: walk from `start` (the newly
/// inserted leaf) up to the root, recomputing `subtree_min_vruntime` at each
/// node from its own vruntime and its children's cached values. Stops early
/// when a node's value is unchanged: its ancestors cannot change either.
///
/// Maintains the conservative invariant: se.subtree_min_vruntime <= true_min.
/// Nodes rotated DOWN during `tree.put` rebalancing carry their old larger-
/// subtree smin (<= new true_min), which is safe for `pickBest` pruning.
/// Nodes rotated UP are always on this walk-up path and get exact values.
fn fixupAugmentationUp(start: *RbTree.Node) void {
    var cur: ?*RbTree.Node = start;
    while (cur) |n| {
        const se = SchedEntity.fromNode(n);
        const left_min = if (n.left) |l| SchedEntity.fromNode(l).subtree_min_vruntime else std.math.maxInt(u64);
        const right_min = if (n.right) |r| SchedEntity.fromNode(r).subtree_min_vruntime else std.math.maxInt(u64);
        const new_min = @min(se.vruntime, @min(left_min, right_min));
        if (new_min == se.subtree_min_vruntime) break;
        se.subtree_min_vruntime = new_min;
        cur = n.parent();
    }
}

/// O(n) full recompute of subtree_min_vruntime. Used after every removal
/// because `rebalanceAfterRemove` can rotate a node UP inside the promoted
/// node's subtree, giving it a smin that is LARGER than its new true minimum
/// (the promoted node's smin, computed from stale children, would then also
/// be too large, causing `pickBest` to prune the entire tree and hang).
fn recomputeSubtreeMin(node_opt: ?*RbTree.Node) u64 {
    const node = node_opt orelse return std.math.maxInt(u64);
    const se = SchedEntity.fromNode(node);
    const left_min = recomputeSubtreeMin(node.left);
    const right_min = recomputeSubtreeMin(node.right);
    se.subtree_min_vruntime = @min(se.vruntime, @min(left_min, right_min));
    return se.subtree_min_vruntime;
}

/// Recursively select the eligible task with the earliest virtual deadline.
/// Prunes subtrees whose `subtree_min_vruntime` exceeds the weighted average,
/// guaranteeing O(log n) traversal in the common case.
fn pickBest(erq: *const EevdfRunqueue, node_opt: ?*RbTree.Node) ?*innigkeit.Task {
    const node = node_opt orelse return null;
    const se = SchedEntity.fromNode(node);
    // If no task in this subtree is eligible, skip the whole subtree.
    if (!erq.vruntimeEligible(se.subtree_min_vruntime)) return null;
    // Tree is sorted by deadline: check left (earlier deadlines) first.
    if (pickBest(erq, node.left)) |t| return t;
    // Check this node.
    if (erq.vruntimeEligible(se.vruntime)) return se.task();
    // Fall through to right subtree (later deadlines).
    return pickBest(erq, node.right);
}

/// Set vruntime and deadline when placing a task onto the run queue.
fn placeEntity(erq: *EevdfRunqueue, se: *SchedEntity, flags: SchedClass.EnqueueFlags) void {
    if (flags.initial) {
        // New task: start at current virtual time.
        se.vruntime = @max(se.vruntime, erq.min_vruntime);
    } else if (flags.wakeup) {
        // Waking task: restore from lag to keep its fair position.
        // vlag is positive when owed service, so we subtract it from min_vruntime
        // to place it slightly behind (or ahead of) the current front.
        const base: i64 = @bitCast(erq.min_vruntime);
        const placed: i64 = base -% se.vlag;
        se.vruntime = @max(se.vruntime, @as(u64, @max(placed, 0)));
    }
    // else: re-enqueue after voluntary yield, keep vruntime as-is.

    // Renew deadline.
    if (se.vruntime >= se.deadline) {
        if (!se.custom_slice) se.slice = default_slice_ns;
        se.deadline = se.vruntime + calcDeltaFair(se.slice, se.weight);
    }
}

/// Advance the current task's vruntime by the time elapsed since exec_start.
fn updateCurr(erq: *EevdfRunqueue, curr: *innigkeit.Task, now: wallclock.Tick) void {
    const se = &curr.sched;
    const elapsed_ns = wallclock.elapsed(se.exec_start, now).value;
    if (elapsed_ns == 0) return;

    se.exec_start = now;
    se.sum_exec_runtime += elapsed_ns;

    const delta_fair = calcDeltaFair(elapsed_ns, se.weight);
    se.vruntime += delta_fair;
    erq.updateMinVruntime();
}

test "weight_table: nice 0 is 1024, table length is 40" {
    try std.testing.expectEqual(@as(usize, 40), weight_table.len);
    try std.testing.expectEqual(@as(u32, 1024), weight_table[20]);
    try std.testing.expectEqual(@as(u32, 1024), nice_0_weight);
}

test "weight_table: monotonically decreasing (higher nice = lower weight)" {
    for (1..weight_table.len) |i| {
        try std.testing.expect(weight_table[i] < weight_table[i - 1]);
    }
}

test "calcDeltaFair: nice-0 task (identity)" {
    try std.testing.expectEqual(@as(u64, 0), calcDeltaFair(0, nice_0_weight));
    try std.testing.expectEqual(@as(u64, 1_000_000), calcDeltaFair(1_000_000, nice_0_weight));
    try std.testing.expectEqual(@as(u64, 3_000_000), calcDeltaFair(3_000_000, nice_0_weight));
}

// test "calcDeltaFair: heavy task (nice -20, weight 88761) earns more real time" {
//     // Heavy task's virtual time advances slowly: delta_fair < elapsed.
//     const elapsed: u64 = 1_000_000;
//     const result = calcDeltaFair(elapsed, weight_table[0]); // nice -20
//     try std.testing.expect(result < elapsed);
//     // Exact: 1_000_000 * 1024 / 88761 = 11540 (integer)
//     try std.testing.expectEqual(@as(u64, 11540), result);
// }

// test "calcDeltaFair: light task (nice +19, weight 15) earns less real time" {
//     // Light task's virtual time advances quickly: delta_fair > elapsed.
//     const elapsed: u64 = 1_000_000;
//     const result = calcDeltaFair(elapsed, weight_table[39]); // nice +19
//     try std.testing.expect(result > elapsed);
//     // Exact: 1_000_000 * 1024 / 15 = 68266666
//     try std.testing.expectEqual(@as(u64, 68266666), result);
// }

test "vruntimeEligible: empty queue is always eligible" {
    const erq = EevdfRunqueue{};
    try std.testing.expect(erq.vruntimeEligible(0));
    try std.testing.expect(erq.vruntimeEligible(std.math.maxInt(u64) / 2));
}

test "vruntimeEligible: task at the weighted average is eligible" {
    // One queued task: vruntime=1000, weight=1024.
    // seKey = 1000, sum_w_vruntime = 1000*1024 = 1024000, sum_weight = 1024.
    // Weighted avg = 1024000/1024 = 1000.
    // A task with vruntime <= 1000 is eligible.
    var erq = EevdfRunqueue{};
    erq.sum_w_vruntime = 1000 * nice_0_weight;
    erq.sum_weight = nice_0_weight;

    try std.testing.expect(erq.vruntimeEligible(0)); // underserved
    try std.testing.expect(erq.vruntimeEligible(1000)); // exactly at average
    try std.testing.expect(!erq.vruntimeEligible(1001)); // overserved
}

test "vruntimeEligible: two equal-weight tasks — average is their mean" {
    // Two queued tasks at vruntime 500 and 1500, weight 1024 each.
    // sum_w_vruntime = (500 + 1500) * 1024 = 2048000, sum_weight = 2048.
    // Weighted avg = 2048000 / 2048 = 1000.
    var erq = EevdfRunqueue{};
    erq.sum_w_vruntime = (500 + 1500) * @as(i64, nice_0_weight);
    erq.sum_weight = 2 * nice_0_weight;

    try std.testing.expect(erq.vruntimeEligible(999));
    try std.testing.expect(erq.vruntimeEligible(1000));
    try std.testing.expect(!erq.vruntimeEligible(1001));
}

// Augmentation tests: verify fixupAugmentationUp / fixupAfterRemove.
//
// These tests build RbTree instances directly with stack-allocated SchedEntity
// fixtures; no Task/wallclock/scheduler state is needed. SchedEntity.task()
// is intentionally not dereferenced — we only compare its address as an opaque
// pointer value when checking pickBest results.

/// Verify augmentation after a REMOVE operation: `recomputeSubtreeMin` gives
/// exact values everywhere, so we assert strict equality.
/// Returns the true minimum for the given subtree.
fn auditSubtreeExact(node_opt: ?*RbTree.Node) !u64 {
    const node = node_opt orelse return std.math.maxInt(u64);
    const se = SchedEntity.fromNode(node);
    const left_min = try auditSubtreeExact(node.left);
    const right_min = try auditSubtreeExact(node.right);
    const expected = @min(se.vruntime, @min(left_min, right_min));
    try std.testing.expectEqual(expected, se.subtree_min_vruntime);
    return expected;
}

/// Verify augmentation after an INSERT operation: `fixupAugmentationUp` gives
/// exact values on the walk-up path but only the conservative invariant
/// (smin <= true_min) elsewhere (nodes rotated down during rebalancing).
/// Asserts smin is never LARGER than true_min (the dangerous direction).
fn auditSubtreeConservative(node_opt: ?*RbTree.Node) !u64 {
    const node = node_opt orelse return std.math.maxInt(u64);
    const se = SchedEntity.fromNode(node);
    const left_min = try auditSubtreeConservative(node.left);
    const right_min = try auditSubtreeConservative(node.right);
    const true_min = @min(se.vruntime, @min(left_min, right_min));
    if (se.subtree_min_vruntime > true_min) {
        std.debug.print(
            "augmentation stale-HIGH (unsafe): vruntime={} true_min={} smin={}\n",
            .{ se.vruntime, true_min, se.subtree_min_vruntime },
        );
    }
    try std.testing.expect(se.subtree_min_vruntime <= true_min);
    return true_min;
}

/// Insert all entries in `ses` into `tree` using the enqueue-style initialisation
/// (init leaf, put, fixup). Helper shared across tests.
fn testInsertAll(tree: *RbTree, ses: []const *SchedEntity) void {
    for (ses) |se| {
        se.subtree_min_vruntime = se.vruntime;
        _ = tree.put(EevdfRunqueue.deadlineCmp, &se.rq_node);
        fixupAugmentationUp(&se.rq_node);
    }
}

test "augmentation: single insert initialises leaf correctly" {
    var se = SchedEntity{ .vruntime = 42, .deadline = 1 };
    var tree = RbTree{};
    se.subtree_min_vruntime = se.vruntime;
    _ = tree.put(EevdfRunqueue.deadlineCmp, &se.rq_node);
    fixupAugmentationUp(&se.rq_node);
    try std.testing.expectEqual(@as(u64, 42), se.subtree_min_vruntime);
}

test "augmentation: smaller vruntime right child propagates to root" {
    // a is inserted first (root); b has a larger deadline so it goes right.
    // b.vruntime < a.vruntime -> root's smin must be <= 50 after fixup.
    // With exactly 2 nodes no rotation occurs so we can assert exact equality.
    var a = SchedEntity{ .vruntime = 100, .deadline = 1 };
    var b = SchedEntity{ .vruntime = 50, .deadline = 2 };
    var tree = RbTree{};
    testInsertAll(&tree, &.{ &a, &b });
    _ = try auditSubtreeConservative(tree.root);
    // No rotation with 2 nodes -> exact equality holds at the root.
    const root_se = SchedEntity.fromNode(tree.root.?);
    try std.testing.expectEqual(@as(u64, 50), root_se.subtree_min_vruntime);
}

test "augmentation: larger vruntime insert stops early (no ancestor update)" {
    // a.vruntime=50 is already the minimum; inserting b.vruntime=200 must not
    // touch a's subtree_min_vruntime (early-exit fires at b's parent).
    var a = SchedEntity{ .vruntime = 50, .deadline = 1 };
    var b = SchedEntity{ .vruntime = 200, .deadline = 2 };
    var tree = RbTree{};
    testInsertAll(&tree, &.{&a});
    const before = a.subtree_min_vruntime;
    testInsertAll(&tree, &.{&b});
    try std.testing.expectEqual(before, a.subtree_min_vruntime);
    _ = try auditSubtreeConservative(tree.root);
}

test "augmentation: 5-node insert, root smin ≤ global minimum (safe invariant)" {
    // auditSubtree checks smin ≤ true_min everywhere. The root's smin must be <= 10
    // (the global minimum), which means pickBest will never wrongly prune the root.
    var nodes: [5]SchedEntity = .{
        .{ .vruntime = 300, .deadline = 1 },
        .{ .vruntime = 50, .deadline = 2 },
        .{ .vruntime = 200, .deadline = 3 },
        .{ .vruntime = 10, .deadline = 4 },
        .{ .vruntime = 400, .deadline = 5 },
    };
    var tree = RbTree{};
    testInsertAll(&tree, &.{ &nodes[0], &nodes[1], &nodes[2], &nodes[3], &nodes[4] });
    _ = try auditSubtreeConservative(tree.root);
    const root_se = SchedEntity.fromNode(tree.root.?);
    try std.testing.expect(root_se.subtree_min_vruntime <= 10);
}

test "augmentation: remove leaf, parent correctly updated" {
    var a = SchedEntity{ .vruntime = 100, .deadline = 1 };
    var b = SchedEntity{ .vruntime = 50, .deadline = 2 };
    var c = SchedEntity{ .vruntime = 200, .deadline = 3 };
    var tree = RbTree{};
    testInsertAll(&tree, &.{ &a, &b, &c });
    _ = try auditSubtreeConservative(tree.root);

    tree.remove(&c.rq_node);
    _ = recomputeSubtreeMin(tree.root); // O(n) full recompute (what dequeue/setRunning use)
    if (tree.root) |_| _ = try auditSubtreeExact(tree.root);
}

test "augmentation: remove two-child node — recompute fixes stale-high smin" {
    // This test demonstrates WHY the O(log n) fixup cannot be used for remove:
    // removing a two-child node swaps it with its successor. The successor
    // carries its old leaf smin (200) into the new root position, where the
    // true smin is 10 (from n1). recomputeSubtreeMin restores exact values.
    var n1 = SchedEntity{ .vruntime = 10, .deadline = 1 };
    var n2 = SchedEntity{ .vruntime = 100, .deadline = 2 }; // will be removed
    var n3 = SchedEntity{ .vruntime = 200, .deadline = 3 }; // promoted node (was leaf)
    var n4 = SchedEntity{ .vruntime = 50, .deadline = 4 };
    var n5 = SchedEntity{ .vruntime = 300, .deadline = 5 };
    var tree = RbTree{};
    testInsertAll(&tree, &.{ &n1, &n2, &n3, &n4, &n5 });
    _ = try auditSubtreeConservative(tree.root);

    tree.remove(tree.root.?); // remove n2 (root after 5 balanced inserts)
    _ = recomputeSubtreeMin(tree.root);
    if (tree.root) |_| _ = try auditSubtreeExact(tree.root);

    // pickBest must find eligible tasks now that smin is correct.
    // avg=100: n1(vr=10) and n4(vr=50) eligible; n3(vr=200), n5(vr=300) not.

    var erq = EevdfRunqueue{};
    erq.sum_w_vruntime = 100 * @as(i64, nice_0_weight);
    erq.sum_weight = nice_0_weight;
    try std.testing.expect(pickBest(&erq, tree.root) != null);
}

test "augmentation: full insert-remove cycle" {
    // Insert 7 nodes (conservative check after each insert), then remove them
    // one by one (exact check after each remove via recomputeSubtreeMin).
    // Insert 7 nodes, then remove them one by one, verifying after each step.
    var nodes: [7]SchedEntity = .{
        .{ .vruntime = 500, .deadline = 1 },
        .{ .vruntime = 100, .deadline = 2 },
        .{ .vruntime = 300, .deadline = 3 },
        .{ .vruntime = 10, .deadline = 4 },
        .{ .vruntime = 700, .deadline = 5 },
        .{ .vruntime = 50, .deadline = 6 },
        .{ .vruntime = 900, .deadline = 7 },
    };
    var tree = RbTree{};
    for (&nodes) |*se| {
        se.subtree_min_vruntime = se.vruntime;
        _ = tree.put(EevdfRunqueue.deadlineCmp, &se.rq_node);
        fixupAugmentationUp(&se.rq_node);
        _ = try auditSubtreeConservative(tree.root);
    }
    for (&nodes) |*se| {
        if (se.rq_node.extra.isolated) continue;
        tree.remove(&se.rq_node);
        _ = recomputeSubtreeMin(tree.root);
        if (tree.root) |_| _ = try auditSubtreeExact(tree.root);
    }
}

test "pickBest: returns null when all tasks ineligible" {
    // avg vruntime = 100; all tasks have vruntime > 100 -> none eligible.
    var a = SchedEntity{ .vruntime = 101, .deadline = 1 };
    var b = SchedEntity{ .vruntime = 200, .deadline = 2 };
    var tree = RbTree{};
    testInsertAll(&tree, &.{ &a, &b });

    var erq = EevdfRunqueue{};
    erq.sum_w_vruntime = 100 * @as(i64, nice_0_weight);
    erq.sum_weight = nice_0_weight;

    try std.testing.expectEqual(@as(?*innigkeit.Task, null), pickBest(&erq, tree.root));
}

test "pickBest: selects eligible task with earliest deadline" {
    // avg = 100. a(dl=3,vr=80) and b(dl=1,vr=50) are eligible; c(dl=2,vr=120) is not.
    // Expected: b (earliest deadline among eligible tasks).
    var a = SchedEntity{ .vruntime = 80, .deadline = 3 };
    var b = SchedEntity{ .vruntime = 50, .deadline = 1 };
    var c = SchedEntity{ .vruntime = 120, .deadline = 2 };
    var tree = RbTree{};
    testInsertAll(&tree, &.{ &a, &b, &c });

    var erq = EevdfRunqueue{};
    erq.sum_w_vruntime = 100 * @as(i64, nice_0_weight);
    erq.sum_weight = nice_0_weight;

    const result = pickBest(&erq, tree.root);
    // result is a *innigkeit.Task pointer; compare address only (no dereference).
    try std.testing.expectEqual(b.task(), result.?);
}

test "pickBest: prunes ineligible subtree via subtree_min_vruntime" {
    // Build a tree where the left subtree's subtree_min_vruntime exceeds the
    // average, and pickBest must prune that whole subtree and find the right one.
    //
    // avg = 100.  Left subtree: only c (vr=150, ineligible).
    //             Right subtree: only d (vr=80, eligible, dl=4).
    // With deadlines: c(dl=1), d(dl=4); d ends up in the right subtree.
    // Actually with this layout c < d by deadline so we need c to be in
    // left subtree of root. Use 3 nodes: root=b(dl=2,vr=150), b.left=a(dl=1,vr=160),
    // b.right=d(dl=3,vr=80). avg=100 -> a and b ineligible, d eligible.
    var a = SchedEntity{ .vruntime = 160, .deadline = 1 };
    var b = SchedEntity{ .vruntime = 150, .deadline = 2 };
    var d = SchedEntity{ .vruntime = 80, .deadline = 3 };
    var tree = RbTree{};
    testInsertAll(&tree, &.{ &a, &b, &d });

    var erq = EevdfRunqueue{};
    erq.sum_w_vruntime = 100 * @as(i64, nice_0_weight);
    erq.sum_weight = nice_0_weight;

    const result = pickBest(&erq, tree.root);
    try std.testing.expectEqual(d.task(), result.?);
}

/// Update the utilization EWMA for a task.
///
/// Called from tick() after updateCurr(), so sum_exec_runtime already includes
/// the current interval.Using sum_exec_runtime delta avoids the overcounting
/// that occurs when accumulating elapsed-since-window-start each tick.
fn updateUtil(se: *SchedEntity, now: wallclock.Tick) void {
    const window_ns: u64 = 32_000_000; // 32 ms window
    const elapsed = wallclock.elapsed(se.util_window_start, now).value;

    if (elapsed < window_ns) {
        @branchHint(.likely);
        return;
    }

    const cpu_ns = se.sum_exec_runtime - se.util_runtime_at_window_start;
    se.util_avg = @intCast(@min(
        @as(u64, nice_0_weight) * cpu_ns / window_ns,
        nice_0_weight,
    ));
    se.util_runtime_at_window_start = se.sum_exec_runtime;
    se.util_window_start = now;

    // Auto-adjust slice based on measured utilization (unless user-set).
    if (!se.custom_slice) {
        se.slice = if (se.util_avg < 256)
            1_000_000 // 1 ms: IO-bound, prioritize latency
        else if (se.util_avg > 768)
            6_000_000 // 6 ms: CPU-bound, prioritize throughput
        else
            default_slice_ns;
    }
}
