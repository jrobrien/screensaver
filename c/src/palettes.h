#ifndef SAVER_PALETTES_H
#define SAVER_PALETTES_H
#include <stdint.h>

/* Colour keys. Order matters: K_LEAF_x_HI == K_LEAF_x + 1, K_S1..K_S7 contiguous. */
enum {
    K_CULM, K_NODE, K_BARK,
    K_LEAF_A, K_LEAF_A_HI, K_LEAF_B, K_LEAF_B_HI,
    K_PINK, K_PINK_HI, K_PINK_DK,
    K_S1, K_S2, K_S3, K_S4, K_S5, K_S6, K_S7,
    K_LINE,
    K_COUNT
};

#define PALETTE_COUNT 3

typedef struct {
    uint8_t c[K_COUNT][3];
} Palette;

const char *palette_name(int index);
int palette_find(const char *name);   /* index, or -1 */
void palette_get(int index, Palette *out);
int key_is_glyph(int key);            /* culm, node and leaves become ASCII glyphs */

#endif
