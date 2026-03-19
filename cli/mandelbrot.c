/*
 * mandelbrot.c — Q4.28 fixed-point Mandelbrot tile generator + RLE compressor
 *
 * Pure C99.  Computes a full-screen Genesis Mandelbrot (320×224, 40×28 tiles,
 * 4bpp) in tile order, RLE compresses with per-frame token selection, and
 * writes the result to a binary file.
 *
 * Decompress mode reads the binary back and produces a PNG preview via libpng.
 *
 * Usage:
 *   mandelbrot -c [-o out.bin] [-x cx] [-y cy] [-z zoom] [-i maxiter]
 *   mandelbrot -d -f in.bin [-o out.png]
 *   mandelbrot -c -d [-o out.png] [...]   # compress + immediate preview
 */

#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <getopt.h>
#include <math.h>
#include <png.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

/* ── Genesis screen geometry ── */
#define SCREEN_W      320
#define SCREEN_H      224
#define TILE_W        8
#define TILE_H        8
#define TILES_X       (SCREEN_W / TILE_W)   /* 40 */
#define TILES_Y       (SCREEN_H / TILE_H)   /* 28 */
#define NUM_TILES     (TILES_X * TILES_Y)   /* 1120 */
#define TILE_BYTES    32                     /* 8×8 px × 4bpp = 32 bytes */
#define RAW_SIZE      (NUM_TILES * TILE_BYTES)  /* 35840 */

/* ── Q4.28 fixed-point ── */
#define FP_SHIFT      28
#define FP_ONE        (1 << FP_SHIFT)
#define FP_FROM_DBL(x) ((int32_t)((x) * FP_ONE))
#define ESCAPE_R2     (FP_FROM_DBL(4.0))

/* ── Frame header (8 bytes, big-endian wire format) ── */
#define FRAME_MAGIC   0x4D42   /* "MB" */

/* ── 16-color palette (Genesis 9-bit RGB: 3 bits per channel) ── */
/* Index 0 = transparent (black), 1-14 = escape gradient, 15 = interior */
static const uint32_t palette_rgb[16] = {
    0x000000,   /*  0: transparent / black */
    0x000090,   /*  1: deep blue */
    0x0000FC,   /*  2: blue */
    0x0048FC,   /*  3: sky blue */
    0x0090FC,   /*  4: light blue */
    0x00D8FC,   /*  5: cyan */
    0x00FC90,   /*  6: green-cyan */
    0x00FC00,   /*  7: green */
    0x90FC00,   /*  8: yellow-green */
    0xFCFC00,   /*  9: yellow */
    0xFCD800,   /* 10: gold */
    0xFC9000,   /* 11: orange */
    0xFC4800,   /* 12: dark orange */
    0xFC0000,   /* 13: red */
    0xFC0090,   /* 14: magenta */
    0x000000,   /* 15: interior (black) */
};

/* ── Mandelbrot compute ── */

static uint8_t mandelbrot_pixel(int32_t cr, int32_t ci, int max_iter)
{
    int32_t zr = 0, zi = 0;
    for (int i = 0; i < max_iter; i++) {
        int32_t zr2 = (int32_t)(((int64_t)zr * zr) >> FP_SHIFT);
        int32_t zi2 = (int32_t)(((int64_t)zi * zi) >> FP_SHIFT);
        if (zr2 + zi2 > ESCAPE_R2) {
            return (uint8_t)((i % 14) + 1);   /* colors 1-14 */
        }
        zi = (int32_t)(((int64_t)zr * zi) >> (FP_SHIFT - 1)) + ci;
        zr = zr2 - zi2 + cr;
    }
    return 15;   /* interior */
}

/*
 * Compute full screen in tile order.
 * Output: 35,840 bytes of 4bpp tile data, ready for VDP DMA.
 */
