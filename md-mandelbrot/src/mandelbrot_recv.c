/*
 * mandelbrot_recv.c — MegaWiFi Mandelbrot Frame Receiver for Sega Genesis
 *
 * Based on perf_server.c boilerplate. Receives RLE-compressed Mandelbrot
 * frames over TCP, decodes, and DMAs tile data to VDP.
 *
 * Screen layout:
 *   During WiFi connect: text status on BG_A (same as perf_server)
 *   During frame reception: full-screen 320x224 Mandelbrot on BG_A
 */

#include <genesis.h>
#include <task.h>
#include <string.h>
#include "ext/mw/megawifi.h"
#include "ext/mw/mw-msg.h"

extern void mw_set_draw_hook(void (*hook)(void));

#define MS_TO_FRAMES(ms)  ((((ms) * 60 / 500) + 1) / 2)
#define FPS               60

#define AP_SLOT           0
#define AP_SSID           "ATThSVWdE9"
#define AP_PASS           "bnfx6wrc#zag"
#define RECV_PORT         2026
#define RECV_CH           1
#define RECV_TIMEOUT      MS_TO_FRAMES(10000)
#define CONN_TIMEOUT      (FPS * 300)

/* Screen row assignments — same as perf_server */
#define ROW_TITLE         0
#define ROW_FW            2
#define ROW_STATE         4
#define ROW_STATS         5
#define ROW_LOG_HDR       7
#define ROW_LOG_START     8
#define ROW_LOG_END       26

/* Mandelbrot tile geometry */
#define MB_TILES_X        40
#define MB_TILES_Y        28
#define MB_NUM_TILES      (MB_TILES_X * MB_TILES_Y)   /* 1120 */
#define MB_TILE_BYTES     32                           /* 8x8 x 4bpp */
#define MB_RAW_SIZE       (MB_NUM_TILES * MB_TILE_BYTES)  /* 35840 */

/* Frame header wire format (all multi-byte fields big-endian) */
#define FRAME_MAGIC       0x4D42
#define FRAME_HDR_SIZE    8

static uint16_t cmd_buf[MW_BUFLEN / 2];
static u32 tile_buf[MB_NUM_TILES * (MB_TILE_BYTES / 4)];  /* 35840 bytes */

static uint8_t fw_major = 0, fw_minor = 0;
static char fw_variant_buf[32] = "?";

static uint32_t g_sessions;
static uint32_t g_frames;

/* Mandelbrot palette — 16 colors matching CLI tool */
static const u16 mb_palette[16] = {
    RGB24_TO_VDPCOLOR(0x000000),   /*  0: transparent / black */
    RGB24_TO_VDPCOLOR(0x000090),   /*  1: deep blue */
    RGB24_TO_VDPCOLOR(0x0000FC),   /*  2: blue */
    RGB24_TO_VDPCOLOR(0x0048FC),   /*  3: sky blue */
    RGB24_TO_VDPCOLOR(0x0090FC),   /*  4: light blue */
    RGB24_TO_VDPCOLOR(0x00D8FC),   /*  5: cyan */
    RGB24_TO_VDPCOLOR(0x00FC90),   /*  6: green-cyan */
    RGB24_TO_VDPCOLOR(0x00FC00),   /*  7: green */
    RGB24_TO_VDPCOLOR(0x90FC00),   /*  8: yellow-green */
    RGB24_TO_VDPCOLOR(0xFCFC00),   /*  9: yellow */
    RGB24_TO_VDPCOLOR(0xFCD800),   /* 10: gold */
    RGB24_TO_VDPCOLOR(0xFC9000),   /* 11: orange */
    RGB24_TO_VDPCOLOR(0xFC4800),   /* 12: dark orange */
    RGB24_TO_VDPCOLOR(0xFC0000),   /* 13: red */
    RGB24_TO_VDPCOLOR(0xFC0090),   /* 14: magenta */
    RGB24_TO_VDPCOLOR(0x000000),   /* 15: interior (black) */
};

/* ---- Helpers — verbatim from perf_server.c ---- */

static void clear_row(u16 row)
{
    VDP_drawText("                                        ", 0, row);
}

