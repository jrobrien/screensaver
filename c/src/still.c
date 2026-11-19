#include "still.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CW 8
#define CH 16

static void fill(uint8_t *img, size_t stride, int x0, int y0, int w, int h, const uint8_t *rgb)
{
    for (int y = y0; y < y0 + h; y++)
        for (int x = x0; x < x0 + w; x++)
            memcpy(img + ((size_t)y * stride + (size_t)x) * 3, rgb, 3);
}

int still_write_ppm(const Cells *c, const char *path)
{
    size_t W = (size_t)c->cols * CW, H = (size_t)c->rows * CH;
    uint8_t *img = malloc(W * H * 3);
    if (!img)
        return -1;
    for (int r = 0; r < c->rows; r++)
        for (int x = 0; x < c->cols; x++) {
            size_t o = (size_t)r * (size_t)c->cols + (size_t)x;
            const uint8_t *fg = c->fg + o * 3, *bg = c->bg + o * 3;
            int px = x * CW, py = r * CH;
            if (c->ch[o] == HALF_BLOCK) {
                fill(img, W, px, py, CW, CH / 2, fg);
                fill(img, W, px, py + CH / 2, CW, CH / 2, bg);
                continue;
            }
            fill(img, W, px, py, CW, CH, bg);
            const char *p = c->ch[o] < 128 && c->ch[o] ? strchr(RAMP, (int)c->ch[o]) : NULL;
            int idx = p ? (int)(p - RAMP) : 0;
            int w = CW * idx / 9, h = CH * idx / 9;   /* scaled box centred in the cell */
            if (w > 0 && h > 0)
                fill(img, W, px + (CW - w) / 2, py + (CH - h) / 2, w, h, fg);
        }
    FILE *f = fopen(path, "wb");
    int ok = f && fprintf(f, "P6\n%zu %zu\n255\n", W, H) > 0 && fwrite(img, 3, W * H, f) == W * H;
    if (f && fclose(f))
        ok = 0;
    free(img);
    return ok ? 0 : -1;
}
