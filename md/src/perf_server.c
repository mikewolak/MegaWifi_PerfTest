/*
 * perf_server.c — MegaWiFi TCP Echo Server for Performance Testing
 *
 * Pure sync I/O version with diagnostic display.
 * Based on stock_ticker init structure.
 *
 * Screen layout (40x28 tiles):
 *   Row  0: Title / IP:port
 *   Row  1: (blank separator — BG_B visible)
 *   Row  2: Firmware version
 *   Row  3: (blank separator — BG_B visible)
 *   Row  4: STATE — current server state (bind/wait/connected/echoing)
 *   Row  5: STATS — sessions / total bytes / progress
 *   Row  6: (blank separator — BG_B visible)
 *   Row  7: --- Log ---  (header)
 *   Row  8-26: Scrolling diagnostic log (BG_B visible through text)
 *   Row 27: (blank — BG_B visible)
 *
 * BG_B: girl.png tiled 128x128 (16x16 tiles), diagonal scroll +1X +1Y/frame
 * BG_A: text overlay, header rows masked with solid black tiles
 */

#include <genesis.h>
#include <task.h>
#include <string.h>
#include "ext/mw/megawifi.h"
#include "ext/mw/mw-msg.h"
#include "girl_gfx.h"

extern void mw_set_draw_hook(void (*hook)(void));

#define MS_TO_FRAMES(ms)  ((((ms) * 60 / 500) + 1) / 2)
#define FPS               60

#define AP_SLOT           0
#define AP_SSID           "ATThSVWdE9"
#define AP_PASS           "bnfx6wrc#zag"
#define PERF_PORT         2026
#define PERF_CH           1
#define ECHO_TIMEOUT      MS_TO_FRAMES(10000)
#define CONN_TIMEOUT      (FPS * 300)

/* Screen row assignments — each has a dedicated purpose */
#define ROW_TITLE         0
#define ROW_FW            2
#define ROW_STATE         4
#define ROW_STATS         5
#define ROW_LOG_HDR       7
#define ROW_LOG_START     8
#define ROW_LOG_END       26

static uint16_t cmd_buf[MW_BUFLEN / 2];

static uint8_t fw_major = 0, fw_minor = 0;
static char fw_variant_buf[32] = "?";

static uint32_t g_sessions;
static uint32_t g_total_bytes;

/* ---- Diagonal background scroll state ---- */
static bool bg_active = FALSE;
static s16 bgb_hscroll[32];

/* ---- Helpers ---- */

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

/* ---- Background scroll — draw hook (fires every frame via megawifi.c) ---- */

static void fetch_draw_hook(void)
{
    static u32 last_frame = 0;
    u32 frame;
    s16 neg_scroll, bg_sx, bg_sy;
    u16 i;

    if (!bg_active) return;

    /* Derive scroll position from vtimer (VBlank frame counter).
     * vtimer increments exactly once per VBlank. Guard against
     * multiple calls within the same frame. */
    frame = vtimer;
    if (frame == last_frame) return;
    last_frame = frame;

    bg_sx = (s16)(frame & 0x1FF);      /* wrap at 512 px (nametable width)  */
    bg_sy = (s16)(frame & 0xFF);       /* wrap at 256 px (nametable height) */

    neg_scroll = -(s16)bg_sx;
    for (i = 0; i < 32; i++) bgb_hscroll[i] = neg_scroll;
    VDP_setHorizontalScrollTile(BG_B, 0, bgb_hscroll, 32, DMA);
    VDP_setVerticalScroll(BG_B, bg_sy);
}

/* ---- Background init ---- */