static void compute_tiles(uint8_t *tiles, double cx, double cy,
                          double zoom, int max_iter)
{
    /* Viewport: 3.0 units wide at zoom=1, aspect-corrected */
    double w = 3.0 / zoom;
    double h = w * SCREEN_H / SCREEN_W;
    double x0 = cx - w / 2.0;
    double y0 = cy - h / 2.0;
    double dx = w / SCREEN_W;
    double dy = h / SCREEN_H;

    /* Fixed-point deltas */
    int32_t fp_x0 = FP_FROM_DBL(x0);
    int32_t fp_y0 = FP_FROM_DBL(y0);
    int32_t fp_dx = FP_FROM_DBL(dx);
    int32_t fp_dy = FP_FROM_DBL(dy);

    uint8_t *out = tiles;

    for (int ty = 0; ty < TILES_Y; ty++) {
        for (int tx = 0; tx < TILES_X; tx++) {
            /* Each tile: 8 rows × 4 bytes (8 pixels, 4bpp packed) */
            for (int py = 0; py < TILE_H; py++) {
                int sy = ty * TILE_H + py;
                int32_t ci = fp_y0 + (int32_t)((int64_t)fp_dy * sy);

                for (int px = 0; px < TILE_W; px += 2) {
                    int sx0 = tx * TILE_W + px;
                    int sx1 = sx0 + 1;

                    int32_t cr0 = fp_x0 + (int32_t)((int64_t)fp_dx * sx0);
                    int32_t cr1 = fp_x0 + (int32_t)((int64_t)fp_dx * sx1);

                    uint8_t hi = mandelbrot_pixel(cr0, ci, max_iter);
                    uint8_t lo = mandelbrot_pixel(cr1, ci, max_iter);
                    *out++ = (hi << 4) | lo;
                }
            }
        }
    }
}

/* ── RLE encoders ── */

/*
 * Find the byte value that appears least in the raw data.
 * Prefer a value with zero occurrences.
 */
static uint8_t find_token(const uint8_t *data, size_t len)
{
    uint32_t freq[256] = {0};
    for (size_t i = 0; i < len; i++)
        freq[data[i]]++;

    uint8_t best = 0;
    uint32_t best_count = freq[0];
    for (int i = 1; i < 256; i++) {
        if (freq[i] < best_count) {
            best_count = freq[i];
            best = (uint8_t)i;
            if (best_count == 0) break;
        }
    }
    return best;
}

/*
 * Byte-level RLE encode: token-based compression on packed 4bpp bytes.
 *
 *   byte != token  →  literal
 *   token count value  →  emit value × count times
 *
 * If the token byte appears as literal data, encode it as: token 1 token
 *
 * Returns encoded size.  Output buffer must be at least len * 2 bytes.
 */
static size_t rle_encode(const uint8_t *in, size_t len,
                         uint8_t *out, uint8_t token)
{
    size_t oi = 0;
    size_t i = 0;

    while (i < len) {
        /* Count run length */
        size_t run = 1;
        while (i + run < len && in[i + run] == in[i] && run < 255)
            run++;

        if (run >= 3 || in[i] == token) {
            /* Encode as run: token count value */
            out[oi++] = token;
            out[oi++] = (uint8_t)run;
            out[oi++] = in[i];
            i += run;
        } else {
            /* Literal bytes */
            for (size_t j = 0; j < run; j++)
                out[oi++] = in[i++];
        }
    }

    return oi;
}

/* ── RLE decoder ── */

/*
 * Decode RLE stream back to raw tile data.
 * Returns decoded size (should be RAW_SIZE for a full frame).
 */
static size_t rle_decode(const uint8_t *in, size_t in_len,
                         uint8_t *out, size_t out_max, uint8_t token)
{
    size_t ii = 0, oi = 0;

    while (ii < in_len && oi < out_max) {
        if (in[ii] == token) {
            if (ii + 2 >= in_len) break;   /* truncated */
            uint8_t count = in[ii + 1];
            uint8_t value = in[ii + 2];
            ii += 3;
            for (uint8_t j = 0; j < count && oi < out_max; j++)
                out[oi++] = value;
        } else {
            out[oi++] = in[ii++];
        }
    }

    return oi;
}

/* ── PNG writer ── */

