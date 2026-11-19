# gfx4snes: BMP decoder heap-buffer-overflow

`sprite16.bmp` sent to `gfx4snes -s 8 -o 16 -u 16 -e 0 -p -m -q -t bmp -i sprite16.bmp` makes the BMP
decoder read past its heap buffer (ASan: heap-buffer-overflow). `LoadBMP` always reads 256 palette
entries (1024 bytes starting at offset 54) for an 8-bit BMP, whatever the file size, and this file is
only 368 bytes. Kept here as a reproducer so the `gfx4snes_bmp` testsuite stays crash-free.

`testsuite/sprite16_padded.bmp` is the same file zero-padded to 1078 bytes, so it decodes cleanly
(no sanitizer report). It is a seed one mutation away from the crash: shortening it below 1078 bytes
reaches the overflow.