static void init_girl_bg(void)
{
    u16 col, row;

    /* Load girl palette into PAL3 (colours 48-62) */
    PAL_setColors(PAL3 * 16, girl_palette, 15, CPU);
    /* Keep PAL3[15] (colour 63) = blue for log text */
    PAL_setColor(63, RGB24_TO_VDPCOLOR(0x00AAFF));

    /* Load girl tile data to VRAM at TILE_USER_INDEX */
    VDP_loadTileData(girl_tiles, TILE_USER_INDEX, GIRL_NUM_TILES, DMA);
    VDP_waitDMACompletion();

    /* Tile BG_B (64×32) with 16×16 girl pattern
     * 64÷16 = 4 reps horizontal, 32÷16 = 2 reps vertical — seamless wrap */
    for (row = 0; row < 32; row++) {
        for (col = 0; col < 64; col++) {
            u16 src_x    = col % GIRL_TILES_X;
            u16 src_y    = row % GIRL_TILES_Y;
            u16 tile_idx = girl_tilemap[src_y][src_x];
            u16 attr     = TILE_ATTR_FULL(PAL3, FALSE, FALSE, FALSE,
                                          TILE_USER_INDEX + tile_idx);
            VDP_setTileMapXY(BG_B, attr, col, row);
        }
    }

    /* Initialise scroll tables */
    {
        u16 i;
        s16 zero = 0;
        for (i = 0; i < 32; i++) bgb_hscroll[i] = 0;
        VDP_setHorizontalScrollTile(BG_B, 0, bgb_hscroll, 32, DMA);
        VDP_setHorizontalScrollTile(BG_A, 0, &zero, 1, CPU);
        VDP_setVerticalScroll(BG_B, 0);
    }
}

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

/* ---- Server ---- */

