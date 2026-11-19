#ifndef SAVER_RASTER_H
#define SAVER_RASTER_H
#include <stdint.h>

typedef struct {
    double x, y;
} Pt;

/* A drawing target: an RGB image and an optional 1-byte-per-pixel mask.
 * Everything drawn is written in `rgb` to the image and `mval` to the mask. */
typedef struct {
    uint8_t *img;
    uint8_t *mask;   /* may be NULL */
    int w, h;
    uint8_t rgb[3];
    uint8_t mval;
} Canvas;

void canvas_pixel(Canvas *c, int x, int y);
void canvas_line(Canvas *c, Pt a, Pt b);                  /* 1 px Bresenham */
void canvas_poly(Canvas *c, const Pt *p, int n);          /* even-odd fill + outline, n <= 64 */
void canvas_thick(Canvas *c, Pt a, Pt b, double width);   /* quad of `width` about a-b */

#endif
