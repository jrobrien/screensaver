"""Reusable bits salvaged from the dropped coast scene (2026-11-18).

Nothing here is wired into a scene yet; they are for the next one.
"""
import math

import numpy as np

# 'v' sprites for a flapping bird, as pixel offsets (dx, dy); cycle through them
BIRD_FRAMES = (
    [(-2, -1), (-1, 0), (0, 1), (1, 0), (2, -1)],
    [(-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0)],
    [(-2, 1), (-1, 0), (0, -1), (1, 0), (2, 1)],
    [(-2, 0), (-1, 0), (0, 0), (1, 0), (2, 0)],
)


class Birds:
    """A few birds drifting across a w-pixel-wide sky, flapping at different rates."""

    def __init__(self, n=6, y_range=(10, 40), seed=3):
        r = np.random.default_rng(seed)
        self.b = [dict(x=r.uniform(0, 1), y=r.uniform(*y_range), v=r.uniform(.012, .03),
                       ph=r.uniform(0, 6.3), f=r.uniform(2.5, 4.0)) for _ in range(n)]

    def draw(self, draw, t, width, colour):
        """draw: a PIL ImageDraw. Positions are in pixels."""
        for b in self.b:
            x = ((b['x'] + b['v'] * t) % 1.1 - 0.05) * width
            y = b['y'] + 1.5 * math.sin(t * 0.6 + b['ph'])
            for dx, dy in BIRD_FRAMES[int(t * b['f'] + b['ph']) % 4]:
                draw.point((x + dx, y + dy), fill=colour)


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def dithered_bands(coord, colours, lo, hi, noise, spread=0.5):
    """Quantise coord in [lo, hi] into len(colours) flat bands, with `noise`
    (random in [0,1], same shape) dithering the seams. Returns (..., 3)."""
    k = ((coord - lo) / (hi - lo) * len(colours) + (noise - .5) * spread).astype(int)
    return np.array(colours, np.uint8)[np.clip(k, 0, len(colours) - 1)]


# Also worth remembering from coast.py (see git history if committed, else the notes):
# - water as a per-pixel numpy field: banded colour warped by sin(x,t), crest rows
#   that move with u**1.7 for perspective, foam from thresholded static noise.
# - scenes return (rgb, glyph_mask); the renderer decides per cell.
