# Mandelbrot Demo — Design Document

Full-screen 16-color Mandelbrot set computed in fixed-point on the ESP32-C3
RISC-V core and streamed over the LSD serial link to the Genesis VDP.

```
   m68k (7.67 MHz)                    C99 CLI / ESP32-C3 (160 MHz)
  ┌─────────────────┐                ┌──────────────────────────┐
  │ VDP tile DMA     │◄── TCP/LSD ───│ Q4.28 fixed-point math  │
  │ RLE decode       │               │ RLE encode              │
  │ D-pad/zoom input │──────────────►│ Mandelbrot iteration    │
  │ Palette cycling  │               │ Tile-order output       │
  └─────────────────┘                └──────────────────────────┘
```

**Standalone ROM** — separate from the echo server. No background image,
no text overlay during render. Full screen (320×224) dedicated to the
Mandelbrot set. The echo server ROM is preserved as-is as a TCP
boilerplate example.

---

## Display Target

| Parameter     | Value                            |
|---------------|----------------------------------|
| Resolution    | 320×224 px (NTSC)                |
| Tile grid     | 40×28 tiles (8×8 px each)        |
| Color depth   | 4bpp (16 colors per palette)     |
| Total tiles   | 1,120                            |
| Tile data     | 1,120 × 32 bytes = 35,840 bytes  |
| Tilemap       | 1,120 × 2 bytes = 2,240 bytes    |
| Raw total     | 38,080 bytes (~37.2 KB)          |

**VDP layout:** Single plane (BG_A), full screen. No BG_B, no text
overlay, no sprites. One palette (PAL0) with 16 Mandelbrot colors.
Minimal status (if any) written to a single row during transfers,
cleared when render completes.

---

## Fixed-Point Arithmetic

**Format: Q4.28** (signed 32-bit: 4 integer bits, 28 fractional bits)

| Property          | Value                              |
|-------------------|------------------------------------|
| Range             | -8.0 to +7.999 999 996            |
| Precision         | 1/2²⁸ ≈ 3.73 × 10⁻⁹              |
| Mandelbrot range  | real: -2.0 to +1.0, imag: ±1.5    |
| Max zoom          | ~2,500,000:1 before precision loss |

Core iteration (2 multiplies + shifts per iteration):

```c
int32_t zr = 0, zi = 0;
for (int i = 0; i < max_iter; i++) {
    int32_t zr2 = (int32_t)(((int64_t)zr * zr) >> 28);
    int32_t zi2 = (int32_t)(((int64_t)zi * zi) >> 28);
    if (zr2 + zi2 > (4 << 28)) break;
    zi = (int32_t)(((int64_t)zr * zi) >> 27) + ci;
    zr = zr2 - zi2 + cr;
}
```

RISC-V `MUL`/`MULH` give 32×32→64 in ~2 cycles. Per iteration: ~16 cycles.

---

## RLE Compression

### Constraints

- **Byte-aligned only.** The 68000 has no barrel shifter — variable bit
  shifts cost 2 cycles per bit. Fixed nibble shifts (`ROR #4`) are fine
  for 4bpp pixel packing, but the RLE stream itself must be byte-granular.
- **Token byte chosen per frame.** Scan the encoded tile data, pick the
  least-used byte value (ideally one that never appears). Include it in
  the frame header so the decoder knows the escape character.
- **No recovery from broken transfers.** If data stops mid-frame, the
  Genesis times out (2 VBlanks with no data), resets state, and waits
  for a new frame header. Simpler than checksums/retransmit — just
  start over.

### Encoding format

```
Byte in stream:
  if byte != TOKEN:  literal byte, write as-is
  if byte == TOKEN:  read next two bytes → [count:u8][value:u8]
                     write value × count times
```

m68k decode inner loop is just `cmpi.b`, branch, `dbra` — fast and simple.

### Tile stripe order: why tile-order wins

The Mandelbrot is computed in scanline order (best for the math), but the
VDP wants tile-format data.  Three options for the RLE stream order:

**Option A: Scanline-order RLE → m68k tile conversion**
- Best compression (~8:1) — long horizontal runs cross tile boundaries
- But m68k must scatter-write: for each pixel, compute tile column,
  row offset within tile, nibble position, shift, and OR into buffer
