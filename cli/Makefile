# Makefile — Mandelbrot tile generator / RLE compressor
#
# Pure C99.  Only external dependency: libpng (for PNG preview).

CC       = cc
CFLAGS   = -std=c99 -O2 -Wall -Wextra \
           -I/Users/MWOLAK/homebrew/opt/libpng/include
LDFLAGS  = -L/Users/MWOLAK/homebrew/opt/libpng/lib -lpng -lz

TARGET   = mandelbrot
SRC      = mandelbrot.c

.PHONY: all clean test

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(SRC) $(LDFLAGS) -o $@

clean:
	rm -f $(TARGET) *.bin *.png

# Quick test: compute + preview + binary
test: $(TARGET)
	./$(TARGET) -c -o frame.bin
	./$(TARGET) -d -f frame.bin -o from_bin.png
	./$(TARGET) -c -d -o direct.png
	@echo "--- Verify: diff direct.png from_bin.png should match ---"
