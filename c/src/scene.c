#include "scene.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

#include "raster.h"
#include "rng.h"

#define VW 1600
#define VH 900
#define PI 3.14159265358979323846
#define TAU (2 * PI)
#define DEG (PI / 180)
#define BOOST 1.35        /* leaves and blossoms drawn larger than the SVG's */
#define BAMBOO_SWAY 1.6
#define SCENE_SEED 20261118u
#define PETAL_SEED 7u
#define N_PETALS 48

#define SUN_CX 800
#define SUN_CY 450
#define SUN_R 250
#define HALO_R0 236
#define HALO_R1 430

static const struct {
    double top;
    int key;
} SUN_BANDS[7] = {{200, K_S1}, {350, K_S2}, {420, K_S3}, {480, K_S4}, {535, K_S5}, {585, K_S6}, {640, K_S7}};

static const Pt RIDGE0[] = {{330, 770}, {450, 700}, {525, 742}, {640, 610}, {744, 750}};
static const Pt RIDGE1[] = {{580, 790}, {710, 700}, {780, 748}, {880, 655}, {1000, 770}, {1060, 742}, {1190, 800}};
static const Pt RIDGE2[] = {{240, 810}, {370, 745}, {460, 800}, {560, 760}, {660, 815}};
static const struct {
    const Pt *p;
    int n;
} RIDGES[3] = {{RIDGE0, 5}, {RIDGE1, 7}, {RIDGE2, 5}};

static const int BAYER4[4][4] = {{0, 8, 2, 10}, {12, 4, 14, 6}, {3, 11, 1, 9}, {15, 7, 13, 5}};

static const Pt PETAL[10] = {{0, 0}, {-7, -4}, {-11, -12}, {-9, -20}, {-4, -23},
                             {0, -20}, {4, -23}, {9, -20}, {11, -12}, {7, -4}};
static const Pt PETAL_TIP[6] = {{-5, -16}, {0, -14}, {5, -16}, {3, -22}, {0, -20}, {-3, -22}};

typedef struct {
    int parent;   /* -1 for none */
    double px, py, amp, dur, phase;
} Node;

typedef enum { SH_POLY, SH_STEM, SH_LINE, SH_DOT } ShapeKind;

typedef struct {
    ShapeKind kind;
    int start, end;   /* point range */
    int key;
    double w0, w1;
} Shape;

typedef struct {
    double x, y, depth, vy, phase, flip, flip_rate, age;
} Petal;

struct Scene {
    int w, h;
    double s, ox, oy;

    Rng rng;
    double sway_k;
    int oom;

    Node *nodes;
    size_t nn, ncap;
    Shape *shapes;
    size_t nsh, shcap;
    Pt *pts;
    int *pt_node;
    size_t np, pcap, pncap;
    Pt *spots;          /* blossom positions, virtual coordinates */
    size_t nspots, spcap;

    Pt leaf_body[12], leaf_tip[8];

    double *mats;       /* 6 per node */
    Pt *world;          /* per point, pixel coordinates */

    int pal_index;
    Palette pal;
    uint8_t *base;      /* static backdrop, w*h*3 */

    Rng petal_rng;
    Petal petals[N_PETALS];
};

/* ---- growable arrays ------------------------------------------------ */

static int reserve(Scene *sc, void **p, size_t *cap, size_t need, size_t elt)
{
    if (sc->oom)
        return -1;
    if (need <= *cap)
        return 0;
    size_t ncap = *cap ? *cap * 2 : 64;
    while (ncap < need)
        ncap *= 2;
    void *q = realloc(*p, ncap * elt);
    if (!q) {
        sc->oom = 1;
        return -1;
    }
    *p = q;
    *cap = ncap;
    return 0;
}

/* ---- geometry helpers ----------------------------------------------- */

static Pt bez2(Pt p0, Pt p1, Pt p2, double t)
{
    double u = 1 - t;
    return (Pt){u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
                u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y};
}

static Pt bez3(Pt p0, Pt p1, Pt p2, Pt p3, double t)
{
    double u = 1 - t, a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t;
    return (Pt){a * p0.x + b * p1.x + c * p2.x + d * p3.x, a * p0.y + b * p1.y + c * p2.y + d * p3.y};
}

static double angle_at(const Pt *pts, int n, int i)
{
    Pt a = pts[i > 0 ? i - 1 : 0], b = pts[i + 1 < n ? i + 1 : n - 1];
    return atan2(b.y - a.y, b.x - a.x);
}

