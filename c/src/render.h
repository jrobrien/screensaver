#ifndef SAVER_RENDER_H
#define SAVER_RENDER_H
#include <stddef.h>
#include <stdint.h>

#define HALF_BLOCK 0x2580u   /* upper half block */
#define RAMP " .:-=+*#%@"

/* A frame of terminal cells. */
typedef struct {
    int cols, rows;
    uint32_t *ch;    /* rows*cols code points */
    uint8_t *fg;     /* rows*cols*3 */
    uint8_t *bg;
} Cells;

Cells *cells_new(int cols, int rows);   /* NULL on allocation failure */
void cells_free(Cells *c);

/* Fold a (cols x rows*2) pixel image and glyph mask into cells. */
void to_cells(Cells *c, const uint8_t *img, const uint8_t *mask);

/* Turns successive cell frames into minimal ANSI updates (truecolour, synchronized). */
typedef struct {
    Cells *prev;
    char *buf;
    size_t len, cap;
} Emitter;

void emitter_init(Emitter *e);
void emitter_fini(Emitter *e);
void emitter_reset(Emitter *e);   /* force a full redraw on the next frame */

/* Build the update; on success out and n describe an internal buffer valid
 * until the next call. Returns 0, or -1 on out of memory. */
int emitter_frame(Emitter *e, const Cells *c, const char **out, size_t *n);

#endif
