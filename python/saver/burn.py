"""Burn-to-ash and its reverse, as per-pixel effects on the scene image.

Burn: a fire front crawls out from a few ignition points. Each pixel goes
  heat glow -> flame -> char -> grey ash -> black,
while ash flakes and sparks lift off and drift upward.
Grow: the scene flashes in, spreading out from the centre.
"""
import numpy as np

FLAME = np.array([(255, 244, 190), (255, 204, 70), (240, 120, 24), (178, 48, 12), (80, 18, 8)], np.float32)
HEAT = np.array([255, 120, 30], np.float32)
EMBER = np.array([190, 70, 16], np.float32)
ASH = np.array([1.0, 0.97, 0.92], np.float32)        # tint applied to grey levels
FLASH = np.array([255, 235, 200], np.float32)

HEAT_T = 0.6        # seconds of glow before the front arrives
FLAME_T = 0.75      # in flame
CHAR_T = 1.1        # smouldering
ASH_T = 1.6         # grey ash, then black


def _value_noise(rng, h, w, cell):
    """Smooth noise in [0, 1]: a random grid every `cell` pixels, bilinearly interpolated."""
    gh, gw = h // cell + 2, w // cell + 2
    g = rng.random((gh, gw)).astype(np.float32)
    ys, xs = np.linspace(0, gh - 1.001, h), np.linspace(0, gw - 1.001, w)
    y0, x0 = ys.astype(int), xs.astype(int)
    fy, fx = (ys - y0)[:, None], (xs - x0)[None, :]
    top = g[y0][:, x0] * (1 - fx) + g[y0][:, x0 + 1] * fx
    bot = g[y0 + 1][:, x0] * (1 - fx) + g[y0 + 1][:, x0 + 1] * fx
    return top * (1 - fy) + bot * fy


def _flame(u):
    """FLAME gradient at u in [0, 1] (array) -> (..., 3)."""
    u = np.clip(u, 0, 1) * (len(FLAME) - 1)
    i = np.minimum(u.astype(int), len(FLAME) - 2)
    f = (u - i)[..., None]
    return FLAME[i] * (1 - f) + FLAME[i + 1] * f


class Burn:
    def __init__(self, w, h, rng, duration):
        self.w, self.h, self.rng = w, h, rng
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        dist = np.full((h, w), np.inf, np.float32)
        for _ in range(rng.integers(2, 4)):          # ignition points, lower half of the screen
            sx, sy = rng.uniform(0.1, 0.9) * w, rng.uniform(0.55, 1.0) * h
            dist = np.minimum(dist, np.hypot(xx - sx, yy - sy))
        size = max(w, h)
        dist += (_value_noise(rng, h, w, 7) - .5) * 0.22 * size     # ragged front
        dist += (_value_noise(rng, h, w, 2) - .5) * 0.04 * size
        dist -= dist.min()
        self.ignite = dist / dist.max() * duration + rng.random((h, w)).astype(np.float32) * 0.25
        self.ash_at = self.ignite + FLAME_T + CHAR_T
        self.end = self.ignite.max() + FLAME_T + CHAR_T + ASH_T + 3.0   # + time for flakes to clear
        self.grain = rng.random((h, w)).astype(np.float32)
        self.t_prev = 0.0
        # flakes: one row each: x, y, vx, vy, age, life, is_spark
        self.flakes = np.zeros((0, 7), np.float32)

    @property
    def done(self):
        return self.t_prev > self.end

    def _spawn(self, mask, prob, vx_sd, vy_range, life_range, spark):
        ys, xs = np.nonzero(mask & (self.rng.random(mask.shape) < prob))
        n = len(ys)
        f = np.zeros((n, 7), np.float32)
        f[:, 0], f[:, 1] = xs, ys
        f[:, 2] = self.rng.normal(2.5 if not spark else 2, vx_sd, n)
        f[:, 3] = -self.rng.uniform(*vy_range, n)
        f[:, 5] = self.rng.uniform(*life_range, n)
        f[:, 6] = spark
        self.flakes = np.concatenate([self.flakes, f])

    def _move_and_draw_flakes(self, out, dt):
        f = self.flakes
        f[:, 4] += dt
        f[:, 0] += (f[:, 2] + np.sin(f[:, 4] * 3 + f[:, 1]) * 3) * dt
        f[:, 1] += f[:, 3] * dt
        f = self.flakes = f[(f[:, 4] < f[:, 5]) & (f[:, 1] > -2)]
        x, y = f[:, 0].astype(int), f[:, 1].astype(int)
        on = (x >= 0) & (x < self.w) & (y >= 0) & (y < self.h)
        f, x, y = f[on], x[on], y[on]
        life = (1 - f[:, 4] / f[:, 5])[:, None]
        ash = 150 * life * ASH
        spark = np.concatenate([255 * life, 140 * life ** 2, 30 * life ** 3], axis=1)
        colour = np.where(f[:, 6:7] == 1, spark, ash)
        under = out[y, x]
        out[y, x] = np.where(colour.sum(1, keepdims=True) > under.sum(1, keepdims=True), colour, under)

    def apply(self, img, t):
        """The burn at t seconds after ignition, applied to img."""
        dt, t0 = t - self.t_prev, self.t_prev
        self.t_prev = t
        out = img.astype(np.float32)
        age = t - self.ignite

        m = (age < 0) & (age > -HEAT_T)
        k = ((1 + age[m] / HEAT_T) * 0.55)[:, None]
        out[m] = out[m] * (1 - k) + HEAT * k

        m = (age >= 0) & (age < FLAME_T)
        u = age[m] / FLAME_T * 0.9 + (self.rng.random(m.sum()).astype(np.float32) - 0.5) * 0.5
        out[m] = _flame(u)

        m = (age >= FLAME_T) & (age < FLAME_T + CHAR_T)
        c = ((age[m] - FLAME_T) / CHAR_T)[:, None]
        ember = self.rng.random(c.shape) < 0.10 * (1 - c)
        out[m] = np.where(ember, EMBER * (1 - c), out[m] * 0.22 * (1 - c))

        a1 = FLAME_T + CHAR_T
        m = (age >= a1) & (age < a1 + ASH_T)
        grey = (112 * (1 - (age[m] - a1) / ASH_T) * (0.65 + 0.35 * self.grain[m]))[:, None]
        out[m] = grey * ASH
        out[age >= a1 + ASH_T] = 0

        self._spawn((self.ash_at > t0) & (self.ash_at <= t), 0.45, 3, (2, 9), (1.5, 4.0), 0)
        self._spawn((self.ignite > t0) & (self.ignite <= t), 0.06, 4, (6, 18), (0.6, 1.8), 1)
        self._move_and_draw_flakes(out, dt)
        return np.clip(out, 0, 255).astype(np.uint8)


class Grow:
    """Flash-in reveal radiating from the centre."""

    FLASH_T = 0.8

    def __init__(self, w, h, rng, duration=4.0):
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        d = np.hypot(xx - w / 2, yy - h / 2)
        self.reveal = d / d.max() * duration + rng.random((h, w)).astype(np.float32) * 0.9
        self.end = self.reveal.max() + self.FLASH_T

    def apply(self, img, t):
        age = t - self.reveal
        out = img.astype(np.float32)
        out[age < 0] = 0
        m = (age >= 0) & (age < self.FLASH_T)
        k = ((1 - age[m] / self.FLASH_T) ** 2)[:, None]
        out[m] = out[m] * (1 - k) + FLASH * k
        return np.clip(out, 0, 255).astype(np.uint8)