- 71,680 scatter-writes at ~20 cycles each = ~1.4M cycles = 0.19 s
  decode overhead, plus the code complexity is significant

**Option B: Tile-order RLE → direct to VRAM buffer**
- Worse compression (~4–5:1) — runs limited to 32 bytes within a tile
- But m68k decode is trivial sequential writes — each decoded tile is
  32 contiguous bytes, ready for DMA to VRAM
- 35,840 bytes at ~6 cycles/byte decode = ~215K cycles = 0.03 s
- **6× faster decode than scanline order**

**Option C: Tile-row-scanline interleave**
- For each tile-row: send 8 scanlines, each as 40 groups of 4 bytes
  (one tile-row-slice per group)
- Moderate compression, moderate decode complexity
- No real advantage over pure tile-order

**Decision: Tile-order (Option B).** The compression is worse on paper,
but the decode cost difference (0.03 s vs 0.19 s) matters more than
saving ~3 KB of transfer when the serial link is the bottleneck anyway.
And the code is far simpler — no scatter-writes, no nibble bookkeeping,
just a linear decode loop followed by DMA.

Tile-order also compresses better than the raw numbers suggest because
Mandelbrot tiles have internal coherence:
- Solid tiles (all one color): 32 bytes of 0xCC → `TOKEN 32 0xCC` = 3 bytes
- Horizontal-band tiles: rows repeat → multi-byte runs within the tile
- Even boundary tiles have repeated row patterns

### Compression estimates (tile-order)

| Region              | Screen % | Raw bytes | RLE ratio | RLE bytes |
|---------------------|----------|-----------|-----------|-----------|
| Interior (solid)    | ~30%     | 10,752    | ~10:1     | ~1,075    |
| Smooth bands        | ~45%     | 16,128    | ~6:1      | ~2,688    |
| Boundary detail     | ~25%     | 8,960     | ~2:1      | ~4,480    |
| **Total**           | **100%** | **35,840**| **~4.3:1**| **~8,243**|

Estimated transfer payload: **~8 KB** per frame in tile-order.
At 11.6 KB/s (echo): ~0.7 s transfer. At streaming rates: potentially
~0.2–0.3 s.

---

## Frame Protocol

### Design principles

- **Token + payload size starts every valid frame.** The m68k state
  machine only leaves IDLE when it sees a valid header.
- **No error recovery.** If a transfer breaks mid-frame, the Genesis
  times out and resets. The sender just sends a new complete frame.
  This keeps the protocol trivially simple and guarantees correctness.
- **Timeout: 2 VBlanks (~33 ms).** If no data arrives within 2 frames
  after the state machine is armed, reset to IDLE, clear screen, and
  wait for a new frame header.

### Frame format

```
┌─────────────────────────────────────────────────────┐
│ HEADER (4 bytes)                                    │
│   [0] token:u8      RLE escape byte for this frame  │
│   [1] flags:u8      reserved (0x00)                 │
│   [2] payload:u16   big-endian, total RLE bytes     │
├─────────────────────────────────────────────────────┤
│ RLE DATA (payload bytes)                            │
│   Tile-order: tile 0 (32 bytes decoded) ...         │
│   ... tile 1119 (32 bytes decoded)                  │
│   Total decoded: 35,840 bytes (1120 × 32)           │
│                                                     │
│   Byte semantics:                                   │
│     byte != token  →  literal, write as-is          │
│     byte == token  →  next two bytes: [count][value]│
│                       write value × count           │
└─────────────────────────────────────────────────────┘
```

### Genesis state machine

```
         ┌──────────┐
    ┌───►│  IDLE    │◄──── timeout (2 VBlanks)
    │    └────┬─────┘      or transfer complete
    │         │ recv 4-byte header
    │         ▼
    │    ┌──────────┐
    │    │ RECEIVE  │ armed: expecting `payload` bytes
    │    │          │ decoding RLE into tile buffer
    │    └────┬─────┘
    │         │ all payload bytes received
    │         ▼
    │    ┌──────────┐
    │    │ DMA      │ blast tile buffer → VRAM
    │    └────┬─────┘
    │         │ DMA complete
    └─────────┘
```

