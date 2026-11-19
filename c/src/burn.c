#include "burn.h"

#include <math.h>
#include <stdlib.h>

#define FLAME_N 5
static const float FLAME[FLAME_N][3] = {{255, 244, 190}, {255, 204, 70}, {240, 120, 24}, {178, 48, 12}, {80, 18, 8}};
static const float HEAT[3] = {255, 120, 30};
static const float EMBER[3] = {190, 70, 16};
static const float ASH[3] = {1.0f, 0.97f, 0.92f};
static const float FLASH[3] = {255, 235, 200};

#define HEAT_T 0.6f
#define FLAME_T 0.75f
#define CHAR_T 1.1f
#define ASH_T 1.6f
#define GROW_FLASH_T 0.8f

typedef struct {
    float x, y, vx, vy, age, life;
    uint8_t spark;
} Flake;

struct Burn {
    int w, h;
    Rng *rng;
    float *ignite, *grain;
    double end, t_prev;
    Flake *flakes;
    size_t n, cap;
};

struct Grow {
    int w, h;
    float *reveal;
    double end;
};

static uint8_t clamp8(float v)
{
    return v <= 0 ? 0 : v >= 255 ? 255 : (uint8_t)v;
}

/* Smooth noise in [0, 1]: a random grid every `cell` pixels, bilinearly interpolated. */
static int value_noise(Rng *rng, int h, int w, int cell, float *out)
{
    int gh = h / cell + 2, gw = w / cell + 2;
    float *g = malloc((size_t)gh * (size_t)gw * sizeof *g);
    int *x0 = malloc((size_t)w * sizeof *x0);
    float *fx = malloc((size_t)w * sizeof *fx);
    if (!g || !x0 || !fx) {
        free(g); free(x0); free(fx);
        return -1;
    }
    for (int i = 0; i < gh * gw; i++)
        g[i] = (float)rng_f(rng);
    for (int x = 0; x < w; x++) {
        double xs = w > 1 ? x * (gw - 1.001) / (w - 1) : 0;
        x0[x] = (int)xs;
        fx[x] = (float)(xs - x0[x]);
    }
    for (int y = 0; y < h; y++) {
        double ys = h > 1 ? y * (gh - 1.001) / (h - 1) : 0;
        int y0 = (int)ys;
        float fy = (float)(ys - y0);
        const float *r0 = g + (size_t)y0 * (size_t)gw, *r1 = r0 + gw;
        for (int x = 0; x < w; x++) {
            int xi = x0[x];
            float top = r0[xi] * (1 - fx[x]) + r0[xi + 1] * fx[x];
            float bot = r1[xi] * (1 - fx[x]) + r1[xi + 1] * fx[x];
            out[(size_t)y * (size_t)w + (size_t)x] = top * (1 - fy) + bot * fy;
        }
    }
    free(g); free(x0); free(fx);
    return 0;
}

void burn_free(Burn *b)
{
    if (!b)
        return;
    free(b->ignite);
    free(b->grain);
    free(b->flakes);
    free(b);
}