static void transform(const Pt *in, int n, double rot, double scale, double tx, double ty, Pt *out)
{
    double c = cos(rot) * scale, s = sin(rot) * scale;
    for (int i = 0; i < n; i++)
        out[i] = (Pt){c * in[i].x - s * in[i].y + tx, s * in[i].x + c * in[i].y + ty};
}

static void leaf_outline(Pt body[12], Pt tip[8])
{
    /* edge(sign, t0, t1, n): n+1 points of a quadratic along one side. */
    struct { double sign, t0, t1; int n; } e[4] = {{-1, 0, 1, 5}, {1, 1, 0, 5}, {-1, 0.55, 1, 3}, {1, 1, 0.55, 3}};
    Pt *dst[4] = {body, body + 6, tip, tip + 4};
    for (int k = 0; k < 4; k++)
        for (int i = 0; i <= e[k].n; i++) {
            double t = e[k].t0 + (e[k].t1 - e[k].t0) * i / e[k].n, u = 1 - t;
            dst[k][i] = (Pt){2 * u * t * 24 + t * t * 74, e[k].sign * 2 * u * t * 11};
        }
}

/* ---- building the tree ---------------------------------------------- */

static double rr(Scene *sc, double a, double b)
{
    return rng_range(&sc->rng, a, b);
}

static int add_node(Scene *sc, int parent, Pt pivot, double amp, double dur)
{
    double phase = rng_f(&sc->rng) * TAU;
    if (reserve(sc, (void **)&sc->nodes, &sc->ncap, sc->nn + 1, sizeof *sc->nodes))
        return 0;
    sc->nodes[sc->nn] = (Node){parent, pivot.x, pivot.y, amp * sc->sway_k * DEG, dur, phase};
    return (int)sc->nn++;
}

static int add_node_rr(Scene *sc, int parent, Pt pivot, double a0, double a1, double d0, double d1)
{
    double amp = rr(sc, a0, a1);
    double dur = rr(sc, d0, d1);
    return add_node(sc, parent, pivot, amp, dur);
}

static void add_shape(Scene *sc, int node, ShapeKind kind, const Pt *pts, int n, int key, double w0, double w1)
{
    if (reserve(sc, (void **)&sc->pts, &sc->pcap, sc->np + (size_t)n, sizeof *sc->pts) ||
        reserve(sc, (void **)&sc->pt_node, &sc->pncap, sc->np + (size_t)n, sizeof *sc->pt_node) ||
        reserve(sc, (void **)&sc->shapes, &sc->shcap, sc->nsh + 1, sizeof *sc->shapes))
        return;
    for (int i = 0; i < n; i++) {
        sc->pts[sc->np + (size_t)i] = pts[i];
        sc->pt_node[sc->np + (size_t)i] = node;
    }
    sc->shapes[sc->nsh++] = (Shape){kind, (int)sc->np, (int)sc->np + n, key, w0, w1};
    sc->np += (size_t)n;
}

static void leaf(Scene *sc, int parent, Pt q, double ang, double size)
{
    ang = atan2(sin(ang) + 0.35, cos(ang));   /* leaves droop a little */
    int n = add_node_rr(sc, parent, q, 2.5, 5.5, 3.5, 6.5);
    int key = rng_f(&sc->rng) < .5 ? K_LEAF_A : K_LEAF_B;
    Pt body[12], tip[8];
    transform(sc->leaf_body, 12, ang, size * BOOST, q.x, q.y, body);
    transform(sc->leaf_tip, 8, ang, size * BOOST, q.x, q.y, tip);
    add_shape(sc, n, SH_POLY, body, 12, key, 0, 0);
    add_shape(sc, n, SH_POLY, tip, 8, key + 1, 0, 0);
}

