# Scheduler QoS

**Status: implemented.** Weight+slice QoS mapping + `thread_set_qos` shipped. Phase A (reschedule IPI, idle work stealing, idle-first wake placement) shipped in "feat: scheduler utilization."

## What shipped

- `Eevdf.Qos` { interactive, default, background } + `qos_presets` (weights 2048 / 1024 / 335; slices 1 / 3 / 10 ms) + `Eevdf.setQos(se, qos)` (weight + slice + immediate deadline rescale; preserves a `custom_slice`). `Task.Qos` / `Task.setQos` are the task-facing names.
- Syscall `thread_set_qos` (59): caller-only, ungated; handler in `handlers/misc.zig` takes the scheduler lock; userspace `thread.setQos`.
- Tests (deterministic, in `Eevdf.zig`): preset application, weight→CPU-share ratio ("double weight advances vruntime at half rate"), and custom-slice survival.

Gate: x64 123/123, arm 83 (9 skipped).

Deferred: P/E Edge-style migration (untestable under QEMU), process-group fairness, root-bucket EDF. A cross-task (capability-gated) QoS setter would extend `setQos` with a dequeue/enqueue around the weight change.

---

## Background — Apple XNU Clutch/Edge (doc published 2026-02)

Source: https://github.com/apple-oss-distributions/xnu/blob/main/doc/scheduler/sched_clutch_edge.md

Three-level hierarchy:
1. **Root buckets** = QoS classes (FIXPRI/FG/IN/DF/UT/BG), scheduled by EDF with per-class deadline windows (`WCEL`: FG=0µs, IN=37.5ms, DF=75ms, UT=150ms, BG=250ms) plus bounded "warp" windows for high-QoS preemption.
2. **Thread groups** within a bucket, ranked by interactivity score (blocked-time / CPU-time ratio).
3. **Threads** within a group via priority decay.

Edge (heterogeneous): per-QoS directed migration graphs; migrate when scheduling-latency delta > edge weight. Idle protocol: find displaced threads → steal native → IPI foreign running threads → cross-cluster steal.

## What we adopted

Full root-bucket EDF is overkill at our scale. QoS maps onto EEVDF weight+slice policy, which captures most of the value:

| QoS | weight | slice | intent |
|---|---|---|---|
| interactive | 2048 (≈ nice −5) | 1 ms | low latency, frequent preemption |
| default | 1024 | 3 ms | unchanged |
| background | 335 (≈ nice +5) | 10 ms | throughput, yields latency |

EEVDF already provides Clutch's interactivity mechanism: a task that blocks often accumulates positive lag and is placed favourably on wakeup (`placeEntity` with `.wakeup`, vlag-based). No extra scoring machinery needed at our scale.

## Implementation notes

`src/innigkeit/task/sched/Eevdf.zig`: `pub const Qos = enum(u8) { interactive, default, background }` + preset table + `setQos(se, qos)`. Changing weight of an enqueued entity must keep `sum_w_vruntime`/`sum_weight` consistent — safest to dequeue/enqueue under the scheduler lock, or only allow while not enqueued. `setQos` does the former.

Syscall numbering: `thread_set_qos` = 59 (appended after `net_udp_recv_nb` = 58). Arg1 = qos (0/1/2), affects the calling task only (lowering/raising own QoS is unprivileged; cross-task QoS would need a capability).

P/E Edge-lite: executors carry `core_type` (CPUID 0x1A) and tasks carry `core_hint` (syscall 35, `thread_set_hint`), consumed by `pickPreferring` in `Runqueue.zig`. Edge-style latency-delta migration is deferred — QEMU can't emulate hybrid CPUs.

Deferred: process-level group fairness (divide a process's aggregate weight across runnable threads to stop thread-count domination); root-bucket EDF with warps if QoS counts exceed what weights express.

## Key invariants

- Changing weight of an enqueued entity must keep `sum_w_vruntime`/`sum_weight` consistent (see `addToAvg`/`removeFromAvg`). The `smin` augmentation is unaffected (weight is not a tree key).
- Scheduler lock rule: no path ever holds two scheduler locks at once.
- QoS changes don't affect `Task.stealable` semantics.
