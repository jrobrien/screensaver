#include "render.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

Cells *cells_new(int cols, int rows)
{
    if (cols < 1) cols = 1;
    if (rows < 1) rows = 1;
    Cells *c = calloc(1, sizeof *c);
    if (!c)
        return NULL;
    size_t n = (size_t)cols * (size_t)rows;
    c->cols = cols;
    c->rows = rows;
    c->ch = malloc(n * sizeof *c->ch);
    c->fg = malloc(n * 3);
    c->bg = malloc(n * 3);
    if (!c->ch || !c->fg || !c->bg) {
        cells_free(c);
        return NULL;
    }
    return c;
}

void cells_free(Cells *c)
{
    if (!c)
        return;
    free(c->ch);
    free(c->fg);
    free(c->bg);
    free(c);
}

static uint8_t to8(float v)
{
    return v <= 0 ? 0 : v >= 255 ? 255 : (uint8_t)v;
}

void to_cells(Cells *c, const uint8_t *img, const uint8_t *mask)
{
    const size_t W = (size_t)c->cols;
    const size_t nramp = sizeof RAMP - 1;
    for (int r = 0; r < c->rows; r++) {
        for (int x = 0; x < c->cols; x++) {
            size_t it = (size_t)(2 * r) * W + (size_t)x, ib = it + W;
            const uint8_t *top = img + it * 3, *bot = img + ib * 3;
            int mt = mask[it] != 0, mb = mask[ib] != 0;
            size_t o = (size_t)r * W + (size_t)x;
            if (!mt && !mb) {
                c->ch[o] = HALF_BLOCK;
                memcpy(c->fg + o * 3, top, 3);
                memcpy(c->bg + o * 3, bot, 3);
                continue;
            }
            float fg[3], peak = 0;
            float cnt = (float)(mt + mb);
            for (int j = 0; j < 3; j++) {
                fg[j] = (float)(top[j] * mt + bot[j] * mb) / cnt;
                if (fg[j] > peak) peak = fg[j];
            }
            const uint8_t *other = mt ? bot : top;
            for (int j = 0; j < 3; j++)
                c->bg[o * 3 + (size_t)j] = (mt && mb) ? to8(fg[j] * 0.18f) : to8((float)other[j] * 0.45f);
            float lum = (0.2126f * fg[0] + 0.7152f * fg[1] + 0.0722f * fg[2]) / 255.0f;
            float fi = powf(lum, 0.55f) * (float)(nramp - 1) + 0.5f;
            int idx = fi < 0 ? 0 : fi > (float)(nramp - 1) ? (int)(nramp - 1) : (int)fi;
            c->ch[o] = peak < 12 ? ' ' : (uint32_t)(unsigned char)RAMP[idx];
            float boost = 225.0f / (peak > 1 ? peak : 1);   /* brighten the ink */
            boost = boost < 1 ? 1 : boost > 2.4f ? 2.4f : boost;
            for (int j = 0; j < 3; j++)
                c->fg[o * 3 + (size_t)j] = to8(fg[j] * boost);
        }
    }
}

/* ---- emitter ---------------------------------------------------------- */

void emitter_init(Emitter *e)
{
    memset(e, 0, sizeof *e);
}

void emitter_fini(Emitter *e)
{
    cells_free(e->prev);
    free(e->buf);
    memset(e, 0, sizeof *e);
}

void emitter_reset(Emitter *e)
{
    cells_free(e->prev);
    e->prev = NULL;
}

static int ensure(Emitter *e, size_t extra)
{
    if (e->len + extra <= e->cap)
        return 0;
    size_t nc = e->cap ? e->cap : 4096;
    while (nc < e->len + extra)
        nc *= 2;
    char *b = realloc(e->buf, nc);
    if (!b)
        return -1;
    e->buf = b;
    e->cap = nc;
    return 0;
}

static void put_str(Emitter *e, const char *s)
{
    size_t n = strlen(s);
    memcpy(e->buf + e->len, s, n);
    e->len += n;
}

