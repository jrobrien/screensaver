#ifndef SAVER_BURN_H
#define SAVER_BURN_H
#include <stdint.h>

#include "rng.h"

/* Burn-to-ash and its reverse, as per-pixel effects on an RGB image. The
 * Rng is borrowed: it must outlive the effect. */

typedef struct Burn Burn;
typedef struct Grow Grow;

Burn *burn_new(int w, int h, Rng *rng, double duration);
void burn_free(Burn *b);
void burn_apply(Burn *b, uint8_t *img, double t);
int burn_done(const Burn *b);

Grow *grow_new(int w, int h, Rng *rng, double duration);
void grow_free(Grow *g);
void grow_apply(const Grow *g, uint8_t *img, double t);
double grow_end(const Grow *g);

#endif