static int write_png(const char *path, const uint8_t *tiles)
{
    FILE *fp = fopen(path, "wb");
    if (!fp) { perror(path); return -1; }

    png_structp png = png_create_write_struct(PNG_LIBPNG_VER_STRING,
                                              NULL, NULL, NULL);
    png_infop info = png_create_info_struct(png);
    if (setjmp(png_jmpbuf(png))) {
        png_destroy_write_struct(&png, &info);
        fclose(fp);
        return -1;
    }

    png_init_io(png, fp);
    png_set_IHDR(png, info, SCREEN_W, SCREEN_H, 8,
                 PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE,
                 PNG_COMPRESSION_TYPE_DEFAULT, PNG_FILTER_TYPE_DEFAULT);
    png_write_info(png, info);

    uint8_t *row = malloc(SCREEN_W * 3);

    for (int y = 0; y < SCREEN_H; y++) {
        int ty = y / TILE_H;
        int py = y % TILE_H;

        for (int x = 0; x < SCREEN_W; x++) {
            int tx = x / TILE_W;
            int px = x % TILE_W;

            /* Locate byte in tile data */
            int tile_idx = ty * TILES_X + tx;
            int byte_off = py * (TILE_W / 2) + px / 2;
            uint8_t b = tiles[tile_idx * TILE_BYTES + byte_off];

            /* Extract 4-bit pixel (high nibble = even pixel) */
            uint8_t cidx = (px & 1) ? (b & 0x0F) : (b >> 4);

            uint32_t rgb = palette_rgb[cidx];
            row[x * 3 + 0] = (rgb >> 16) & 0xFF;
            row[x * 3 + 1] = (rgb >> 8) & 0xFF;
            row[x * 3 + 2] = rgb & 0xFF;
        }

        png_write_row(png, row);
    }

    free(row);
    png_write_end(png, NULL);
    png_destroy_write_struct(&png, &info);
    fclose(fp);
    return 0;
}

/* ── File I/O ── */

/*
 * Build 8-byte frame header in big-endian wire format.
 * This is the canonical format — used for both files and TCP.
 */
static void build_frame_hdr(uint8_t *hdr, uint8_t token,
                             size_t rle_len)
{
    hdr[0] = (FRAME_MAGIC >> 8) & 0xFF;   /* 0x4D 'M' */
    hdr[1] = FRAME_MAGIC & 0xFF;           /* 0x42 'B' */
    hdr[2] = token;
    hdr[3] = 0;                             /* flags */
    hdr[4] = (rle_len >> 8) & 0xFF;
    hdr[5] = rle_len & 0xFF;
    hdr[6] = (NUM_TILES >> 8) & 0xFF;
    hdr[7] = NUM_TILES & 0xFF;
}

static int write_frame(const char *path, const uint8_t *rle_data,
                       size_t rle_len, uint8_t token)
{
    FILE *fp = fopen(path, "wb");
    if (!fp) { perror(path); return -1; }

    uint8_t hdr[8];
    build_frame_hdr(hdr, token, rle_len);

    fwrite(hdr, 8, 1, fp);
    fwrite(rle_data, 1, rle_len, fp);
    fclose(fp);
    return 0;
}

static int read_frame(const char *path, uint8_t **rle_out,
                      size_t *rle_len, uint8_t *token)
{
    FILE *fp = fopen(path, "rb");
    if (!fp) { perror(path); return -1; }

    uint8_t hdr[8];
    if (fread(hdr, 8, 1, fp) != 1) {
        fprintf(stderr, "%s: truncated header\n", path);
        fclose(fp);
        return -1;
    }

    uint16_t magic = ((uint16_t)hdr[0] << 8) | hdr[1];
    if (magic != FRAME_MAGIC) {
        fprintf(stderr, "%s: bad magic 0x%04X (expected 0x%04X)\n",
                path, magic, FRAME_MAGIC);
        fclose(fp);
        return -1;
    }

    *token = hdr[2];
    uint16_t payload = ((uint16_t)hdr[4] << 8) | hdr[5];

    uint8_t *buf = malloc(payload);
    if (fread(buf, 1, payload, fp) != payload) {
        fprintf(stderr, "%s: truncated payload\n", path);
        free(buf);
        fclose(fp);
        return -1;
    }

    *rle_out = buf;
    *rle_len = payload;
    fclose(fp);
    return 0;
}

/* ── TCP push ── */

