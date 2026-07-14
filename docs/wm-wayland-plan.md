# Display server — native WM → Wayland compositor

> **STASHED (2026-06-23).** Parked behind security and test-system work (see `docs/roadmap.md`). The pure cores are built and host-tested: `wm/geometry.zig`, `wm/protocol.zig`, `wm/client.zig`, `wm/server.zig` — all green under `wm_core`. Remaining work is the live A1/A3 finish (bootstrap app, per-client request demux, composite-blit) and Phase B (Wayland). Resume when the roadmap says so.

---

## Current state

**Substrate:**
- **Scanout/present**: one global framebuffer. `framebuffer_map` (syscall 20) maps the bootloader fb or virtio-gpu backing store; `gpu_flush`/`present(x,y,w,h)` (syscalls 40/60) present a damage rect. `library/innigkeit/graphics.zig`: `Canvas` + offscreen `Buffer`.
- **Buffers (sharable)**: `gpu_buffer` cap (`cap_create(.gpu_buffer)`, `gpu` entitlement) and `Frame` cap (`clone`, `phys_addr`, `vmem_map`). Both are physical-page-backed — the zero-copy basis (dmabuf-equivalent).
- **IPC**: `Endpoint` (send/recv/call/reply) and `Notify` (signal/wait). `Message` = 8-byte tag + 4×u64 payload + **4 cap handles**. This is request/response + fd-passing — exactly the shape Wayland needs.
- **Input**: PS/2 keyboard (`kbd_read`) and mouse (`mouse_read`). Both are global, non-routed drains.
- **Spawn**: cap-granting `spawn`, exit `Notify`, `wait_process`.
- **QoS**: compositor runs `interactive`, clients `default`/`background`.
- **`std.Io`**: `library/innigkeit/stdio.zig` is a synchronous `std.Io` backend with futex-backed Mutex/Condition/Event, time, and stdio streams.

**`apps/wm` today:** a ~400-line single process that maps the framebuffer, draws a menu bar + dock, reads the mouse, and spawns apps fullscreen. No client windows, no per-client buffers, no compositing, no input routing. The right throwaway scaffold to evolve from.

**Four real gaps before "multi-client" means anything:**
1. Every app with `framebuffer` entitlement maps the *same* scanout and draws directly. Two GUI apps = garbage. The compositor must own scanout; clients render into their own buffers.
2. No agreed "here are my surface's pixels" handshake, even though caps can carry a `gpu_buffer`/`Frame` in a `Message`.
3. Input is a global drain; nothing routes events to the focused client.
4. `gpu_flush` blits the whole backing store; there's no per-surface damage or frame-callback pacing.

**What's already built (the pure cores):**
- **`wm/geometry.zig`** — `Rect` (intersect/contains/union) + a fixed-capacity z-ordered `Stack` with raise/move/remove/`topAt` hit-testing and bounding-box damage. No I/O; host-unit-tested. Shared by the native WM and the Wayland front-end.
- **`wm/protocol.zig`** — typed `Request` (client→server) and `Event` (server→client) tagged unions encoding onto `Message` (tag = append-only opcode; 4×u64 words; 4 cap handles). Illegal states are unrepresentable; every variant round-trip host-tested. 6 requests: connect/create_surface/attach_buffer/commit/set_position/destroy_surface. 7 events: surface_created/configure/frame_done/pointer/key/buffer_released/closed. Opcodes are append-only.
- **`wm/server.zig` `Compositor`** — pure `Compositor(max_surfaces)` owning the surface list (geometry + committed buffer cap). Decodes `protocol.Request`s via `apply` → `Outcome` (new surface id, damage rect, or nothing). `commit` translates surface-local damage to screen; `pointerAt` hit-tests for input routing. Host-unit-tested. What stays out (the IPC loop's job): mapping the buffer cap + blitting, creating per-surface frame `Notify`, moving event caps.
- **`wm/server.zig` `Server(Platform)`** — wraps `Compositor` with IPC/scanout plumbing via an injected `Platform` (recv/sendEvent/createFrameNotify/present). `handleOne` recvs a request, registers the client's event channel on `connect`, applies and acts on `Outcome`. Malformed messages and unknown clients are dropped. Orchestration host-tested with a fake platform; the thin `SyscallPlatform` is compile-checked. **Remaining for live A1/A3:** the production bootstrap app (builds the registry endpoint, spawns clients), per-client request demux (a multi-wait — today the platform reads one channel), and the composite-blit (map each visible surface's read-only buffer, copy into scanout, present).
- **`wm/client.zig`** — `connect()` → `Connection`, `createSurface()` → `Surface` with `attach()`/`commit()`/`setPosition()`/`destroy()`/`waitFrame()`, `nextEvent()`. `attach` shares the buffer read-only (`caps.copy(.., .read_only)`) — server composites zero-copy but can't modify it. Generic over a `Transport` so behavior is host-unit-tested with an in-memory fake.