static void branch(Scene *sc, int parent, Pt p, double ang, double length, double size)
{
    Pt end = {p.x + cos(ang) * length, p.y + sin(ang) * length};
    double jitter = rr(sc, -6, 6);
    Pt ctrl = {(p.x + end.x) / 2, (p.y + end.y) / 2 + length * 0.12 + jitter};
    Pt pts[7];
    for (int i = 0; i <= 6; i++)
        pts[i] = bez2(p, ctrl, end, i / 6.0);
    int n = add_node_rr(sc, parent, p, 1.4, 2.6, 8, 12);
    add_shape(sc, n, SH_STEM, pts, 7, K_CULM, 2.8 * size, 1.1 * size);
    static const double U[3] = {0.35, 0.6, 0.82};
    static const int SIDE[3] = {1, -1, 1};
    for (int k = 0; k < 3; k++) {
        int i = (int)lround(U[k] * 6);
        double da = rr(sc, 28, 50);
        double sz = size * rr(sc, 0.8, 1.15);
        leaf(sc, n, pts[i], angle_at(pts, 7, i) + SIDE[k] * da * DEG, sz);
    }
    double th = angle_at(pts, 7, 6);
    static const int A[3] = {-38, 0, 36};
    for (int k = 0; k < 3; k++) {
        double da = rr(sc, -6, 6);
        double sz = size * rr(sc, 0.9, 1.25);
        leaf(sc, n, end, th + (A[k] + da) * DEG, sz);
    }
}

static void bamboo(Scene *sc, Pt p0, Pt p1, Pt p2, double w0, double w1, double amp, double dur, double scale)
{
    enum { N = 48 };
    int n = add_node(sc, -1, p0, amp, dur);
    Pt pts[N + 1];
    for (int i = 0; i <= N; i++)
        pts[i] = bez2(p0, p1, p2, (double)i / N);
    add_shape(sc, n, SH_STEM, pts, N + 1, K_CULM, w0, w1);
    int side = 1;
    for (double t = 0.05; t < 0.97; t += 0.075) {   /* nodes up the culm, branches above 30% */
        int i = (int)lround(t * N);
        Pt p = pts[i];
        double th = angle_at(pts, N + 1, i);
        double k = (w0 + (w1 - w0) * t) / 2 + 1.4;
        double nx = -sin(th) * k, ny = cos(th) * k;
        Pt seg[2] = {{p.x + nx, p.y + ny}, {p.x - nx, p.y - ny}};
        add_shape(sc, n, SH_LINE, seg, 2, K_NODE, 0, 0);
        if (t > 0.3 && rng_f(&sc->rng) < 0.85) {
            double da = rr(sc, 40, 64);
            double len = rr(sc, 70, 130) * scale * (1.15 - 0.6 * t);
            branch(sc, n, p, th + side * da * DEG, len, scale);
            side = -side;
        }
    }
    double th = angle_at(pts, N + 1, N);
    static const int A[3] = {-30, 0, 28};
    for (int k = 0; k < 3; k++) {
        double da = rr(sc, -5, 5);
        double sz = scale * rr(sc, 1.0, 1.3);
        leaf(sc, n, pts[N], th + (A[k] + da) * DEG, sz);
    }
}

static void blossom(Scene *sc, int parent, double x, double y, double size)
{
    int n = add_node_rr(sc, parent, (Pt){x, y}, 2, 5, 5, 8);
    double rot0 = rr(sc, 0, 360);
    size *= BOOST * 1.1;
    for (int layer = 0; layer < 2; layer++) {
        const Pt *outline = layer ? PETAL_TIP : PETAL;
        int cnt = layer ? 6 : 10;
        Pt out[10];
        for (int k = 0; k < 5; k++) {
            transform(outline, cnt, (rot0 + 72 * k) * DEG, size, x, y, out);
            add_shape(sc, n, SH_POLY, out, cnt, layer ? K_PINK_HI : K_PINK, 0, 0);
        }
    }
    Pt c = {x, y};
    add_shape(sc, n, SH_DOT, &c, 1, K_PINK_DK, 0, 0);
    if (reserve(sc, (void **)&sc->spots, &sc->spcap, sc->nspots + 1, sizeof *sc->spots) == 0)
        sc->spots[sc->nspots++] = c;
}

