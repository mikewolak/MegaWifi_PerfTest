#!/usr/bin/env python3
"""convert_girl.py — Convert girl.png to Genesis VDP tile data (girl_gfx.h)

Based on proven approach from stock_ticker commit a6f90b3:
- Resize to 128x128 (16x16 tiles) — divides 64x32 nametable evenly
- Over-quantize to 48 colours for palette selection, snap to Genesis 9-bit
- Select top 14 unique Genesis colours by pixel coverage
- Remap original pixels to nearest Genesis colour (indices 1-14)
- Index 0 = transparent (never used by content), 15 = reserved for text

Usage:
    python3 convert_girl.py [input.png] [output.h]

Defaults: girl.png → ../md/src/girl_gfx.h
Requires: Pillow, numpy (pip install Pillow numpy)
"""

import sys
from PIL import Image
import numpy as np
from collections import Counter

INPUT  = sys.argv[1] if len(sys.argv) > 1 else "girl.png"
OUTPUT = sys.argv[2] if len(sys.argv) > 2 else "../md/src/girl_gfx.h"

TILE_W, TILE_H = 8, 8
IMG_W, IMG_H   = 128, 128  # 16x16 tiles — 64/16=4, 32/16=2 seamless
TILES_X = IMG_W // TILE_W  # 16
TILES_Y = IMG_H // TILE_H  # 16
MAX_CONTENT_COLORS = 14    # indices 1-14; 0=transparent, 15=text color

# Genesis valid channel values (3-bit: 0-7 mapped to 0-252 in steps of 36)
GENESIS_STEPS = [0, 36, 72, 108, 144, 180, 216, 252]

def snap_channel(v):
    """Snap 8-bit value to nearest Genesis 3-bit channel value."""
    return min(GENESIS_STEPS, key=lambda s: abs(s - v))

def snap_genesis(r, g, b):
    return (snap_channel(r), snap_channel(g), snap_channel(b))

def rgb_to_vdp(r, g, b):
    """Convert 8-bit RGB to Genesis VDP colour word (0x0BGR, 3 bits each)."""
    br = round(r / 36.0) & 7
    bg = round(g / 36.0) & 7
    bb = round(b / 36.0) & 7
    return (bb << 9) | (bg << 5) | (br << 1)

def color_distance(c1, c2):
    return sum((a - b) ** 2 for a, b in zip(c1, c2))