static void show_state(u16 pal, const char *msg)
{
    VDP_setTextPalette(pal);
    clear_row(ROW_STATE);
    VDP_drawText(msg, 1, ROW_STATE);
    VDP_setTextPalette(PAL0);
}

static void show_stats(const char *msg)
{
    clear_row(ROW_STATS);
    VDP_drawText(msg, 1, ROW_STATS);
}

static u16 log_line = ROW_LOG_START;

static void log_msg(const char *msg)
{
    if (log_line > ROW_LOG_END) {
        for (u16 r = ROW_LOG_START; r <= ROW_LOG_END; r++)
            clear_row(r);
        log_line = ROW_LOG_START;
    }
    VDP_setTextPalette(PAL3);
    clear_row(log_line);
    VDP_drawText(msg, 1, log_line);
    VDP_setTextPalette(PAL0);
    log_line++;
}

/* ---- MegaWifi init — verbatim from perf_server.c ---- */

static void user_tsk(void)
{
    while (1) mw_process();
}

static bool megawifi_init(void)
{
    char *variant = NULL;
    struct mw_ip_cfg dhcp_cfg = { {0}, {0}, {0}, {0}, {0} };
    enum mw_err err;

    if (mw_init(cmd_buf, MW_BUFLEN) != MW_ERR_NONE) return false;
    TSK_userSet(user_tsk);

    err = mw_detect(&fw_major, &fw_minor, &variant);
    if (err != MW_ERR_NONE) return false;
    if (variant) {
        uint8_t i;
        for (i = 0; i < sizeof(fw_variant_buf) - 1 && variant[i]; i++)
            fw_variant_buf[i] = variant[i];
        fw_variant_buf[i] = '\0';
    }

    err = mw_ap_cfg_set(AP_SLOT, AP_SSID, AP_PASS, MW_PHY_11BGN);
    if (err != MW_ERR_NONE) return false;

    err = mw_ip_cfg_set(AP_SLOT, &dhcp_cfg);
    if (err != MW_ERR_NONE) return false;

    err = mw_cfg_save();
    if (err != MW_ERR_NONE) return false;

    err = mw_ap_assoc(AP_SLOT);
    if (err != MW_ERR_NONE) return false;

    err = mw_ap_assoc_wait(30 * FPS);
    if (err != MW_ERR_NONE) return false;

    mw_sleep(3 * 60);

    return true;
}

/* ---- RLE streaming decoder ---- */

struct rle_dec {
    uint8_t token;
    uint8_t state;    /* 0=normal, 1=got_token, 2=got_count */
    uint8_t count;
    uint8_t *out;
    u32 out_pos;
    u32 out_max;
};

static void rle_init(struct rle_dec *d, uint8_t token, uint8_t *out, u32 max)
{
    d->token   = token;
    d->state   = 0;
    d->count   = 0;
    d->out     = out;
    d->out_pos = 0;
    d->out_max = max;
}

static void rle_feed(struct rle_dec *d, const uint8_t *in, u16 len)
{
    u16 i;
    for (i = 0; i < len && d->out_pos < d->out_max; i++) {
        uint8_t b = in[i];
        switch (d->state) {
        case 0:
            if (b == d->token) {
                d->state = 1;
            } else {
                d->out[d->out_pos++] = b;
            }
            break;
        case 1:
            d->count = b;
            d->state = 2;
            break;
        case 2: {
            uint8_t j;
            for (j = 0; j < d->count && d->out_pos < d->out_max; j++)
                d->out[d->out_pos++] = b;
            d->state = 0;
            break;
        }
        }
    }
}

/* ---- Mandelbrot VDP setup ---- */

static void setup_mandelbrot_display(void)
{
    u16 col, row;

    /* Load Mandelbrot palette into PAL1 (indices 16-31) */
    PAL_setColors(PAL1 * 16, mb_palette, 16, CPU);

    /* Set up sequential tilemap on BG_A — each visible tile position
     * maps to TILE_USER_INDEX + sequential index, using PAL1 */
    for (row = 0; row < MB_TILES_Y; row++) {
        for (col = 0; col < MB_TILES_X; col++) {
            u16 tile_idx = row * MB_TILES_X + col;
            u16 attr = TILE_ATTR_FULL(PAL1, FALSE, FALSE, FALSE,
                                       TILE_USER_INDEX + tile_idx);
            VDP_setTileMapXY(BG_A, attr, col, row);
        }
    }
}