Burn *burn_new(int w, int h, Rng *rng, double duration)
{
    Burn *b = calloc(1, sizeof *b);
    if (!b)
        return NULL;
    size_t n = (size_t)w * (size_t)h;
    b->w = w;
    b->h = h;
    b->rng = rng;
    b->ignite = malloc(n * sizeof(float));
    b->grain = malloc(n * sizeof(float));
    float *noise = malloc(n * sizeof(float));
    if (!b->ignite || !b->grain || !noise) {
        free(noise);
        burn_free(b);
        return NULL;
    }
    float *dist = b->ignite;
    for (size_t i = 0; i < n; i++)
        dist[i] = INFINITY;
    int points = rng_int(rng, 2, 3);   /* ignition points, lower half of the screen */
    for (int k = 0; k < points; k++) {
        double sx = rng_range(rng, 0.1, 0.9) * w, sy = rng_range(rng, 0.55, 1.0) * h;
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++) {
                float d = (float)hypot(x - sx, y - sy);
                if (d < dist[(size_t)y * (size_t)w + (size_t)x])
                    dist[(size_t)y * (size_t)w + (size_t)x] = d;
            }
    }
    float size = (float)(w > h ? w : h);
    static const struct { int cell; float amp; } layers[2] = {{7, 0.22f}, {2, 0.04f}};
    for (int l = 0; l < 2; l++) {   /* ragged front */
        if (value_noise(rng, h, w, layers[l].cell, noise)) {
            free(noise);
            burn_free(b);
            return NULL;
        }
        for (size_t i = 0; i < n; i++)
            dist[i] += (noise[i] - 0.5f) * layers[l].amp * size;
    }
    free(noise);
    float lo = dist[0], hi = dist[0];
    for (size_t i = 1; i < n; i++) {
        if (dist[i] < lo) lo = dist[i];
        if (dist[i] > hi) hi = dist[i];
    }
    float span = hi - lo > 1e-6f ? hi - lo : 1e-6f;
    float maxi = 0;
    for (size_t i = 0; i < n; i++) {
        dist[i] = (dist[i] - lo) / span * (float)duration + (float)rng_f(rng) * 0.25f;
        if (dist[i] > maxi) maxi = dist[i];
    }
    for (size_t i = 0; i < n; i++)
        b->grain[i] = (float)rng_f(rng);
    b->end = maxi + FLAME_T + CHAR_T + ASH_T + 3.0;
    return b;
}

int burn_done(const Burn *b)
{
    return b->t_prev > b->end;
}

static void spawn(Burn *b, int x, int y, double vx_mean, double vx_sd, double vy0, double vy1,
                  double l0, double l1, int spark)
{
    if (b->n == b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 1024;
        Flake *f = realloc(b->flakes, nc * sizeof *f);
        if (!f)
            return;   /* out of memory: just drop the flake */
        b->flakes = f;
        b->cap = nc;
    }
    Rng *r = b->rng;
    float vx = (float)rng_normal(r, vx_mean, vx_sd);
    float vy = (float)-rng_range(r, vy0, vy1);
    float life = (float)rng_range(r, l0, l1);
    b->flakes[b->n++] = (Flake){(float)x, (float)y, vx, vy, 0, life, (uint8_t)spark};
}

static void flakes_step_draw(Burn *b, uint8_t *img, float dt)
{
    size_t keep = 0;
    for (size_t i = 0; i < b->n; i++) {
        Flake f = b->flakes[i];
        f.age += dt;
        f.x += (f.vx + sinf(f.age * 3 + f.y) * 3) * dt;
        f.y += f.vy * dt;
        if (!(f.age < f.life && f.y > -2))
            continue;
        b->flakes[keep++] = f;
        int x = (int)f.x, y = (int)f.y;
        if (f.x < 0 || f.y < 0 || x >= b->w || y >= b->h)
            continue;
        float l = 1 - f.age / f.life, c[3];
        if (f.spark) {
            c[0] = 255 * l; c[1] = 140 * l * l; c[2] = 30 * l * l * l;
        } else {
            for (int j = 0; j < 3; j++)
                c[j] = 150 * l * ASH[j];
        }
        uint8_t *px = img + ((size_t)y * (size_t)b->w + (size_t)x) * 3;
        if (c[0] + c[1] + c[2] > (float)(px[0] + px[1] + px[2]))
            for (int j = 0; j < 3; j++)
                px[j] = clamp8(c[j]);
    }
    b->n = keep;
}