static void twig(Scene *sc, int parent, Pt p0, double ang, double length, double w, int level)
{
    Pt end = {p0.x + cos(ang) * length, p0.y + sin(ang) * length};
    double jx = rr(sc, -10, 10);
    Pt ctrl = {(p0.x + end.x) / 2 + jx, (p0.y + end.y) / 2 + length * 0.18};
    Pt pts[7];
    for (int i = 0; i <= 6; i++)
        pts[i] = bez2(p0, ctrl, end, i / 6.0);
    int n = add_node_rr(sc, parent, p0, 1.2, 2.4, 8, 12);
    add_shape(sc, n, SH_STEM, pts, 7, K_BARK, w, w * 0.35);
    if (level == 0) {
        int count = rng_f(&sc->rng) < 0.6 ? 2 : 1;
        for (int k = 0; k < count; k++) {
            int i = (int)lround(rr(sc, 0.35, 0.7) * 6);
            int side = rng_f(&sc->rng) < .5 ? -1 : 1;
            double da = rr(sc, 30, 55);
            double lf = rr(sc, 0.4, 0.6);
            twig(sc, n, pts[i], angle_at(pts, 7, i) + side * da * DEG, length * lf, w * 0.6, 1);
        }
    }
    int blossoms = level == 0 ? 3 : 2;
    for (int k = 0; k < blossoms; k++) {   /* first blossom at the tip, the rest along it */
        int i = (int)lround((k == 0 ? 1.0 : rr(sc, 0.55, 0.95)) * 6);
        double j = k == 0 ? 0.3 : 1;
        double dx = rr(sc, -8, 8) * j;
        double dy = rr(sc, -8, 8) * j;
        double sz = rr(sc, 0.6, 1.0);
        blossom(sc, n, pts[i].x + dx, pts[i].y + dy, sz);
    }
}

static void cherry(Scene *sc)
{
    Pt P0 = {-80, 490}, P1 = {110, 520}, P2 = {250, 330}, P3 = {620, 250};
    enum { N = 28 };
    Pt pts[N + 1];
    for (int i = 0; i <= N; i++)
        pts[i] = bez3(P0, P1, P2, P3, (double)i / N);
    int n = add_node(sc, -1, P0, 0.6, 14);
    add_shape(sc, n, SH_STEM, pts, N + 1, K_BARK, 15, 3.5);
    static const double T[7] = {0.2, 0.32, 0.45, 0.58, 0.7, 0.8, 0.9};
    for (int i = 0; i < 7; i++) {
        int idx = (int)lround(T[i] * N);
        int side = i % 2 ? -1 : 1;
        double da = rr(sc, 35, 60);
        double len = rr(sc, 80, 140) * (1.1 - T[i] * 0.5);
        twig(sc, n, pts[idx], angle_at(pts, N + 1, idx) + side * da * DEG, len, 4.4 - T[i] * 1.6, 0);
    }
    double da = rr(sc, -10, 10);
    twig(sc, n, pts[N], angle_at(pts, N + 1, N) + da * DEG, 70, 3, 0);
}

/* ---- falling petals --------------------------------------------------- */

static void petal_reset(Scene *sc, Petal *p, int initial)
{
    Rng *R = &sc->petal_rng;
    p->depth = rng_range(R, 0.25, 1);
    if (initial) {   /* scattered and already faded in */
        p->x = rng_range(R, -100, 1700);
        p->y = rng_range(R, -40, 940);
        p->age = 99.0;
    } else if (sc->nspots && rng_f(R) < 0.6) {   /* shed from a blossom */
        Pt sp = sc->spots[rng_int(R, 0, (int)sc->nspots - 1)];
        p->x = sp.x + rng_range(R, -10, 10);
        p->y = sp.y + rng_range(R, -6, 10);
        p->age = 0.0;
    } else {   /* from above the screen */
        p->x = rng_range(R, -120, 1500);
        p->y = -40.0;
        p->age = 0.0;
    }
    p->vy = 14 + p->depth * 34 + rng_range(R, 0, 8);
    p->phase = rng_range(R, 0, TAU);
    p->flip = rng_range(R, 0, TAU);
    p->flip_rate = rng_range(R, 0.8, 2.4);
}

static void petals_step(Scene *sc, double dt, double t)
{
    double wind = 14 + 10 * sin(t * 0.13) + 5 * sin(t * 0.37);
    for (int i = 0; i < N_PETALS; i++) {
        Petal *p = &sc->petals[i];
        p->x += (wind * (0.5 + p->depth * 0.7) + sin(t * 0.7 + p->phase) * 16) * dt;
        p->y += (p->vy + sin(t * 1.1 + p->phase * 2) * 6) * dt;
        p->flip += p->flip_rate * dt;
        p->age += dt;
        if (p->y > 950 || p->x > 1750)
            petal_reset(sc, p, 0);
    }
}

