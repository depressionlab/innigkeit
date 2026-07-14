---
paths:
  - "src/innigkeit/network/**"
---

# Network stack invariants

Drafted during Phase 3 Stage 12 (`docs/phase3-review-plan.md`), same
convention `.claude/rules/acpi.md`/`drivers.md`/`memory.md`/`scheduler.md`/
`x64.md`/`arm.md` established for their subsystems.

## Every wire-format length field needs both a lower AND upper bound before it's used to slice — `udp.zig` only had the upper one

A protocol header's own declared length field (as opposed to the number of
bytes actually received, `data.len`) is attacker-controlled and
independent of the buffer size. Getting only the upper bound right
(`data.len < declared_length -> reject`) is not enough — a declared length
*smaller* than the format's own fixed minimum header size produces a
slice with `start > end`, which Zig's slicing bounds-check turns into a
runtime panic rather than silently misbehaving.

- **`udp.zig`'s `parse()` — FIXED (Stage 12).** Checked `data.len <
  length` but not `length < HEADER_LEN` (8). A UDP packet with a real
  size `>= 8` bytes but a header `length` field of `0` produced
  `data[8..0]` — a single crafted packet from anywhere on the network
  segment, panicking the kernel with no privilege or handshake required.
  Fixed: reject `length < HEADER_LEN` before it's used, alongside the
  existing upper-bound check.
- **`ipv4.zig`'s `parse()` — the correct pattern, already in the
  codebase.** Both of the format's own declared-length fields get both
  bounds: `ihl` is checked `>= HEADER_LEN` (lower) and `<= data.len`
  (upper); `total` is checked `>= ihl` (lower) and `<= data.len` (upper).
  Point any future parser at this function as the template.
- **`tcp/Segment.zig`'s `parse()` — also already hardened**, including
  against the exact same shape of bug in its TCP-options loop: every
  option's declared `len` is checked against a floor (`< 2`) and the
  remaining option space (`> opt.len`) before being used to advance the
  scan — with a regression test whose comment states a zero-length option
  "previously looped forever," proving this exact class was already found
  and fixed here once before `udp.zig`'s instance surfaced.

## `socket.zig`'s `handleIp()` dispatches to UDP/ICMP/TCP handlers without checking the packet's destination IP (Phase 3 Stage 12, not fixed)

`ip4.parse()`'s returned `pkt.dst` is available but never compared against
this host's own IP before `handleUdp`/`handleIcmp`/`tcp_sock.handleSegment`
are called — every inbound IPv4 packet the NIC receives is processed
regardless of who it was actually addressed to.
`tcp/Socket.zig`'s `handleSegment()` receives `dst_ip` as a parameter and
immediately discards it with a comment claiming "we always accept frames
addressed to us" — describing behavior the code doesn't implement; there
is no accept/reject decision happening at all. Low-impact under the
current QEMU user-mode-networking setup (the virtual NIC generally only
receives traffic actually destined to this VM), but a real gap on any
bridged/promiscuous/broadcast-domain deployment. Not fixed: deciding where
the check belongs, and how it should carve out legitimate broadcast/
multicast UDP traffic (which targets a non-unicast destination by design),
needs a deliberate answer — flagged for the project owner rather than
resolved with a reflexive equality check that could break broadcast UDP.

## Ring buffers (`socket.zig`'s UDP rings, `tcp/Socket.zig`'s `rx_buf`, `virtio/net.zig`'s DMA rings — see `drivers.md`) all use the same wrapping head/tail-index pattern

`head`/`tail` are unsigned integers that wrap via `+%=`, indexed into the
backing array with `% capacity`; "used" or "available" counts are derived
via wrapping subtraction (`tail -% head`). Any new ring buffer in this
codebase should follow the same shape rather than inventing a new one —
it's been independently re-derived correctly at least three times now
(UDP sockets, TCP sockets, virtio DMA rings) which suggests it's worth
factoring into a shared generic helper if a fourth instance appears.