def main():
    img = Image.open(INPUT).convert("RGB")
    img = img.resize((IMG_W, IMG_H), Image.LANCZOS)

    # Over-quantize with PIL, then snap to Genesis and merge duplicates
    qimg = img.quantize(colors=48, method=Image.MEDIANCUT,
                        dither=Image.FLOYDSTEINBERG)
    raw_pal = qimg.getpalette()

    # Snap all quantized colours to Genesis colour space
    q_colors = []
    for i in range(48):
        r, g, b = raw_pal[i*3], raw_pal[i*3+1], raw_pal[i*3+2]
        q_colors.append(snap_genesis(r, g, b))

    # Count pixel usage per palette index
    pixels = list(qimg.getdata())
    usage = Counter(pixels)

    # Group by snapped Genesis colour, sum pixel counts
    genesis_colors = {}
    for idx, count in usage.items():
        if idx < 48:
            gc = q_colors[idx]
            genesis_colors[gc] = genesis_colors.get(gc, 0) + count

    # Sort by usage, take top MAX_CONTENT_COLORS unique Genesis colours
    sorted_colors = sorted(genesis_colors.items(), key=lambda x: -x[1])
    final_palette = [c for c, _ in sorted_colors[:MAX_CONTENT_COLORS]]

    print(f"Unique Genesis colours found: {len(genesis_colors)}")
    print(f"Using top {len(final_palette)} by pixel coverage")

    # Build VDP palette (16 entries):
    #   [0] = 0x0000 (transparent/black)
    #   [1..14] = image colours
    #   [15] = 0x0000 (reserved for text colour)
    gen_palette = [0x0000]  # index 0 = transparent
    for r, g, b in final_palette:
        gen_palette.append(rgb_to_vdp(r, g, b))
    while len(gen_palette) < 15:
        gen_palette.append(0x0000)
    gen_palette.append(0x0000)  # index 15 = reserved for text

    # Remap every pixel: snap to Genesis, find nearest palette entry, shift +1
    img_rgb = img.load()
    pixel_grid = []
    for y in range(IMG_H):
        row = []
        for x in range(IMG_W):
            r, g, b = img_rgb[x, y]
            snapped = snap_genesis(r, g, b)

            # Find closest in final_palette (indices 1..14)
            best_idx = 0
            best_dist = float('inf')
            for pi, pc in enumerate(final_palette):
                d = color_distance(snapped, pc)
                if d < best_dist:
                    best_dist = d
                    best_idx = pi
            row.append(best_idx + 1)  # +1: content uses indices 1-14
        pixel_grid.append(row)

    # Extract 8x8 tiles, deduplicate, build tilemap
    tiles = []
    tile_dict = {}
    tilemap = []

    for ty in range(TILES_Y):
        row = []
        for tx in range(TILES_X):
            tile_bytes = bytearray()
            for py in range(TILE_H):
                for px in range(0, TILE_W, 2):
                    hi = pixel_grid[ty*TILE_H + py][tx*TILE_W + px]
                    lo = pixel_grid[ty*TILE_H + py][tx*TILE_W + px + 1]
                    tile_bytes.append((hi << 4) | lo)

            tb = bytes(tile_bytes)
            if tb not in tile_dict:
                tile_dict[tb] = len(tiles)
                tiles.append(tb)
            row.append(tile_dict[tb])
        tilemap.append(row)

    print(f"Image: {IMG_W}x{IMG_H} ({TILES_X}x{TILES_Y} tiles)")
    print(f"Unique tiles: {len(tiles)} (of {TILES_X * TILES_Y} total)")

    # Print palette
    print("Palette:")
    for i in range(16):
        if i == 0:
            print(f"  [{i:2d}] 0x{gen_palette[i]:04X} (transparent)")
        elif i <= len(final_palette):
            r, g, b = final_palette[i-1]
            print(f"  [{i:2d}] RGB({r:3d},{g:3d},{b:3d}) -> 0x{gen_palette[i]:04X}")
        else:
            print(f"  [{i:2d}] 0x{gen_palette[i]:04X} (reserved)")

    # Write C header
    with open(OUTPUT, "w") as f:
        f.write("/* girl_gfx.h — auto-generated by convert_girl.py\n")
        f.write(" *\n")
        f.write(f" * {IMG_W}x{IMG_H} px = {TILES_X}x{TILES_Y}"
                f" tiles ({len(tiles)} unique)\n")
        f.write(f" * Pattern divides 64x32 nametable:"
                f" 64/{TILES_X}={64//TILES_X},"
                f" 32/{TILES_Y}={32//TILES_Y}\n")
        f.write(" * Palette indices: 0=transparent, 1-14=image,"
                " 15=reserved for text\n")
        f.write(" */\n")
        f.write("#ifndef GIRL_GFX_H\n#define GIRL_GFX_H\n\n")
        f.write("#include <genesis.h>\n\n")

        f.write(f"#define GIRL_TILES_X   {TILES_X}\n")
        f.write(f"#define GIRL_TILES_Y   {TILES_Y}\n")
        f.write(f"#define GIRL_NUM_TILES {len(tiles)}\n\n")

        # Palette
        f.write("static const u16 girl_palette[16] = {\n")
        for i in range(0, 16, 8):
            vals = ", ".join(f"0x{gen_palette[j]:04X}"
                            for j in range(i, min(i+8, 16)))
            f.write(f"    {vals},\n")
        f.write("};\n\n")

        # Tile data (each tile = 32 bytes = 8 u32)
        f.write(f"static const u32 girl_tiles[{len(tiles) * 8}] = {{\n")
        for ti, tile in enumerate(tiles):
            vals = []
            for row_i in range(8):
                word = ((tile[row_i*4] << 24) | (tile[row_i*4+1] << 16)
                        | (tile[row_i*4+2] << 8) | tile[row_i*4+3])
                vals.append(f"0x{word:08X}")
            f.write(f"    /* tile {ti:3d} */ {', '.join(vals)},\n")
        f.write("};\n\n")

        # Tilemap
        f.write(f"static const u16 girl_tilemap[{TILES_Y}][{TILES_X}]"
                " = {\n")
        for row in tilemap:
            vals = ", ".join(f"{v:3d}" for v in row)
            f.write(f"    {{ {vals} }},\n")
        f.write("};\n\n")

        f.write("#endif /* GIRL_GFX_H */\n")

    print(f"\nWritten: {OUTPUT}")


if __name__ == "__main__":
    main()
