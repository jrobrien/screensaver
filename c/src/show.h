#ifndef SAVER_SHOW_H
#define SAVER_SHOW_H
#include <stdint.h>

#include "burn.h"
#include "rng.h"
#include "scene.h"

typedef enum { PH_GROW, PH_LIVE, PH_BURN, PH_BLACK } Phase;

#define BLACK_T 1.2

/* The show: grow -> live -> burn -> black, then again with the next palette. */
typedef struct {
    int w, h;                  /* pixels */
    double live_t, burn_t;
    int palette;               /* fixed palette index, or -1 to rotate */
    Rng rng;
    Scene *scene;
    int cycle;
    double T;                  /* scene clock; never stops */
    Phase phase;
    double t0;
    Burn *burn;
    Grow *grow;
    uint8_t *img;              /* w*h*3, valid after show_step */
    uint8_t *mask;             /* w*h */
} Show;

Show *show_new(int w, int h, double live, double burn, int palette, uint64_t seed);
void show_free(Show *s);
int show_resize(Show *s, int w, int h);   /* 0 ok, -1 out of memory */
int show_step(Show *s, double dt);        /* 0 ok, -1 out of memory; frame is in s->img / s->mask */
void show_seek(Show *s, Phase phase, double at);

#endif
