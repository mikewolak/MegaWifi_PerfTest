# MegaWifi Perf Test — TODO

## Bugs

### Genesis server enters "Bind failed" loop on client disconnect during continuous test
When the macOS client stops a continuous test mid-session, the Genesis server
falls through to `mw_close()` but the subsequent `mw_tcp_bind()` fails
repeatedly with "Bind failed, retry in 2s". The socket/channel is not being
fully released before the next bind attempt. Requires investigation into
whether `mw_close()` needs a delay, a status poll, or a full channel teardown
before re-binding.

## ESP32-C3 Co-processor Opportunities

The ESP32-C3 has hardware accelerators that are present but **not exposed**
as MegaWifi commands. Available command slots: 7, 16, 19, 48, 59-254.

### Crypto offload (HW accelerated)
- **AES 128/256** — encrypt/decrypt up to 1456 bytes per call
- **SHA-1/256** — hash offload for data integrity
- **HMAC** — authenticated message signing
- **MPI (big integer)** — RSA/ECC math, large number arithmetic

### Computation offload
- **Math coprocessor** — RISC-V 160 MHz can do float/bigint the m68k cannot
- **JSON parsing** — firmware already has a JSON parser, could expose it
- **DNS resolve** — standalone hostname resolution command

### Implementation path
1. Pick unused command slot in `main/megawifi.c` (`MwFsmCmdProc` dispatcher)
2. Define message structure in `main/mw-msg.h`
3. Add m68k-side API wrapper in MegaWifi library
4. Constraints: 1456 byte max payload, ~188 KB/s serial, synchronous dispatch
