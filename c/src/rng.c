#include "rng.h"

#include <math.h>

static uint64_t splitmix64(uint64_t *x)
{
    uint64_t z = (*x += 0x9e3779b97f4a7c15ULL);
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static uint64_t rotl(uint64_t x, int k)
{
    return (x << k) | (x >> (64 - k));
}

void rng_seed(Rng *r, uint64_t seed)
{
    for (int i = 0; i < 4; i++)
        r->s[i] = splitmix64(&seed);
}

uint64_t rng_u64(Rng *r)
{
    uint64_t *s = r->s;
    uint64_t res = rotl(s[1] * 5, 7) * 9;
    uint64_t t = s[1] << 17;
    s[2] ^= s[0];
    s[3] ^= s[1];
    s[1] ^= s[2];
    s[0] ^= s[3];
    s[2] ^= t;
    s[3] = rotl(s[3], 45);
    return res;
}

double rng_f(Rng *r)
{
    return (double)(rng_u64(r) >> 11) * (1.0 / 9007199254740992.0);
}

double rng_range(Rng *r, double a, double b)
{
    return a + (b - a) * rng_f(r);
}

double rng_normal(Rng *r, double mean, double sd)
{
    double u1 = 1.0 - rng_f(r); /* (0, 1] so log is finite */
    double u2 = rng_f(r);
    return mean + sd * sqrt(-2.0 * log(u1)) * cos(6.283185307179586 * u2);
}

int rng_int(Rng *r, int lo, int hi)
{
    return lo + (int)(rng_f(r) * (double)(hi - lo + 1));
}
