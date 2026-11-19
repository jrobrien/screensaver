#include "raster.h"

#include <math.h>
#include <stdlib.h>

#define MAX_POLY 64

void canvas_pixel(Canvas *c, int x, int y)
{
    if (x < 0 || y < 0 || x >= c->w || y >= c->h)
        return;
    size_t i = (size_t)y * (size_t)c->w + (size_t)x;
    uint8_t *p = c->img + i * 3;
    p[0] = c->rgb[0];
    p[1] = c->rgb[1];
    p[2] = c->rgb[2];
    if (c->mask)
        c->mask[i] = c->mval;
}

void canvas_line(Canvas *c, Pt a, Pt b)
{
    /* Guard against absurd coordinates (they would loop for ages). */
    const double lim = 1e6;
    if (fabs(a.x) > lim || fabs(a.y) > lim || fabs(b.x) > lim || fabs(b.y) > lim)
        return;
    long x0 = lround(a.x), y0 = lround(a.y), x1 = lround(b.x), y1 = lround(b.y);
    long dx = labs(x1 - x0), dy = -labs(y1 - y0);
    long sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    long err = dx + dy;
    for (;;) {
        canvas_pixel(c, (int)x0, (int)y0);
        if (x0 == x1 && y0 == y1)
            break;
        long e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x0 += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y0 += sy;
        }
    }
}

void canvas_poly(Canvas *c, const Pt *p, int n)
{
    if (n < 1 || n > MAX_POLY)
        return;
    double miny = p[0].y, maxy = p[0].y;
    for (int i = 1; i < n; i++) {
        if (p[i].y < miny) miny = p[i].y;
        if (p[i].y > maxy) maxy = p[i].y;
    }
    if (maxy < -1e6 || miny > 1e6)
        return;
    int y0 = (int)fmax(0.0, ceil(miny - 0.5));
    int y1 = (int)fmin((double)(c->h - 1), floor(maxy - 0.5));
    for (int y = y0; y <= y1; y++) {
        double yc = y + 0.5, xs[MAX_POLY];
        int nx = 0;
        for (int i = 0; i < n; i++) {
            Pt a = p[i], b = p[(i + 1) % n];
            if ((a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc)) {
                double x = a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y);
                int j = nx++;
                while (j > 0 && xs[j - 1] > x) {   /* insertion sort */
                    xs[j] = xs[j - 1];
                    j--;
                }
                xs[j] = x;
            }
        }
        for (int k = 0; k + 1 < nx; k += 2) {
            double lo = ceil(xs[k] - 0.5), hi = ceil(xs[k + 1] - 0.5) - 1;
            if (lo < 0) lo = 0;
            if (hi > c->w - 1) hi = c->w - 1;
            for (int x = (int)lo; x <= (int)hi; x++)
                canvas_pixel(c, x, y);
        }
    }
    for (int i = 0; i < n; i++)
        canvas_line(c, p[i], p[(i + 1) % n]);
}

void canvas_thick(Canvas *c, Pt a, Pt b, double width)
{
    double dx = b.x - a.x, dy = b.y - a.y, len = hypot(dx, dy);
    if (len < 1e-9) {
        canvas_pixel(c, (int)floor(a.x), (int)floor(a.y));
        return;
    }
    double nx = -dy / len * width / 2, ny = dx / len * width / 2;
    Pt q[4] = {{a.x + nx, a.y + ny}, {b.x + nx, b.y + ny}, {b.x - nx, b.y - ny}, {a.x - nx, a.y - ny}};
    canvas_poly(c, q, 4);
}
