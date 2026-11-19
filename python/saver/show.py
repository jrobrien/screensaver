"""The show: grow -> live -> burn -> black, then again with the next palette."""
import numpy as np

from .burn import Burn, Grow
from .scene import Sakura

PHASES = ('grow', 'live', 'burn', 'black')
BLACK_T = 1.2


class Show:
    def __init__(self, w, h, live=24.0, burn=9.0, palette=None, seed=None):
        self.w, self.h = w, h
        self.live_t, self.burn_t = live, burn
        self.palette = palette                      # fixed palette, or None to rotate
        self.rng = np.random.default_rng(seed)
        self.scene = Sakura(w, h)
        self.cycle = 0
        self.T = 0.0                                # scene clock: the scene keeps swaying through every phase
        self._start_cycle()

    def _start_cycle(self):
        names = self.scene.names
        self.scene.set_palette(self.palette or names[self.cycle % len(names)])
        self.cycle += 1
        self._enter('grow')

    def _enter(self, phase):
        self.phase, self.t0 = phase, self.T
        self.fx = (Grow(self.w, self.h, self.rng) if phase == 'grow' else
                   Burn(self.w, self.h, self.rng, self.burn_t) if phase == 'burn' else None)

    def resize(self, w, h):
        self.w, self.h = w, h
        self.scene.resize(w, h)
        if self.phase in ('grow', 'burn'):          # their per-pixel state is size-specific
            self._enter('grow')

    def step(self, dt):
        """Advance dt seconds; return (image, glyph mask)."""
        self.T += dt
        t = self.T - self.t0
        img, mask = self.scene.render(self.T, dt)
        if self.phase == 'grow':
            img = self.fx.apply(img, t)
            if t > self.fx.end:
                self._enter('live')
        elif self.phase == 'live':
            if t > self.live_t:
                self._enter('burn')
        elif self.phase == 'burn':
            img = self.fx.apply(img, t)
            if self.fx.done:
                self._enter('black')
        else:
            img, mask = np.zeros_like(img), np.zeros_like(mask)
            if t > BLACK_T:
                self._start_cycle()
        return img, mask

    def seek(self, phase, at, fps=20):
        """Run from the start until `at` seconds into `phase` (for stills)."""
        target = PHASES.index(phase)
        while True:
            frame = self.step(1.0 / fps)
            here = PHASES.index(self.phase)
            if here > target or (here == target and self.T - self.t0 >= at):
                return frame