No ACKs, no handshake, no retransmit. The sender pushes frames.
The receiver either gets a complete frame or times out and resets.

---

## Pipeline Timing

### Per-stage costs (tile-order RLE, ~8 KB payload)

| Stage                  | Work                                     | Time      |
|------------------------|------------------------------------------|-----------|
| Compute (ESP32/CLI)    | 71,680 px × 50 avg iter × 16 cyc        | 0.36 s    |
| RLE encode             | scan 35,840 bytes, emit ~8 KB            | ~0.01 s   |
| Serial transfer        | ~8 KB at 11.6 KB/s (echo baseline)       | 0.69 s    |
| m68k RLE decode        | sequential byte decode (no scatter-write) | 0.03 s   |
| VDP DMA                | 35,840 bytes at ~6.8 MB/s                | ~0.005 s  |

### Non-pipelined (sequential)

```
Compute ──► RLE encode ──► serial TX ──► m68k decode ──► DMA
 0.36s         0.01s         0.69s          0.03s        0.005s
                                                  Total: ~1.1 s
```

### With streaming throughput (TBD)

The echo test measures worst-case synchronous throughput. One-way push
(sender streams, Genesis receives continuously) eliminates per-block
round-trip overhead and should be significantly faster.

| Mode                     | Bandwidth  | ~8 KB RLE | Total w/compute |
|--------------------------|------------|-----------|-----------------|
| Echo sync (measured)     | 11.6 KB/s  | 0.69 s    | ~1.1 s          |
| Streaming (est. 25% raw) | ~36 KB/s  | 0.22 s    | ~0.6 s          |
| Streaming (est. 50% raw) | ~73 KB/s  | 0.11 s    | ~0.5 s          |
| Raw serial (theoretical) | 146 KB/s  | 0.05 s    | ~0.4 s          |

**Unknown:** actual streaming throughput. Must benchmark before optimizing.
The prototype phase will establish this number.

---

## Interaction Model

D-pad pan, A/B zoom in/out. Each input triggers a new render.

| Input   | Action         |
|---------|----------------|
| D-pad   | Pan viewport   |
| A       | Zoom in 2×     |
| B       | Zoom out 2×    |
| Start   | Reset to default view |
| C       | Cycle palette  |

At ~0.4–0.9 s per frame, interaction feels like "step and wait" — each
button press triggers a new computation, with progressive display as
tile-rows stream in top-to-bottom.

---

## Rendering Strategy

### Option A: Full-frame compute, then stream

ESP32 computes entire frame, RLE encodes, streams to Genesis.
Simpler protocol. Frame time = compute + transfer.

### Option B: Row-by-row pipeline

ESP32 computes 8-scanline tile-rows and streams each immediately.
Genesis decodes and DMAs while ESP32 computes next row.
Visual: top-to-bottom wipe effect. Frame time ≈ max(compute, transfer).

### Option C: Progressive refinement

Pass 1: 16 solid-color tiles pre-loaded. ESP32 sends only tilemap
(2,240 bytes) based on center-pixel iteration per tile.
**Time: ~0.03 s compute + ~0.19 s transfer = ~0.22 s** for blocky preview.

Pass 2: stream unique boundary tiles only (est. 200–400 tiles).
**Time: ~0.1 s compute + ~0.3 s transfer = ~0.4 s** for detail fill.

Total: **~0.6 s** with instant visual feedback at 0.2 s.

---

## Color Palette

16 colors in one Genesis palette (PAL0 or PAL1):

| Index | Purpose                          |
|-------|----------------------------------|
| 0     | Transparent (VDP convention)     |
| 1–14  | Escape-time gradient (14 bands)  |
| 15    | Interior (iteration = max_iter)  |

Iteration-to-color mapping: `color = (iter % 14) + 1` for escaped
pixels, `15` for interior. Palette cycling (button C) rotates
indices 1–14 for the classic animated Mandelbrot effect — no
recomputation needed, just palette register writes.

---

