#ifndef SAVER_STILL_H
#define SAVER_STILL_H
#include "render.h"

/* Write the cell frame as a binary PPM (P6), each cell 8x16 pixels.
 * Returns 0 on success, -1 on error. */
int still_write_ppm(const Cells *c, const char *path);

#endif
