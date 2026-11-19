"""Colour palettes, taken from the Sakura & Bamboo artifact.

Each palette changes the sun's seven bands and the ridge line; every other
colour is shared.
"""

SUN = {
    'ember': (('#9e1b1b', '#bf3418', '#d4501a', '#e26a24', '#ea8640', '#ee9f66', '#eeb0a0'), '#f3e9dd'),
    'moon':  (('#e9f0f6', '#d3e0ec', '#bccfe1', '#a5bdd5', '#8da9c6', '#7694b5', '#5f7fa3'), '#e6edf3'),
    'dusk':  (('#3c0f22', '#4d152b', '#5e1b33', '#70223a', '#822a42', '#94344b', '#a63f55'), '#d8c8cf'),
}

COMMON = {
    'culm': '#d9c35c', 'node': '#9b8433', 'bark': '#8a5a48',
    'leaf_a': '#2c7a3a', 'leaf_a_hi': '#7ed06c',
    'leaf_b': '#3f9142', 'leaf_b_hi': '#b0e17a',
    'pink': '#f4a9c4', 'pink_hi': '#fde6ee', 'pink_dk': '#c43a68',
}

NAMES = tuple(SUN)


def rgb(hexstr):
    h = hexstr.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))


def get(name):
    """Palette `name` as {key: (r, g, b)}; sun bands are keys s1..s7."""
    bands, line = SUN[name]
    pal = {k: rgb(v) for k, v in COMMON.items()}
    pal.update({'s%d' % (i + 1): rgb(b) for i, b in enumerate(bands)})
    pal['line'] = rgb(line)
    return pal