void burn_apply(Burn *b, uint8_t *img, double t)
{
    double t0 = b->t_prev;
    float dt = (float)(t - t0);
    b->t_prev = t;
    Rng *rng = b->rng;
    const float a1 = FLAME_T + CHAR_T;
    size_t n = (size_t)b->w * (size_t)b->h;
    for (size_t i = 0; i < n; i++) {
        float age = (float)t - b->ignite[i];
        uint8_t *px = img + i * 3;
        if (age < -HEAT_T)
            continue;
        if (age < 0) {
            float k = (1 + age / HEAT_T) * 0.55f;
            for (int j = 0; j < 3; j++)
                px[j] = clamp8(px[j] * (1 - k) + HEAT[j] * k);
        } else if (age < FLAME_T) {
            float u = age / FLAME_T * 0.9f + ((float)rng_f(rng) - 0.5f) * 0.5f;
            u = (u < 0 ? 0 : u > 1 ? 1 : u) * (FLAME_N - 1);
            int k = (int)u;
            if (k > FLAME_N - 2) k = FLAME_N - 2;
            float f = u - (float)k;
            for (int j = 0; j < 3; j++)
                px[j] = clamp8(FLAME[k][j] * (1 - f) + FLAME[k + 1][j] * f);
        } else if (age < a1) {
            float c = (age - FLAME_T) / CHAR_T;
            if (rng_f(rng) < 0.10f * (1 - c)) {
                for (int j = 0; j < 3; j++)
                    px[j] = clamp8(EMBER[j] * (1 - c));
            } else {
                for (int j = 0; j < 3; j++)
                    px[j] = clamp8(px[j] * 0.22f * (1 - c));
            }
        } else if (age < a1 + ASH_T) {
            float grey = 112 * (1 - (age - a1) / ASH_T) * (0.65f + 0.35f * b->grain[i]);
            for (int j = 0; j < 3; j++)
                px[j] = clamp8(grey * ASH[j]);
        } else {
            px[0] = px[1] = px[2] = 0;
        }
    }
    for (size_t i = 0; i < n; i++) {   /* flakes for pixels whose thresholds fell in (t0, t] */
        double ash_at = b->ignite[i] + a1;
        int x = (int)(i % (size_t)b->w), y = (int)(i / (size_t)b->w);
        if (ash_at > t0 && ash_at <= t && rng_f(rng) < 0.45)
            spawn(b, x, y, 2.5, 3, 2, 9, 1.5, 4.0, 0);
        if (b->ignite[i] > t0 && b->ignite[i] <= t && rng_f(rng) < 0.06)
            spawn(b, x, y, 2, 4, 6, 18, 0.6, 1.8, 1);
    }
    flakes_step_draw(b, img, dt);
}

/* ---- grow ------------------------------------------------------------ */

void grow_free(Grow *g)
{
    if (!g)
        return;
    free(g->reveal);
    free(g);
}

Grow *grow_new(int w, int h, Rng *rng, double duration)
{
    Grow *g = calloc(1, sizeof *g);
    if (!g)
        return NULL;
    size_t n = (size_t)w * (size_t)h;
    g->w = w;
    g->h = h;
    g->reveal = malloc(n * sizeof(float));
    if (!g->reveal) {
        free(g);
        return NULL;
    }
    float dmax = 1e-6f;
    for (int y = 0; y < h; y++)
        for (int x = 0; x < w; x++) {
            float d = (float)hypot(x - w / 2.0, y - h / 2.0);
            g->reveal[(size_t)y * (size_t)w + (size_t)x] = d;
            if (d > dmax) dmax = d;
        }
    float mx = 0;
    for (size_t i = 0; i < n; i++) {
        g->reveal[i] = g->reveal[i] / dmax * (float)duration + (float)rng_f(rng) * 0.9f;
        if (g->reveal[i] > mx) mx = g->reveal[i];
    }
    g->end = mx + GROW_FLASH_T;
    return g;
}

double grow_end(const Grow *g)
{
    return g->end;
}

void grow_apply(const Grow *g, uint8_t *img, double t)
{
    size_t n = (size_t)g->w * (size_t)g->h;
    for (size_t i = 0; i < n; i++) {
        float age = (float)t - g->reveal[i];
        uint8_t *px = img + i * 3;
        if (age < 0) {
            px[0] = px[1] = px[2] = 0;
        } else if (age < GROW_FLASH_T) {
            float k = 1 - age / GROW_FLASH_T;
            k *= k;
            for (int j = 0; j < 3; j++)
                px[j] = clamp8(px[j] * (1 - k) + FLASH[j] * k);
        }
    }
}
