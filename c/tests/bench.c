/* Per-frame time (step + to_cells + emit) at 240x134 pixels. */
#include <stdio.h>
#include <time.h>

#include "render.h"
#include "show.h"

static double now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1e3 + ts.tv_nsec * 1e-6;
}

static void run(const char *label, Show *s, Cells *c, Emitter *em, int frames)
{
    double step = 0, cell = 0, emit = 0, worst = 0;
    size_t bytes = 0;
    for (int i = 0; i < frames; i++) {
        double a = now_ms();
        show_step(s, 1.0 / 24);
        double b = now_ms();
        to_cells(c, s->img, s->mask);
        double d = now_ms();
        const char *out;
        size_t n;
        emitter_frame(em, c, &out, &n);
        double e = now_ms();
        step += b - a; cell += d - b; emit += e - d; bytes += n;
        if (e - a > worst) worst = e - a;
    }
    printf("%-5s %4d frames: step %.2f + cells %.2f + emit %.2f = %.2f ms/frame (worst %.2f), %zu B/frame\n",
           label, frames, step / frames, cell / frames, emit / frames, (step + cell + emit) / frames, worst,
           bytes / (size_t)frames);
}

int main(void)
{
    const int cols = 240, rows = 67;
    Show *s = show_new(cols, rows * 2, 24, 9, 0, 1);
    Cells *c = cells_new(cols, rows);
    Emitter em;
    emitter_init(&em);
    if (!s || !c)
        return 1;
    /* grow lasts ~4.8 s; live 24 s; burn ~9 s + tail, all at 24 fps */
    run("grow", s, c, &em, 100);
    show_seek(s, PH_LIVE, 2.0);
    run("live", s, c, &em, 300);
    show_seek(s, PH_BURN, 0.0);
    run("burn", s, c, &em, 200);
    emitter_fini(&em);
    cells_free(c);
    show_free(s);
    return 0;
}
