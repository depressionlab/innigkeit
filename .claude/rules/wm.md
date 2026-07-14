---
paths:
  - "library/innigkeit/wm/**"
  - "apps/wm/**"
  - "docs/wm-wayland-plan.md"
---

# Display server — stashed

The WM epic is parked. Pure cores are built and host-tested; do not restart this work without explicit instruction.

**What's built and host-tested (wm_core, 29 tests):**
- `wm/geometry.zig`: `Rect` + `Stack` (z-order, hit-test, damage)
- `wm/protocol.zig`: `Request`/`Event` tagged unions encoding onto `Message`
- `wm/client.zig`: `Connection`/`Surface` generic over `Transport`
- `wm/server.zig`: pure `Compositor` + `Server(Platform)` with injected `Platform`

**What's missing for a live A1/A3:**
- production bootstrap app (registry endpoint, spawns clients)
- per-client request demux (multi-wait — today Platform reads one channel)
- composite-blit (map each surface's read-only buffer cap, copy into scanout, present)

**`Endpoint.transferCaps` is user↔user only** — kernel test tasks return early. None of the WM IPC paths have behavioral coverage until the user-process integration harness (TH-5) is built. Do not claim WM IPC is verified.

**Resume condition:** after user-process integration harness (roadmap step 1) is done. TH-5 validates the stashed cores end-to-end before the live finish.