/* ---- Server loop ---- */

static void server_loop(void)
{
    char dbg[40];
    bool display_ready = FALSE;

    for (;;) {
        enum mw_err err;

        /* Bind — same pattern as perf_server */
        show_state(PAL0, "Binding port 2026...");
        log_msg("tcp_bind...");
        if (mw_tcp_bind(RECV_CH, RECV_PORT) != MW_ERR_NONE) {
            show_state(PAL2, "Bind FAILED");
            log_msg("Bind failed, retry in 2s");
            for (u8 i = 0; i < 120; i++) VDP_waitVSync();
            continue;
        }
        log_msg("Bind OK, waiting for client");

        /* Wait for connection — same pattern as perf_server */
        show_state(PAL0, "Waiting for client...");
        if (mw_sock_conn_wait(RECV_CH, CONN_TIMEOUT) != MW_ERR_NONE) {
            log_msg("conn_wait timeout/err");
            goto disc;
        }

        g_sessions++;
        sprintf(dbg, "Client #%d connected", (int)g_sessions);
        show_state(PAL1, dbg);
        log_msg(dbg);

        /* Send "ready" signal — tells client we're listening.
         * Without this, the client floods data before we arm
         * lsd_recv and the UART FIFO overflows. Same principle
         * as perf_server's handshake ACK. */
        {
            uint8_t ready = 0x06;
            err = mw_send_sync(RECV_CH, (const char *)&ready, 1,
                               RECV_TIMEOUT);
            if (err != MW_ERR_NONE) {
                log_msg("Ready send failed");
                goto disc;
            }
        }

        /* Frame receive loop — receive frames until disconnect */
        for (;;) {
            uint8_t hdr_bytes[FRAME_HDR_SIZE];
            uint16_t magic, payload, tiles;
            uint8_t token;
            struct rle_dec dec;

            /* Receive 8-byte frame header — same recv pattern as perf_server */
            {
                int16_t got = 0;
                while (got < FRAME_HDR_SIZE) {
                    uint8_t ch = RECV_CH;
                    int16_t chunk = FRAME_HDR_SIZE - got;
                    err = mw_recv_sync(&ch, (char *)hdr_bytes + got,
                                       &chunk, RECV_TIMEOUT);
                    if (err != MW_ERR_NONE || chunk <= 0) {
                        if (g_frames > 0) {
                            log_msg("Client disconnected");
                        } else {
                            log_msg("Header recv failed");
                        }
                        goto disc;
                    }
                    got += chunk;
                }
            }

            /* Parse header — big-endian wire format */
            magic   = ((uint16_t)hdr_bytes[0] << 8) | hdr_bytes[1];
            token   = hdr_bytes[2];
            /* flags = hdr_bytes[3]; */
            payload = ((uint16_t)hdr_bytes[4] << 8) | hdr_bytes[5];
            tiles   = ((uint16_t)hdr_bytes[6] << 8) | hdr_bytes[7];

            if (magic != FRAME_MAGIC) {
                sprintf(dbg, "Bad magic: 0x%04X", (int)magic);
                log_msg(dbg);
                goto disc;
            }

            if (tiles != MB_NUM_TILES || payload == 0) {
                sprintf(dbg, "Bad frame: t=%d p=%d", (int)tiles, (int)payload);
                log_msg(dbg);
                goto disc;
            }

            /* Set up display on first frame */
            if (!display_ready) {
                setup_mandelbrot_display();
                display_ready = TRUE;
            }

            /* Stream-receive RLE payload, decode into tile_buf */
            rle_init(&dec, token, (uint8_t *)tile_buf, MB_RAW_SIZE);

            {
                u16 remaining = payload;
                while (remaining > 0) {
                    uint8_t ch = RECV_CH;
                    int16_t chunk = (remaining > (u16)MW_BUFLEN)
                                    ? (int16_t)MW_BUFLEN
                                    : (int16_t)remaining;
                    err = mw_recv_sync(&ch, (char *)cmd_buf,
                                       &chunk, RECV_TIMEOUT);
                    if (err != MW_ERR_NONE || chunk <= 0) {
                        sprintf(dbg, "Payload recv err=%d", (int)err);
                        log_msg(dbg);
                        goto disc;
                    }
                    rle_feed(&dec, (uint8_t *)cmd_buf, (u16)chunk);
                    remaining -= (u16)chunk;
                }
            }

            /* DMA tile data to VRAM */
            VDP_loadTileData(tile_buf, TILE_USER_INDEX,
                             MB_NUM_TILES, DMA);
            VDP_waitDMACompletion();

            g_frames++;
            sprintf(dbg, "Frame %d (%d bytes)",
                    (int)g_frames, (int)payload);
            show_stats(dbg);

            /* ACK frame — tell client we're done so it can close cleanly */
            {
                uint8_t ack = 0x06;
                mw_send_sync(RECV_CH, (const char *)&ack, 1,
                             RECV_TIMEOUT);
            }
        }

disc:
        /* Same disconnect handling as perf_server */
        log_msg("Closing socket...");
        mw_close(RECV_CH);
        /* Fixed delay — give ESP32 lwIP TCP stack time to fully
         * release the socket before we attempt to rebind.
         * Polling with mw_sock_stat_get() after close interferes
         * with the LSD command channel. */
        {
            u16 i;
            for (i = 0; i < 180; i++) VDP_waitVSync();  /* 3 seconds */
        }
        log_msg("Ready to rebind");
    }
}