static void petals_draw(const Scene *sc, Canvas *cv)
{
    for (int i = 0; i < N_PETALS; i++) {
        const Petal *p = &sc->petals[i];
        double x = p->x * sc->s + sc->ox, y = p->y * sc->s + sc->oy;
        double fade = (0.35 + 0.65 * p->depth) * fmin(1.0, p->age / 1.2);
        const uint8_t *base = sc->pal.c[fade > 0.75 ? K_PINK_HI : K_PINK];
        double k = 0.45 + 0.55 * fmin(1.0, fade * 1.2);
        for (int j = 0; j < 3; j++)
            cv->rgb[j] = (uint8_t)(base[j] * k);
        if (fabs(x) > 1e6 || fabs(y) > 1e6)
            continue;
        int px = (int)floor(x), py = (int)floor(y);
        canvas_pixel(cv, px, py);
        if (p->depth > 0.6 && fabs(cos(p->flip)) > 0.5)   /* near petals are 1-2 px wide as they flip */
            canvas_pixel(cv, px + 1, py);
    }
}

/* ---- lifecycle -------------------------------------------------------- */

void scene_free(Scene *sc)
{
    if (!sc)
        return;
    free(sc->nodes);
    free(sc->shapes);
    free(sc->pts);
    free(sc->pt_node);
    free(sc->spots);
    free(sc->mats);
    free(sc->world);
    free(sc->base);
    free(sc);
}

static void make_base(Scene *sc)
{
    const int W = sc->w, H = sc->h;
    uint8_t *img = sc->base;
    memset(img, 0, (size_t)W * (size_t)H * 3);
    const Palette *pal = &sc->pal;
    for (int y = 0; y < H; y++) {
        double vy = (y + 0.5 - sc->oy) / sc->s;
        for (int x = 0; x < W; x++) {
            double vx = (x + 0.5 - sc->ox) / sc->s;
            double r = hypot(vx - SUN_CX, vy - SUN_CY);
            uint8_t *px = img + ((size_t)y * (size_t)W + (size_t)x) * 3;
            double a = fmin(fmax(1 - (r - HALO_R0) / (HALO_R1 - HALO_R0), 0), 1);
            if (r >= HALO_R0 && r < HALO_R1 && a > 0.15 && a > (BAYER4[y % 4][x % 4] + 0.5) / 16) {
                for (int j = 0; j < 3; j++)
                    px[j] = (uint8_t)(pal->c[K_S3][j] * 0.30);
            }
            if (r < SUN_R) {
                for (int k = 0; k < 7; k++) {
                    double bottom = k + 1 < 7 ? SUN_BANDS[k + 1].top : INFINITY;
                    if (vy >= SUN_BANDS[k].top && vy < bottom)
                        memcpy(px, pal->c[SUN_BANDS[k].key], 3);
                }
            }
        }
    }
    Canvas cv = {img, NULL, W, H, {0, 0, 0}, 0};
    for (int k = 0; k < 3; k++) {
        Pt p[8];
        int n = RIDGES[k].n;
        for (int i = 0; i < n; i++)
            p[i] = (Pt){RIDGES[k].p[i].x * sc->s + sc->ox, RIDGES[k].p[i].y * sc->s + sc->oy};
        Pt poly[10];
        memcpy(poly, p, sizeof(Pt) * (size_t)n);
        poly[n] = (Pt){p[n - 1].x, H};
        poly[n + 1] = (Pt){p[0].x, H};
        memset(cv.rgb, 0, 3);
        canvas_poly(&cv, poly, n + 2);
        memcpy(cv.rgb, pal->c[K_LINE], 3);
        for (int i = 0; i + 1 < n; i++)
            canvas_line(&cv, p[i], p[i + 1]);
    }
}

int scene_resize(Scene *sc, int w, int h)
{
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    uint8_t *b = realloc(sc->base, (size_t)w * (size_t)h * 3);
    if (!b)
        return -1;
    sc->base = b;
    sc->w = w;
    sc->h = h;
    sc->s = fmax((double)w / VW, (double)h / VH);
    sc->ox = (w - VW * sc->s) / 2;
    sc->oy = (h - VH * sc->s) / 2;
    make_base(sc);
    return 0;
}

void scene_set_palette(Scene *sc, int index)
{
    sc->pal_index = index % PALETTE_COUNT;
    palette_get(sc->pal_index, &sc->pal);
    make_base(sc);
}

const Palette *scene_palette(const Scene *sc)
{
    return &sc->pal;
}

