# Genesis/MegaDrive Performance Server

TCP echo server for MegaWifi cartridges that displays real-time network statistics on the Genesis VDP.

## Build

Requires SGDK toolchain and MegaWifi-enabled Genesis.

```bash
make AP_SSID="YourWifiName" AP_PASS="YourPassword"
```

Outputs: `out/perf_server.bin` (flash to cartridge)

## Protocol

1. **Handshake**: Client sends 4 bytes `[block_size BE16][num_blocks BE16]`
2. **ACK**: Server echoes handshake back
3. **Echo Loop**: For each block, server receives `block_size` raw bytes and echoes them back
4. **Done**: Client disconnects, server waits for next client

## File Structure

```
md/
├── src/
│   ├── config.h        # SGDK config (MW_BUFLEN, MODULE_MEGAWIFI)
│   └── perf_server.c   # Echo server
├── Makefile
└── out/                # Build artifacts
```

## Dependencies

- **SGDK** at `~/sgdk`
- **m68k-elf-gcc** in PATH

## Configuration

- `AP_SSID` / `AP_PASS` — WiFi credentials (build-time)
- `MW_BUFLEN` = 1460 bytes (max block size, set in config.h)
- Port 2026, TCP channel 1
- Timeouts: 10s per block, 5min for connection wait