int main(bool hard_reset)
{
    (void)hard_reset;

    /* --- VDP setup — same as perf_server, no per-tile scroll needed ---- */
    VDP_setScreenWidth320();
    VDP_setPlaneSize(64, 32, TRUE);
    VDP_setScrollingMode(HSCROLL_PLANE, VSCROLL_PLANE);
    VDP_clearPlane(BG_A, TRUE);
    VDP_clearPlane(BG_B, TRUE);

    /* PAL0: black bg + white text */
    PAL_setColor(0,  RGB24_TO_VDPCOLOR(0x000000));
    PAL_setColor(15, RGB24_TO_VDPCOLOR(0xFFFFFF));
    /* PAL1: green text */
    PAL_setColor(31, RGB24_TO_VDPCOLOR(0x00CC00));
    /* PAL2: red text */
    PAL_setColor(47, RGB24_TO_VDPCOLOR(0xFF2020));
    /* PAL3: blue log text */
    PAL_setColor(63, RGB24_TO_VDPCOLOR(0x00AAFF));
    VDP_waitVSync();

    /* --- Initial title --- */
    VDP_setTextPalette(PAL0);
    VDP_drawText("[ MegaWifi Mandelbrot ]", 0, ROW_TITLE);
    JOY_init();

    show_state(PAL0, "Connecting to WiFi...");
    if (!megawifi_init()) {
        show_state(PAL2, "WiFi init FAILED");
        while (1) VDP_waitVSync();
    }

    {
        struct mw_ip_cfg *ip = NULL;
        if (mw_ip_current(&ip) == MW_ERR_NONE && ip) {
            uint32_t a = ip->addr.addr;
            char buf[42];
            sprintf(buf, "[ Mandelbrot %d.%d.%d.%d:%d ]",
                    (int)((a >> 24) & 0xFF), (int)((a >> 16) & 0xFF),
                    (int)((a >> 8) & 0xFF), (int)(a & 0xFF), RECV_PORT);
            VDP_drawText(buf, 0, ROW_TITLE);
        }
    }

    {
        char buf[40];
        sprintf(buf, "FW %d.%d %s", (int)fw_major, (int)fw_minor,
                fw_variant_buf);
        clear_row(ROW_FW);
        VDP_drawText(buf, 1, ROW_FW);
    }

    VDP_drawText("--- Log ---", 1, ROW_LOG_HDR);

    server_loop();
    return 0;
}
