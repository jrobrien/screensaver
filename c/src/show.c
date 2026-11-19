#include "show.h"

#include <stdlib.h>
#include <string.h>

static void drop_fx(Show *s)
{
    burn_free(s->burn);
    grow_free(s->grow);
    s->burn = NULL;
    s->grow = NULL;
}

static int enter(Show *s, Phase phase)
{
    drop_fx(s);
    s->phase = phase;
    s->t0 = s->T;
    if (phase == PH_GROW)
        s->grow = grow_new(s->w, s->h, &s->rng, 4.0);
    else if (phase == PH_BURN)
        s->burn = burn_new(s->w, s->h, &s->rng, s->burn_t);
    return (phase == PH_GROW && !s->grow) || (phase == PH_BURN && !s->burn) ? -1 : 0;
}

static int start_cycle(Show *s)
{
    scene_set_palette(s->scene, s->palette >= 0 ? s->palette : s->cycle % PALETTE_COUNT);
    s->cycle++;
    return enter(s, PH_GROW);
}

void show_free(Show *s)
{
    if (!s)
        return;
    drop_fx(s);
    scene_free(s->scene);
    free(s->img);
    free(s->mask);
    free(s);
}

static int alloc_frame(Show *s, int w, int h)
{
    uint8_t *img = realloc(s->img, (size_t)w * (size_t)h * 3);
    if (img)
        s->img = img;
    uint8_t *mask = realloc(s->mask, (size_t)w * (size_t)h);
    if (mask)
        s->mask = mask;
    return img && mask ? 0 : -1;
}

Show *show_new(int w, int h, double live, double burn, int palette, uint64_t seed)
{
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    Show *s = calloc(1, sizeof *s);
    if (!s)
        return NULL;
    s->w = w;
    s->h = h;
    s->live_t = live;
    s->burn_t = burn;
    s->palette = palette;
    rng_seed(&s->rng, seed);
    s->scene = scene_new(w, h);
    if (!s->scene || alloc_frame(s, w, h) || start_cycle(s)) {
        show_free(s);
        return NULL;
    }
    return s;
}

int show_resize(Show *s, int w, int h)
{
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    if (alloc_frame(s, w, h) || scene_resize(s->scene, w, h))
        return -1;
    s->w = w;
    s->h = h;
    if (s->phase == PH_GROW || s->phase == PH_BURN)   /* per-pixel state is size-specific */
        return enter(s, PH_GROW);
    return 0;
}

int show_step(Show *s, double dt)
{
    s->T += dt;
    double t = s->T - s->t0;
    size_t npx = (size_t)s->w * (size_t)s->h;
    scene_render(s->scene, s->T, dt, s->img, s->mask);
    switch (s->phase) {
    case PH_GROW:
        grow_apply(s->grow, s->img, t);
        if (t > grow_end(s->grow))
            return enter(s, PH_LIVE);
        break;
    case PH_LIVE:
        if (t > s->live_t)
            return enter(s, PH_BURN);
        break;
    case PH_BURN:
        burn_apply(s->burn, s->img, t);
        if (burn_done(s->burn))
            return enter(s, PH_BLACK);
        break;
    case PH_BLACK:
        memset(s->img, 0, npx * 3);
        memset(s->mask, 0, npx);
        if (t > BLACK_T)
            return start_cycle(s);
        break;
    }
    return 0;
}

void show_seek(Show *s, Phase phase, double at)
{
    for (;;) {
        if (show_step(s, 1.0 / 20))
            return;
        if (s->phase > phase || (s->phase == phase && s->T - s->t0 >= at))
            return;
    }
}
