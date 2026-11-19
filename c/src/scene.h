#ifndef SAVER_SCENE_H
#define SAVER_SCENE_H
#include <stdint.h>

#include "palettes.h"

/* Sakura & Bamboo: a tree of sway nodes rasterised into an RGB buffer, plus
 * a glyph mask marking bamboo pixels. */
typedef struct Scene Scene;

Scene *scene_new(int w, int h);                 /* NULL on allocation failure */
void scene_free(Scene *s);
int scene_resize(Scene *s, int w, int h);       /* 0 ok, -1 out of memory */
void scene_set_palette(Scene *s, int index);
const Palette *scene_palette(const Scene *s);

/* Draw the scene at time t into img (w*h*3 bytes) and mask (w*h bytes). */
void scene_render(Scene *s, double t, double dt, uint8_t *img, uint8_t *mask);

#endif
