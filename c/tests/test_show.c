/* Smoke tests: the show runs through every phase and produces sane frames. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "render.h"
#include "show.h"

static int failures, checks;

#define CHECK(cond)                                                              \
    do {                                                                         \
        checks++;                                                                \
        if (!(cond)) {                                                           \
            failures++;                                                          \
            fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond);      \
        }                                                                        \
    } while (0)

static int any_nonzero(const uint8_t *p, size_t n)
{
    for (size_t i = 0; i < n; i++)
        if (p[i])
            return 1;
    return 0;
}

static int contains(const char *hay, size_t n, const char *needle)
{
    size_t m = strlen(needle);
    for (size_t i = 0; i + m <= n; i++)
        if (memcmp(hay + i, needle, m) == 0)
            return 1;
    return 0;
}

static void test_cycle_and_palette_rotation(void)
{
    Show *s = show_new(80, 48, 0.5, 1.0, -1, 0);
    CHECK(s);
    if (!s) return;
    uint8_t first[3];
    memcpy(first, scene_palette(s->scene)->c[K_S1], 3);
    int seen[4] = {0};
    for (int i = 0; i < 20 * 60; i++) {
        CHECK(show_step(s, 1.0 / 20) == 0);
        seen[s->phase] = 1;
        if (s->cycle == 2)
            break;
    }
    CHECK(seen[PH_GROW] && seen[PH_LIVE] && seen[PH_BURN] && seen[PH_BLACK]);
    CHECK(s->cycle == 2);
    CHECK(memcmp(first, scene_palette(s->scene)->c[K_S1], 3) != 0);
    show_free(s);
}

static void test_live_frame_has_blocks_and_glyphs(void)
{
    Show *s = show_new(120, 70, 24, 9, -1, 0);
    Cells *c = cells_new(120, 35);
    CHECK(s && c);
    if (!s || !c) return;
    show_seek(s, PH_LIVE, 1.0);
    size_t npx = 120 * 70;
    int masked = 0, unmasked = 0;
    for (size_t i = 0; i < npx; i++)
        s->mask[i] ? masked++ : unmasked++;
    CHECK(any_nonzero(s->img, npx * 3) && masked && unmasked);
    to_cells(c, s->img, s->mask);
    int blocks = 0, glyphs = 0;
    for (size_t i = 0; i < 120 * 35; i++) {
        if (c->ch[i] == HALF_BLOCK) blocks++;
        else if (c->ch[i] != ' ' && strchr(RAMP, (int)c->ch[i])) glyphs++;
    }
    CHECK(blocks > 0 && glyphs > 0);
    cells_free(c);
    show_free(s);
}

static void test_burn_ends_black(void)
{
    Show *s = show_new(60, 40, 0.1, 0.5, -1, 0);
    CHECK(s);
    if (!s) return;
    show_seek(s, PH_BURN, 1e9);   /* runs until the phase after burn */
    CHECK(s->phase == PH_BLACK);
    CHECK(!any_nonzero(s->img, 60 * 40 * 3));
    show_free(s);
}

static void test_emitter_only_redraws_changes(void)
{
    Emitter em;
    emitter_init(&em);
    Cells *c = cells_new(3, 2);
    CHECK(c);
    if (!c) return;
    for (int i = 0; i < 6; i++)
        c->ch[i] = HALF_BLOCK;
    memset(c->fg, 0, 18);
    memset(c->bg, 0, 18);
    const char *out;
    size_t n;
    CHECK(emitter_frame(&em, c, &out, &n) == 0);
    CHECK(contains(out, n, "\x1b[2J"));
    CHECK(emitter_frame(&em, c, &out, &n) == 0);
    const char *want = "\x1b[?2026h\x1b[0m\x1b[?2026l";
    CHECK(n == strlen(want) && memcmp(out, want, n) == 0);
    memset(c->fg + (1 * 3 + 2) * 3, 255, 3);   /* cell (row 1, col 2) */
    CHECK(emitter_frame(&em, c, &out, &n) == 0);
    CHECK(contains(out, n, "\x1b[2;3H"));
    int moves = 0;   /* no cell text contains 'H', so each H is a cursor move */
    for (size_t i = 0; i < n; i++)
        moves += out[i] == 'H';
    CHECK(moves == 1);
    emitter_reset(&em);
    CHECK(emitter_frame(&em, c, &out, &n) == 0);
    CHECK(contains(out, n, "\x1b[2J"));
    cells_free(c);
    emitter_fini(&em);
}

static void test_resize_restarts_grow(void)
{
    Show *s = show_new(60, 40, 0.1, 2, -1, 0);
    CHECK(s);
    if (!s) return;
    show_seek(s, PH_BURN, 0.2);
    CHECK(s->phase == PH_BURN);
    CHECK(show_resize(s, 30, 20) == 0);
    CHECK(s->phase == PH_GROW);
    CHECK(show_step(s, 0.05) == 0);
    CHECK(s->w == 30 && s->h == 20);
    show_free(s);
}

static void test_tiny_sizes(void)
{
    Show *s = show_new(10, 8, 0.2, 0.5, 0, 3);   /* 10x4 cells */
    Cells *c = cells_new(10, 4);
    CHECK(s && c);
    if (!s || !c) return;
    for (int i = 0; i < 400; i++) {
        CHECK(show_step(s, 0.05) == 0);
        to_cells(c, s->img, s->mask);
    }
    CHECK(show_resize(s, 1, 2) == 0);
    for (int i = 0; i < 100; i++)
        CHECK(show_step(s, 0.05) == 0);
    CHECK(show_resize(s, 240, 134) == 0);
    for (int i = 0; i < 20; i++)
        CHECK(show_step(s, 0.05) == 0);
    cells_free(c);
    show_free(s);
}

int main(void)
{
    test_cycle_and_palette_rotation();
    test_live_frame_has_blocks_and_glyphs();
    test_burn_ends_black();
    test_emitter_only_redraws_changes();
    test_resize_restarts_grow();
    test_tiny_sizes();
    printf("%d checks, %d failures\n", checks, failures);
    return failures ? 1 : 0;
}