static void server_loop(void)
{
    char dbg[40];

    for (;;) {
        enum mw_err err;
        uint16_t blk_sz, num_blks;

        show_state(PAL0, "Binding port 2026...");
        log_msg("tcp_bind...");
        if (mw_tcp_bind(PERF_CH, PERF_PORT) != MW_ERR_NONE) {
            show_state(PAL2, "Bind FAILED");
            log_msg("Bind failed, retry in 2s");
            for (u8 i = 0; i < 120; i++) VDP_waitVSync();
            continue;
        }
        log_msg("Bind OK, waiting for client");

        show_state(PAL0, "Waiting for client...");
        if (mw_sock_conn_wait(PERF_CH, CONN_TIMEOUT) != MW_ERR_NONE) {
            log_msg("conn_wait timeout/err");
            goto disc;
        }

        g_sessions++;
        sprintf(dbg, "Client #%d connected", (int)g_sessions);
        show_state(PAL1, dbg);
        log_msg(dbg);

        /* Receive handshake — arm recv immediately, no intervening
         * mw_command calls that could eat data on ch1 */
        {
            uint8_t ch = PERF_CH;
            int16_t len = 4;
            log_msg("recv handshake...");
            err = mw_recv_sync(&ch, (char *)cmd_buf, &len, ECHO_TIMEOUT);
            sprintf(dbg, "recv: err=%d ch=%d len=%d", (int)err, (int)ch, (int)len);
            log_msg(dbg);

            if (err != MW_ERR_NONE || len < 4) {
                log_msg("Handshake recv FAILED");
                goto disc;
            }
        }

        {
            uint8_t *hs = (uint8_t *)cmd_buf;
            blk_sz   = ((uint16_t)hs[0] << 8) | hs[1];
            num_blks = ((uint16_t)hs[2] << 8) | hs[3];
            sprintf(dbg, "hs: blk=%d num=%d", (int)blk_sz, (int)num_blks);
            log_msg(dbg);
        }

        if (blk_sz == 0 || blk_sz > MW_BUFLEN) {
            log_msg("Bad block size");
            goto disc;
        }

        /* ACK handshake */
        err = mw_send_sync(PERF_CH, (const char *)cmd_buf, 4, ECHO_TIMEOUT);
        sprintf(dbg, "hs ack send: err=%d", (int)err);
        log_msg(dbg);
        if (err != MW_ERR_NONE) goto disc;

        sprintf(dbg, "Echo %dB x %d", (int)blk_sz, (int)num_blks);
        show_state(PAL1, dbg);

        /* Echo loop — pure sync */
        {
            uint32_t b;
            for (b = 0; b < num_blks; b++) {
                int16_t got = 0;

                while (got < (int16_t)blk_sz) {
                    uint8_t c = PERF_CH;
                    int16_t chunk = blk_sz - got;
                    err = mw_recv_sync(&c, (char *)cmd_buf + got,
                                       &chunk, ECHO_TIMEOUT);
                    if (err != MW_ERR_NONE || chunk <= 0) {
                        sprintf(dbg, "blk %ld recv err=%d got=%d",
                                (long)b, (int)err, (int)got);
                        log_msg(dbg);
                        goto disc;
                    }
                    got += chunk;
                }

                err = mw_send_sync(PERF_CH, (const char *)cmd_buf,
                                   blk_sz, ECHO_TIMEOUT);
                if (err != MW_ERR_NONE) {
                    sprintf(dbg, "blk %ld send err=%d", (long)b, (int)err);
                    log_msg(dbg);
                    goto disc;
                }

                g_total_bytes += blk_sz;

                if ((b & 15) == 0) {
                    sprintf(dbg, "S:%d B:%ld [%ld/%d]",
                            (int)g_sessions, (long)g_total_bytes,
                            (long)(b + 1), (int)num_blks);
                    show_stats(dbg);
                }
            }
        }

        sprintf(dbg, "S:%d B:%ld Done",
                (int)g_sessions, (long)g_total_bytes);
        show_stats(dbg);
        show_state(PAL1, "Session complete");
        log_msg("Session OK");

disc:
        log_msg("Closing socket...");
        mw_close(PERF_CH);
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

    /* --- VDP setup ---- */
    VDP_setScreenWidth320();
    VDP_setPlaneSize(64, 32, TRUE);
    /* HSCROLL_TILE: per tile-row H-scroll — BG_A rows stay at 0 (static text),
     * BG_B all rows scroll together for diagonal background. */
    VDP_setScrollingMode(HSCROLL_TILE, VSCROLL_PLANE);
    VDP_clearPlane(BG_A, TRUE);
    VDP_clearPlane(BG_B, TRUE);

    /* PAL0: black bg + white text */
    PAL_setColor(0,  RGB24_TO_VDPCOLOR(0x000000));
    PAL_setColor(15, RGB24_TO_VDPCOLOR(0xFFFFFF));
    /* PAL1: green text */
    PAL_setColor(31, RGB24_TO_VDPCOLOR(0x00CC00));
    /* PAL2: red text */
    PAL_setColor(47, RGB24_TO_VDPCOLOR(0xFF2020));
    /* PAL3: blue text (girl bg palette loaded later by init_girl_bg) */
    PAL_setColor(63, RGB24_TO_VDPCOLOR(0x00AAFF));
    VDP_waitVSync();

    /* --- Initial title --- */
    VDP_setTextPalette(PAL0);
    VDP_drawText("[ MegaWifi Perf Server ]", 0, ROW_TITLE);
    JOY_init();
    mw_set_draw_hook(fetch_draw_hook);

    show_state(PAL0, "Connecting to WiFi...");
    if (!megawifi_init()) {
        show_state(PAL2, "WiFi init FAILED");
        while (1) VDP_waitVSync();
    }

    /* --- Girl tiled background on BG_B (after WiFi connects) --- */
    init_girl_bg();
    bg_active = TRUE;

    {
        struct mw_ip_cfg *ip = NULL;
        if (mw_ip_current(&ip) == MW_ERR_NONE && ip) {
            uint32_t a = ip->addr.addr;
            char buf[42];
            sprintf(buf, "[ Perf Server %d.%d.%d.%d:%d ]",
                    (int)((a >> 24) & 0xFF), (int)((a >> 16) & 0xFF),
                    (int)((a >> 8) & 0xFF), (int)(a & 0xFF), PERF_PORT);
            VDP_drawText(buf, 0, ROW_TITLE);
        }
    }

    {
        char buf[40];
        sprintf(buf, "FW %d.%d %s", (int)fw_major, (int)fw_minor, fw_variant_buf);
        clear_row(ROW_FW);
        VDP_drawText(buf, 1, ROW_FW);
    }

    VDP_drawText("--- Log ---", 1, ROW_LOG_HDR);

    server_loop();
    return 0;
}
