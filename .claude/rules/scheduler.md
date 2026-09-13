---
paths:
  - "src/innigkeit/task/**"
  - "src/innigkeit/sync/**"
---

# Scheduler invariants

- **No path ever holds two scheduler locks at once.** Work stealing uses `tryLock` on the victim and releases it before taking the local lock.
- **Changing weight of an enqueued entity** must keep `sum_w_vruntime`/`sum_weight` consistent (`addToAvg`/`removeFromAvg`). Safest to dequeue/enqueue under the scheduler lock. The `smin` augmentation is unaffected (weight is not a tree key).
- **RT tasks and migration-pinned tasks are never stolen.** `Task.stealable` must be checked before stealing.
- **`Task.wakeFromBlocked`**: places an unpinned woken task on an idle executor when one exists, else migrates to the waker's executor. Migration-pinned tasks always return to their own executor.
- **Reschedule IPI**: x86-64 vector 253; optional arch function (`reschedule_ipi_available`). The 5 ms tick is the backstop on arm/riscv where the IPI is not yet wired. `Scheduler.kickIfIdle` skips the IPI when the slot is absent.
- **Kill IPI** (sibling-thread force-termination): x86-64 vector 252 (`kill_request`), broadcast (`all_excluding_self`) rather than targeted at one executor — see `Process.forceTerminateSiblings`'s own doc comment for why a broadcast avoids reading another task's `state`/`known_executor` from a foreign core. The handler is (nearly) empty; the real work is `Task.pending_kill` being checked at `Current.checkPendingKill`, called only from a syscall/interrupt return to user mode (never from arbitrary kernel-mode execution) — the IPI just forces a target executor through an interrupt return sooner. `architecture.interrupts.kill_ipi_available` gates it the same way `reschedule_ipi_available` does; arm now has one too (GICv2 SGI id 3, `arm/ipi.zig`); riscv has none and relies on the periodic-tick backstop. **This safe point had two real bugs, both found and FIXED chasing the M3.3 arm SMP blocker** — full writeup in `docs/aarch64-port.md`'s M3.3 section:
  1. `pending_kill` was set once (`forceTerminateSiblings`) and never cleared, so the old (spinlock-release-based) safe point re-fired on the to-be-killed task's own stack every time termination's own path released a nested spinlock before `state` flipped to `.terminated` — unbounded recursion (confirmed 900+ deep in one boot). Fixed by consuming the flag before acting on it.
  2. The deeper bug: that old safe point (`Current.decrementInterruptDisable`) only guarded `spinlocks_held == 0`, not whether a sleeping `Mutex`/`RwLock` (e.g. `AddressSpace.entries_lock`) was held, and `Scheduler.Handle.terminate()` abandons whatever the terminated task holds without unwinding. Fixed by moving the check entirely out of `decrementInterruptDisable` into `Current.checkPendingKill`, wired only into each architecture's syscall-return and interrupt-return-to-EL0/ring3 paths — the same technique Linux (`TIF_SIGPENDING` in `exit_to_user_mode_loop`) and BSD (ASTs) use for asynchronous thread termination/signal delivery. Verified crash-free across ~10 `-smp 4` arm boots.

  Both bugs were arch-independent; x64 could in principle have hit either, just apparently rarely enough not to have surfaced.
- **QoS presets** (weights/slices): interactive=2048/1ms, default=1024/3ms, background=335/10ms. `thread_set_qos` (syscall 59) affects the calling task only; cross-task QoS change needs a capability.
- **Watchdog discipline** (from `smp.test.zig`): every wait in a test must be wallclock-bounded so a deadlock fails the suite instead of hanging it. Apply the same pattern to new blocking test code.

## `setCurrentTask`/GS_BASE vs. the stack swap — resolved (Phase 3 Stage 8)

Stage 6a/6b left open whether `PerTask.setCurrentTask`'s GS_BASE write and
`scheduling.switchTask`'s actual rsp/rbp swap could observe each other
inconsistently. Traced end to end in Stage 8: every switch path in
`task/Handle.zig` (`switchToTaskFromIdleYield`, `switchToTaskFromTaskYield`,
`switchToTaskFromTaskDeferredAction`, `switchToIdleDeferredAction`) calls
`executor.setCurrentTask(new_task)` (which writes `GS_BASE` immediately,
x64 `PerTask.zig`) *before* calling `architecture.scheduling.switchTask`/
`switchTaskNoSave`/`call`/`callNoSave` (the actual native-stack swap). This
creates a real window — GS_BASE already points at `new_task` while the CPU
is still executing on `old_task`'s native stack — but it's benign: (1)
`switchTask` and its siblings (`architecture/x64/scheduling.zig`) are pure
register/stack asm that take `old_task`/`new_task` as explicit parameters
and never read `Task.Current`/GS_BASE themselves; (2) no Zig-level code
runs between the `setCurrentTask` call and the `switchTask` call; (3)
interrupts are disabled for the entire critical section (every switch path
runs under the scheduler lock with `interrupt_disable_count` elevated), so
nothing can observe the mismatched window. Not a bug — a structural
consequence of `Task.Current` being a logical-identity commit point, not a
literal "which stack is executing" query. Port note for future
architectures: the same ordering (commit the logical current-task pointer
before the physical stack swap) is safe only as long as the switch asm
itself never depends on the outgoing/incoming task's `Task.Current`.

## Two Stage 8 cleanup notes (documented, not fixed)

- **`SchedCap.setClass`/`setNice`/`setSlice` mutate scheduler state without
  taking any scheduler lock.** Already self-documented via `TODO`s in
  `SchedCap.zig` ("update weight under scheduler lock and re-place in
  tree") and the file's own top-of-file note that enforcement isn't wired
  into any syscall handler yet — confirmed still true, not a live path
  today, so not a live bug. Whoever wires this up must take the scheduler
  lock and dequeue/re-enqueue per the "changing weight of an enqueued
  entity" rule above, not add it as an afterthought.
- **`SchedClass.pick_next`'s `prev: ?*innigkeit.Task` parameter is always
  `null` and never read.** `Scheduler.getNextTask()` (the sole call site
  reachable from the real scheduling path) calls
  `self.runqueue.pickNext(null)` unconditionally; `Eevdf.pickNext`,
  `Rt.pickNext`, and `Idle.pickNext` all ignore it (`_ = prev;`) and use
  `EevdfRunqueue.curr`/RT's own FIFO state instead. A safe simplification
  (drop the parameter from the vtable and every implementation) but touches
  the scheduling-class dispatch signature across every class plus the
  `EevdfRunqueue.pickPreferring`/`pickNext` call graph — reported rather
  than applied unilaterally, per this project's delivery model for changes
  to stable, widely-depended-on dispatch surfaces.