static void put_num(Emitter *e, unsigned v)
{
    char tmp[12];
    int n = 0;
    do {
        tmp[n++] = (char)('0' + v % 10);
        v /= 10;
    } while (v);
    while (n)
        e->buf[e->len++] = tmp[--n];
}

static void put_rgb(Emitter *e, int bgnd, const uint8_t *c)
{
    put_str(e, bgnd ? "\x1b[48;2;" : "\x1b[38;2;");
    put_num(e, c[0]); e->buf[e->len++] = ';';
    put_num(e, c[1]); e->buf[e->len++] = ';';
    put_num(e, c[2]); e->buf[e->len++] = 'm';
}

static void put_cp(Emitter *e, uint32_t cp)
{
    char *p = e->buf + e->len;
    if (cp < 0x80) {
        *p = (char)cp;
        e->len += 1;
    } else if (cp < 0x800) {
        p[0] = (char)(0xC0 | (cp >> 6));
        p[1] = (char)(0x80 | (cp & 0x3F));
        e->len += 2;
    } else {
        p[0] = (char)(0xE0 | (cp >> 12));
        p[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        p[2] = (char)(0x80 | (cp & 0x3F));
        e->len += 3;
    }
}

int emitter_frame(Emitter *e, const Cells *c, const char **out, size_t *n)
{
    const size_t W = (size_t)c->cols;
    int full = !e->prev || e->prev->cols != c->cols || e->prev->rows != c->rows;
    e->len = 0;
    if (ensure(e, 64))
        return -1;
    put_str(e, "\x1b[?2026h");
    if (full)
        put_str(e, "\x1b[2J");
    uint8_t last_fg[3] = {0}, last_bg[3] = {0};
    int have_fg = 0, have_bg = 0;
    for (int r = 0; r < c->rows; r++) {
        size_t row = (size_t)r * W;
        long a = -1, b = -1;   /* first and last changed column */
        for (size_t x = 0; x < W; x++) {
            size_t o = row + x;
            if (full || e->prev->ch[o] != c->ch[o] || memcmp(e->prev->fg + o * 3, c->fg + o * 3, 3) ||
                memcmp(e->prev->bg + o * 3, c->bg + o * 3, 3)) {
                if (a < 0) a = (long)x;
                b = (long)x;
            }
        }
        if (a < 0)
            continue;
        /* worst case per cell: two colour sequences (19 bytes each) + 3-byte char */
        if (ensure(e, 32 + (size_t)(b - a + 1) * 42))
            return -1;
        put_str(e, "\x1b[");
        put_num(e, (unsigned)r + 1);
        e->buf[e->len++] = ';';
        put_num(e, (unsigned)a + 1);
        e->buf[e->len++] = 'H';
        for (long x = a; x <= b; x++) {
            size_t o = row + (size_t)x;
            if (!have_fg || memcmp(last_fg, c->fg + o * 3, 3)) {
                put_rgb(e, 0, c->fg + o * 3);
                memcpy(last_fg, c->fg + o * 3, 3);
                have_fg = 1;
            }
            if (!have_bg || memcmp(last_bg, c->bg + o * 3, 3)) {
                put_rgb(e, 1, c->bg + o * 3);
                memcpy(last_bg, c->bg + o * 3, 3);
                have_bg = 1;
            }
            put_cp(e, c->ch[o]);
        }
    }
    if (ensure(e, 32))
        return -1;
    put_str(e, "\x1b[0m\x1b[?2026l");

    /* remember this frame */
    if (full) {
        cells_free(e->prev);
        e->prev = cells_new(c->cols, c->rows);
        if (!e->prev)
            return -1;
    }
    size_t cn = (size_t)c->cols * (size_t)c->rows;
    memcpy(e->prev->ch, c->ch, cn * sizeof *c->ch);
    memcpy(e->prev->fg, c->fg, cn * 3);
    memcpy(e->prev->bg, c->bg, cn * 3);
    *out = e->buf;
    *n = e->len;
    return 0;
}
