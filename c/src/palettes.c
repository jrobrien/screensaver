#include "palettes.h"

#include <string.h>

typedef struct {
    const char *name;
    uint32_t bands[7];
    uint32_t line;
} SunPalette;

static const SunPalette SUN[PALETTE_COUNT] = {
    {"ember", {0x9e1b1b, 0xbf3418, 0xd4501a, 0xe26a24, 0xea8640, 0xee9f66, 0xeeb0a0}, 0xf3e9dd},
    {"moon",  {0xe9f0f6, 0xd3e0ec, 0xbccfe1, 0xa5bdd5, 0x8da9c6, 0x7694b5, 0x5f7fa3}, 0xe6edf3},
    {"dusk",  {0x3c0f22, 0x4d152b, 0x5e1b33, 0x70223a, 0x822a42, 0x94344b, 0xa63f55}, 0xd8c8cf},
};

static const struct {
    int key;
    uint32_t rgb;
} COMMON[] = {
    {K_CULM, 0xd9c35c},     {K_NODE, 0x9b8433},      {K_BARK, 0x8a5a48},
    {K_LEAF_A, 0x2c7a3a},   {K_LEAF_A_HI, 0x7ed06c},
    {K_LEAF_B, 0x3f9142},   {K_LEAF_B_HI, 0xb0e17a},
    {K_PINK, 0xf4a9c4},     {K_PINK_HI, 0xfde6ee},   {K_PINK_DK, 0xc43a68},
};

static void set(Palette *p, int key, uint32_t rgb)
{
    p->c[key][0] = (uint8_t)(rgb >> 16);
    p->c[key][1] = (uint8_t)(rgb >> 8);
    p->c[key][2] = (uint8_t)rgb;
}

const char *palette_name(int index)
{
    return SUN[index % PALETTE_COUNT].name;
}

int palette_find(const char *name)
{
    for (int i = 0; i < PALETTE_COUNT; i++)
        if (strcmp(name, SUN[i].name) == 0)
            return i;
    return -1;
}

void palette_get(int index, Palette *out)
{
    const SunPalette *sp = &SUN[index % PALETTE_COUNT];
    for (size_t i = 0; i < sizeof COMMON / sizeof COMMON[0]; i++)
        set(out, COMMON[i].key, COMMON[i].rgb);
    for (int i = 0; i < 7; i++)
        set(out, K_S1 + i, sp->bands[i]);
    set(out, K_LINE, sp->line);
}

int key_is_glyph(int key)
{
    return key == K_CULM || key == K_NODE || (key >= K_LEAF_A && key <= K_LEAF_B_HI);
}