static int send_all(int fd, const void *buf, size_t len)
{
    const uint8_t *p = buf;
    while (len > 0) {
        ssize_t n = send(fd, p, len, 0);
        if (n <= 0) {
            perror("send");
            return -1;
        }
        p   += n;
        len -= (size_t)n;
    }
    return 0;
}

static int send_frame_tcp(const char *host, int port,
                           const uint8_t *rle_data, size_t rle_len,
                           uint8_t token)
{
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) { perror("socket"); return -1; }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(port);
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) {
        fprintf(stderr, "Bad address: %s\n", host);
        close(fd);
        return -1;
    }

    fprintf(stderr, "Connecting to %s:%d...\n", host, port);
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("connect");
        close(fd);
        return -1;
    }
    fprintf(stderr, "Connected. Waiting for Genesis ready...\n");

    /* Wait for "ready" signal before sending — Genesis needs time
     * to arm its LSD receiver after accepting the connection */
    {
        uint8_t ready;
        ssize_t n = recv(fd, &ready, 1, 0);
        if (n != 1) {
            fprintf(stderr, "Failed to get ready signal\n");
            close(fd);
            return -1;
        }
        fprintf(stderr, "Genesis ready.\n");
    }

    uint8_t hdr[8];
    build_frame_hdr(hdr, token, rle_len);

    if (send_all(fd, hdr, 8) != 0 ||
        send_all(fd, rle_data, rle_len) != 0) {
        close(fd);
        return -1;
    }

    fprintf(stderr, "Sent: 8-byte header + %zu bytes RLE payload\n", rle_len);

    /* Wait for ACK from Genesis before closing */
    {
        uint8_t ack;
        ssize_t n = recv(fd, &ack, 1, 0);
        if (n == 1)
            fprintf(stderr, "Frame acknowledged.\n");
        else
            fprintf(stderr, "Warning: no ACK received\n");
    }

    close(fd);
    return 0;
}

/* ── Main ── */

static void usage(const char *prog)
{
    fprintf(stderr,
        "Usage:\n"
        "  %s -c [-o out.bin] [-x cx] [-y cy] [-z zoom] [-i maxiter]\n"
        "  %s -c -H host [-p port] [-x cx] [-y cy] [-z zoom] [-i maxiter]\n"
        "  %s -d -f in.bin [-o out.png]\n"
        "  %s -c -d [-o out.png] [-x cx] [-y cy] [-z zoom] [-i maxiter]\n"
        "\n"
        "Options:\n"
        "  -c          Compress: compute Mandelbrot and RLE encode\n"
        "  -d          Decompress: decode RLE and write PNG preview\n"
        "  -H HOST     Send frame to Genesis at HOST via TCP\n"
        "  -p PORT     TCP port (default: 2026)\n"
        "  -f FILE     Input .bin file (for decompress without -c)\n"
        "  -o FILE     Output file (.bin for -c only, .png for -d)\n"
        "  -r FILE     Write raw (uncompressed) tile data to FILE\n"
        "  -x REAL     Center X (default: -0.5)\n"
        "  -y REAL     Center Y (default: 0.0)\n"
        "  -z ZOOM     Zoom level (default: 1.0)\n"
        "  -i ITER     Max iterations (default: 256)\n"
        "\n"
        "Examples:\n"
        "  %s -c -o frame.bin                    # compute + write binary\n"
        "  %s -c -H 192.168.1.199               # compute + push to Genesis\n"
        "  %s -d -f frame.bin -o preview.png     # decompress to PNG\n"
        "  %s -c -d -o preview.png               # compute + preview\n"
        "  %s -c -d -x -0.75 -y 0.1 -z 50       # zoomed view\n",
        prog, prog, prog, prog, prog, prog, prog, prog, prog);
}