Scene *scene_new(int w, int h)
{
    Scene *sc = calloc(1, sizeof *sc);
    if (!sc)
        return NULL;
    rng_seed(&sc->rng, SCENE_SEED);
    rng_seed(&sc->petal_rng, PETAL_SEED);
    leaf_outline(sc->leaf_body, sc->leaf_tip);
    sc->sway_k = BAMBOO_SWAY;
    bamboo(sc, (Pt){1400, 980}, (Pt){1405, 620}, (Pt){1300, 230}, 6.5, 2.8, 1.1, 11, 0.85);
    bamboo(sc, (Pt){1250, 980}, (Pt){1215, 520}, (Pt){1035, 95}, 9, 3.5, 0.9, 13, 1);
    sc->sway_k = 1.0;
    cherry(sc);
    if (sc->oom) {
        scene_free(sc);
        return NULL;
    }
    sc->mats = malloc(sc->nn * 6 * sizeof(double));
    sc->world = malloc(sc->np * sizeof(Pt));
    if (!sc->mats || !sc->world) {
        scene_free(sc);
        return NULL;
    }
    for (int i = 0; i < N_PETALS; i++)
        petal_reset(sc, &sc->petals[i], 1);
    if (scene_resize(sc, w, h)) {
        scene_free(sc);
        return NULL;
    }
    scene_set_palette(sc, 0);
    return sc;
}

/* ---- per frame -------------------------------------------------------- */

static void evaluate(Scene *sc, double t)
{
    /* affine (a, b, c, d, e, f): x' = a*x + c*y + e, y' = b*x + d*y + f */
    const double root[6] = {sc->s, 0, 0, sc->s, sc->ox, sc->oy};
    for (size_t i = 0; i < sc->nn; i++) {
        const Node *nd = &sc->nodes[i];
        double th = nd->amp * sin(PI * t / nd->dur + nd->phase);
        double c = cos(th), s = sin(th);
        double e = nd->px - c * nd->px + s * nd->py, f = nd->py - s * nd->px - c * nd->py;
        const double *P = nd->parent >= 0 ? &sc->mats[(size_t)nd->parent * 6] : root;
        double *M = &sc->mats[i * 6];
        M[0] = P[0] * c + P[2] * s;
        M[1] = P[1] * c + P[3] * s;
        M[2] = -P[0] * s + P[2] * c;
        M[3] = -P[1] * s + P[3] * c;
        M[4] = P[0] * e + P[2] * f + P[4];
        M[5] = P[1] * e + P[3] * f + P[5];
    }
    for (size_t i = 0; i < sc->np; i++) {
        const double *M = &sc->mats[(size_t)sc->pt_node[i] * 6];
        sc->world[i] = (Pt){M[0] * sc->pts[i].x + M[2] * sc->pts[i].y + M[4],
                            M[1] * sc->pts[i].x + M[3] * sc->pts[i].y + M[5]};
    }
}

void scene_render(Scene *sc, double t, double dt, uint8_t *img, uint8_t *mask)
{
    size_t npx = (size_t)sc->w * (size_t)sc->h;
    memcpy(img, sc->base, npx * 3);
    memset(mask, 0, npx);
    evaluate(sc, t);
    Canvas cv = {img, mask, sc->w, sc->h, {0, 0, 0}, 0};
    for (size_t i = 0; i < sc->nsh; i++) {
        const Shape *sh = &sc->shapes[i];
        const Pt *p = &sc->world[sh->start];
        int n = sh->end - sh->start;
        memcpy(cv.rgb, sc->pal.c[sh->key], 3);
        cv.mval = key_is_glyph(sh->key);   /* non-glyph shapes erase the mask they cover */
        switch (sh->kind) {
        case SH_POLY:
            canvas_poly(&cv, p, n);
            break;
        case SH_STEM:
            for (int k = 0; k + 1 < n; k++) {
                double w = (sh->w0 + (sh->w1 - sh->w0) * k / (n - 1)) * sc->s;
                long wi = lround(w);
                if (wi <= 1)
                    canvas_line(&cv, p[k], p[k + 1]);
                else
                    canvas_thick(&cv, p[k], p[k + 1], (double)wi);
            }
            break;
        case SH_LINE:
            for (int k = 0; k + 1 < n; k++)
                canvas_line(&cv, p[k], p[k + 1]);
            break;
        case SH_DOT:
            if (fabs(p[0].x) < 1e6 && fabs(p[0].y) < 1e6)
                canvas_pixel(&cv, (int)floor(p[0].x), (int)floor(p[0].y));
            break;
        }
    }
    petals_step(sc, dt, t);
    cv.mask = NULL;   /* petals draw into the image only */
    petals_draw(sc, &cv);
}