## Development Strategy: C99 CLI Prototype → ESP32 Port

The prototype is a **standalone C99 command-line tool** that connects to the
Genesis echo server over TCP and pushes computed Mandelbrot frames.  This
keeps the compute + RLE code in pure C99 with no platform dependencies,
matching the ESP32 `mw-fw-rtos` toolchain (GCC, C99, no stdlib bloat).

```
Phase 1: C99 CLI prototype (macOS)        Phase 2: ESP32 firmware
┌────────────────────────┐                ┌────────────────────────┐
│ mandelbrot.c           │                │ mw-fw-rtos/main/       │
│  - Q4.28 fixed-point   │───identical───►│  mandelbrot.c          │
│  - RLE encoder         │   C99 code     │  (same compute + RLE)  │
│  - tile packer         │                │                        │
│  - BSD socket push     │                │  MW_CMD_MANDELBROT     │
│  - CLI params for view │                │  (LSD channel output)  │
└────────────────────────┘                └────────────────────────┘
```

**Why CLI, not the Cocoa app:**
- C99 compute code ports to ESP32 with zero changes
- Same fixed-point types, same RLE format, same tile layout
- Fast iteration: `cc mandelbrot.c -o mb && ./mb 192.168.1.199`
- No Objective-C / framework dependencies to strip out later
- Can also dump tiles to a file for offline inspection

**Prototype scope:**
- `mandelbrot.c` — single-file C99, compiles with `cc -std=c99 -O2`
- Takes CLI args: `host`, `port`, `center_x`, `center_y`, `zoom`
- Computes full frame, RLE encodes, sends to Genesis via TCP
- **New Genesis ROM** (`md-mandelbrot/`) — dedicated Mandelbrot receiver,
  not the echo server. Connects to WiFi, binds TCP, receives RLE tile
  stream, decodes, DMAs to VDP. Full screen, no background image.

---

## Open Questions

1. **Streaming throughput**: Need to benchmark one-way push through
   `mw_recv_sync()` — is it closer to 36 KB/s or 73 KB/s?  The C99
   prototype will establish this immediately.
2. **Max iterations**: 256 baseline. Higher gives better deep-zoom
   detail but linearly increases compute time. Tunable at runtime.
3. **Palette design**: 14 gradient colors + black interior + transparent.
   Need to pick a gradient that looks good on Genesis hardware (9-bit
   RGB, 3 bits per channel = 512 possible colors).
4. **Frame time target**: Push as fast as possible first, then decide
   what interaction model works at the achieved speed.

---

## Implementation Path

### Phase 1: C99 CLI prototype (macOS, pure C99)

1. `mandelbrot.c` — Q4.28 fixed-point compute, tile-order output
2. `rle.c` — byte-level RLE encoder with per-frame token selection
3. TCP push to Genesis using existing echo protocol (temporary)
4. Dump mode — write raw tiles + RLE to file for offline inspection
5. Verify tile packing, palette mapping, RLE correctness on desktop

### Phase 2: Genesis receiver ROM (m68k, SGDK)

6. New ROM (`md-mandelbrot/`) — WiFi connect, TCP bind, receive loop
7. Frame protocol state machine (IDLE → RECEIVE → DMA → IDLE)
8. 2-VBlank timeout with full state reset on broken transfer
9. RLE decoder — sequential byte decode, write to tile buffer
10. VDP DMA — blast decoded tiles to VRAM
11. Palette setup — 16 Mandelbrot colors in PAL0

### Phase 3: Integration + benchmarking

12. CLI pushes frame, Genesis displays it — first pixels on screen
13. Measure actual streaming throughput and frame time
14. Iterate: tune palette, RLE, transfer chunking

### Phase 4: Interaction

15. D-pad pan / A,B zoom on Genesis, send input back to CLI
16. CLI recomputes and pushes new frame
17. Palette cycling (button C) — local on Genesis, no recompute

### Phase 5: ESP32 port

18. Lift `mandelbrot.c` + `rle.c` into `mw-fw-rtos` as new MW command
19. Genesis ROM talks to local ESP32 instead of TCP — no PC needed
20. Self-contained Mandelbrot cartridge demo