int main(int argc, char *argv[])
{
    int do_compress = 0;
    int do_decompress = 0;
    const char *in_file = NULL;
    const char *out_file = NULL;
    const char *raw_file = NULL;
    const char *tcp_host = NULL;
    int tcp_port = 2026;
    double cx = -0.5, cy = 0.0, zoom = 1.0;
    int max_iter = 256;

    int opt;
    while ((opt = getopt(argc, argv, "cdH:p:f:o:r:x:y:z:i:h")) != -1) {
        switch (opt) {
        case 'c': do_compress = 1; break;
        case 'd': do_decompress = 1; break;
        case 'H': tcp_host = optarg; break;
        case 'p': tcp_port = atoi(optarg); break;
        case 'f': in_file = optarg; break;
        case 'o': out_file = optarg; break;
        case 'r': raw_file = optarg; break;
        case 'x': cx = atof(optarg); break;
        case 'y': cy = atof(optarg); break;
        case 'z': zoom = atof(optarg); break;
        case 'i': max_iter = atoi(optarg); break;
        case 'h': usage(argv[0]); return 0;
        default:  usage(argv[0]); return 1;
        }
    }

    if (!do_compress && !do_decompress) {
        usage(argv[0]);
        return 1;
    }

    uint8_t *raw_tiles = NULL;
    uint8_t *rle_data = NULL;
    size_t rle_len = 0;
    uint8_t token = 0;

    if (do_compress) {
        /* Compute */
        raw_tiles = malloc(RAW_SIZE);
        fprintf(stderr, "Computing Mandelbrot: center=(%.6f, %.6f) zoom=%.1f "
                "iter=%d\n", cx, cy, zoom, max_iter);
        compute_tiles(raw_tiles, cx, cy, zoom, max_iter);

        /* ── Byte-level RLE ── */
        token = find_token(raw_tiles, RAW_SIZE);
        rle_data = malloc(RAW_SIZE * 2);
        rle_len = rle_encode(raw_tiles, RAW_SIZE, rle_data, token);

        fprintf(stderr, "\n%d tiles, %d bytes raw\n", NUM_TILES, RAW_SIZE);
        fprintf(stderr, "RLE: %zu bytes  (%.1f:1, token=0x%02X)\n",
                rle_len, (double)RAW_SIZE / rle_len, token);
        fprintf(stderr, "@ 11.6 KB/s: %.2f s transfer\n",
                rle_len / (11.6 * 1024));

        /* Write raw tile data if requested */
        if (raw_file) {
            FILE *rf = fopen(raw_file, "wb");
            if (rf) {
                fwrite(raw_tiles, 1, RAW_SIZE, rf);
                fclose(rf);
                fprintf(stderr, "\nRaw tiles written: %s (%d bytes)\n",
                        raw_file, RAW_SIZE);
            } else {
                perror(raw_file);
            }
        }

        /* Send over TCP, write to file, or pipe to decompress */
        if (tcp_host) {
            if (send_frame_tcp(tcp_host, tcp_port, rle_data,
                               rle_len, token) != 0)
                return 1;
        } else if (!do_decompress) {
            const char *opath = out_file ? out_file : "frame.bin";
            if (write_frame(opath, rle_data, rle_len, token) == 0)
                fprintf(stderr, "Written: %s (8 + %zu bytes)\n",
                        opath, rle_len);
        } else if (out_file == NULL) {
            out_file = "preview.png";
        }
    }

    if (do_decompress) {
        if (!do_compress) {
            /* Read from file */
            if (!in_file) {
                fprintf(stderr, "Error: -d requires -f FILE or -c\n");
                return 1;
            }
            if (read_frame(in_file, &rle_data, &rle_len, &token) != 0)
                return 1;

            fprintf(stderr, "Read: %s  token=0x%02X  payload=%zu bytes\n",
                    in_file, token, rle_len);

            /* Decode */
            raw_tiles = malloc(RAW_SIZE);
            size_t decoded = rle_decode(rle_data, rle_len,
                                        raw_tiles, RAW_SIZE, token);
            fprintf(stderr, "Decoded: %zu bytes (expected %d)\n",
                    decoded, RAW_SIZE);
            if (decoded != RAW_SIZE) {
                fprintf(stderr, "Warning: decoded size mismatch\n");
            }
        }
        /* else: raw_tiles already populated from compress step */

        /* Write PNG */
        const char *opath = out_file ? out_file : "preview.png";
        if (write_png(opath, raw_tiles) == 0)
            fprintf(stderr, "PNG written: %s (%dx%d)\n",
                    opath, SCREEN_W, SCREEN_H);
    }

    free(raw_tiles);
    free(rle_data);
    return 0;
}