---

## Architecture

```
         ┌─────────────────────────────────────────┐
         │  display server (QoS interactive)        │
         │  - owns scanout (framebuffer/virtio-gpu)  │
         │  - compositor: surface list, z-order, damage│
         │  - input focus + event dispatch           │
         │  - window policy / xdg roles              │
         └───▲───────────────▲───────────────▲───────┘
Endpoint(call)│        cap: buffer│       Notify: frame/input│
         ┌────┴────┐      ┌──────┴───┐      ┌──────┴───┐
         │ client A│      │ client B │      │  ...     │  (QoS default)
         └─────────┘      └──────────┘      └──────────┘
```

Clients hold one `Endpoint` cap to the server (granted at spawn). Requests are `call`s; events are delivered via a per-client event `Endpoint` or `Notify` + reply queue. Clients hold caps only to *their own* surfaces/buffers. Confinement is the default — cheaper to guarantee here than on Linux.

The strategy: **native protocol + WM first** (proves buffers/input/present end-to-end with the simplest wire), then a **Wayland front-end** that speaks the real `wl_*` wire on top of the same compositor core.

---

## Substrate hardening (prerequisite steps)

- **H1 — Shareable surface buffers (zero-copy).** Client allocates a `gpu_buffer`/`Frame`, draws into its `vmem_map`'d view, passes a *read-only cap copy* to the server in a commit message. Server maps it to composite — same physical frame, no copy, server can't write. Proven at the kernel level ("Frame sharing transfers backing zero-copy and can restrict rights"); the remaining piece is confirming `gpu_buffer` works without virtio-gpu (software/Frame-backed path for QEMU plain framebuffer).
- **H2 — Input service + virtio-input.** virtio-input driver (keyboard + tablet/pointer — QEMU emulates it) + an input-routing service that drains input and dispatches events to the focused client over IPC. Keep PS/2 as fallback.
- **H3 — Present/damage** — already landed. `present(x,y,w,h)` (syscall 60) → virtio-gpu TRANSFER_TO_HOST_2D + RESOURCE_FLUSH scoped to the rect; clamped by the kernel; no-op on plain fb. Remaining: frame/vsync `Notify` for pacing (low value under QEMU, which has no real vblank — `nanosleep_ms` pacing is fine for now).
- **H4 — `std.Io` weave.** Server event loop as `std.Io` multi-wait (Endpoints + input + timers); client + server containers as `std.ArrayList`/`HashMap`; geometry/region typed. Validates the `std.Io` backend under real multi-wait load.

---

## Phased implementation

**Phase A — native multi-client WM:**
- A1. Server skeleton: owns scanout, draws background, registry `Endpoint`.
- A2. Client connect + `create_surface`; server tracks an empty surface.
- A3. Buffer attach + commit + composite one client surface (zero-copy via H1).
- A4. Multiple surfaces: z-order, move/stack, menu+dock policy from today's `apps/wm`.
- A5. Input routing: focus/clicks → deliver pointer+key to focused client (via H2).
- A6. Frame callbacks / damage pacing (H3); double-buffering + release.
- A7. Port `gfx_demo`, `calculator` to the client library; retire the "everyone maps framebuffer" path for GUI apps.

**Phase B — Wayland compositor:**
- B1. `wl_display`/`wl_registry` + wire dispatch over IPC.
- B2. `wl_compositor`/`wl_surface` + buffer (`wl_shm` first, then dmabuf = cap).
- B3. `wl_seat`/`wl_keyboard`/`wl_pointer` from the input service.
- B4. `xdg_shell` (toplevel/popup, configure).
- B5. Run a real Wayland client end-to-end.

---

## Open decisions

- **Event delivery**: per-client `Notify` + reply-queue vs server→client `Endpoint` per client. Leaning: server→client `Endpoint` for events (more like Wayland's two-directional stream).
- **Buffer type**: standardize on `gpu_buffer` (works without virtio-gpu?) vs `Frame` sets. Confirm the software-backed path under QEMU.
- **Registry/bootstrap**: spawn-time cap grant (compositor spawns clients) vs a names service. Leaning: compositor is the spawner (already is in `apps/wm`), so it grants the `Endpoint` at spawn.
- **`std.Io` depth**: how much of the server runs on `std.Io` async vs plain blocking IPC calls in `interactive`-QoS threads.
