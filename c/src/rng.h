#ifndef SAVER_RNG_H
#define SAVER_RNG_H
#include <stdint.h>

/* xoshiro256** seeded through splitmix64. */
typedef struct {
    uint64_t s[4];
} Rng;

void rng_seed(Rng *r, uint64_t seed);
uint64_t rng_u64(Rng *r);
double rng_f(Rng *r);                          /* uniform in [0, 1) */
double rng_range(Rng *r, double a, double b);  /* uniform in [a, b) */
double rng_normal(Rng *r, double mean, double sd);
int rng_int(Rng *r, int lo, int hi);           /* uniform, both ends inclusive */

#endif
