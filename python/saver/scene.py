"""Sakura & Bamboo, drawn into a low-resolution pixel buffer.

A port of the SVG artifact. The geometry lives in the artifact's 1600x900
"virtual" coordinate space. It is built once as a tree of sway nodes, each
holding shapes; every frame the tree is evaluated into affine matrices, all
points are mapped to pixels in one numpy pass, and the shapes are drawn with
PIL (no antialiasing, so the result stays crisp and pixelated).

Alongside the colour image the scene draws a glyph mask: pixels of bamboo
(culm, nodes, leaves) that the renderer turns into ASCII glyphs.
"""
import math
import random
from collections import namedtuple

import numpy as np
from PIL import Image, ImageDraw

from . import palettes

VW, VH = 1600, 900
DEG = math.pi / 180

BOOST = 1.35          # leaves and blossoms drawn larger than the SVG's: tiny at pixel scale
BAMBOO_SWAY = 1.6     # bamboo sways more than the blossom branch

# The sun: a 250-radius disc at (800, 450) cut into bands, each (top y, colour key).
SUN_C, SUN_R = (800, 450), 250
SUN_BANDS = ((200, 's1'), (350, 's2'), (420, 's3'), (480, 's4'), (535, 's5'), (585, 's6'), (640, 's7'))
HALO_R0, HALO_R1 = 236, 430      # ordered-dither glow ring around the sun

RIDGES = (
    ((330, 770), (450, 700), (525, 742), (640, 610), (744, 750)),
    ((580, 790), (710, 700), (780, 748), (880, 655), (1000, 770), (1060, 742), (1190, 800)),
    ((240, 810), (370, 745), (460, 800), (560, 760), (660, 815)),
)

GLYPH_KEYS = frozenset({'culm', 'node', 'leaf_a', 'leaf_b', 'leaf_a_hi', 'leaf_b_hi'})

BAYER4 = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) + 0.5) / 16

PETAL = ((0, 0), (-7, -4), (-11, -12), (-9, -20), (-4, -23), (0, -20),
         (4, -23), (9, -20), (11, -12), (7, -4))
PETAL_TIP = ((-5, -16), (0, -14), (5, -16), (3, -22), (0, -20), (-3, -22))

# A sway node rotates its subtree about `pivot` by amp*sin(pi*t/dur + phase).
Node = namedtuple('Node', 'parent pivot amp dur phase')
# kind: 'poly' (filled), 'stem' (polyline, width tapering w0->w1), 'line' (1 px), 'dot'
Shape = namedtuple('Shape', 'kind start end colour widths')


def bez2(p0, p1, p2, t):
    u = 1 - t
    return (u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0],
            u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1])


def bez3(p0, p1, p2, p3, t):
    u = 1 - t
    a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
    return (a * p0[0] + b * p1[0] + c * p2[0] + d * p3[0],
            a * p0[1] + b * p1[1] + c * p2[1] + d * p3[1])


def sample(fn, n):
    """n+1 points of fn over t in [0, 1]."""
    return [fn(i / n) for i in range(n + 1)]


def angle_at(pts, i):
    """Tangent direction of a sampled curve at index i."""
    a = pts[max(0, i - 1)]
    b = pts[min(len(pts) - 1, i + 1)]
    return math.atan2(b[1] - a[1], b[0] - a[0])


def transform(pts, rot, scale, tx, ty):
    c, s = math.cos(rot) * scale, math.sin(rot) * scale
    return [(c * x - s * y + tx, s * x + c * y + ty) for x, y in pts]


def _leaf_outline():
    """Leaf (base at origin, tip at (74, 0)): a dark body and a light tip."""
    def edge(sign, t0, t1, n):
        pts = []
        for i in range(n + 1):
            t = t0 + (t1 - t0) * i / n
            u = 1 - t
            pts.append((2 * u * t * 24 + t * t * 74, sign * 2 * u * t * 11))
        return pts
    return edge(-1, 0, 1, 5) + edge(1, 1, 0, 5), edge(-1, 0.55, 1, 3) + edge(1, 1, 0.55, 3)


LEAF_BODY, LEAF_TIP = _leaf_outline()


class Sakura:
    names = palettes.NAMES

    def __init__(self, width, height, seed=20261118):
        self._rng = random.Random(seed)
        self._sway_k = 1.0
        self.nodes, self.shapes, self.blossom_spots = [], [], []
        self._pts, self._pt_node = [], []
        self._build()
        pts = np.array(self._pts)
        self._px, self._py = pts[:, 0], pts[:, 1]
        self._pn = np.array(self._pt_node)
        self.petals = FallingPetals(self.blossom_spots)
        self.resize(width, height)
        self.set_palette(self.names[0])

    # ---- building the tree ------------------------------------------------
    def _rr(self, a, b):
        return a + (b - a) * self._rng.random()

    def _node(self, parent, pivot, amp, dur):
        self.nodes.append(Node(parent, pivot, amp * self._sway_k * DEG, dur, self._rng.random() * math.tau))
        return len(self.nodes) - 1

    def _shape(self, node, kind, pts, colour, widths=None):
        start = len(self._pts)
        self._pts.extend(pts)
        self._pt_node.extend([node] * len(pts))
        self.shapes.append(Shape(kind, start, len(self._pts), colour, widths))

    def _leaf(self, parent, q, ang, s):
        ang = math.atan2(math.sin(ang) + 0.35, math.cos(ang))          # leaves droop a little
        n = self._node(parent, q, self._rr(2.5, 5.5), self._rr(3.5, 6.5))
        colour = 'leaf_a' if self._rng.random() < .5 else 'leaf_b'
        self._shape(n, 'poly', transform(LEAF_BODY, ang, s * BOOST, *q), colour)
        self._shape(n, 'poly', transform(LEAF_TIP, ang, s * BOOST, *q), colour + '_hi')

    def _branch(self, parent, p, ang, length, s):
        end = (p[0] + math.cos(ang) * length, p[1] + math.sin(ang) * length)
        ctrl = ((p[0] + end[0]) / 2, (p[1] + end[1]) / 2 + length * 0.12 + self._rr(-6, 6))
        pts = sample(lambda t: bez2(p, ctrl, end, t), 6)
        n = self._node(parent, p, self._rr(1.4, 2.6), self._rr(8, 12))
        self._shape(n, 'stem', pts, 'culm', (2.8 * s, 1.1 * s))
        for u, side in ((0.35, 1), (0.6, -1), (0.82, 1)):
            i = round(u * 6)
            self._leaf(n, pts[i], angle_at(pts, i) + side * self._rr(28, 50) * DEG, s * self._rr(0.8, 1.15))
        th = angle_at(pts, 6)
        for a in (-38, 0, 36):
            self._leaf(n, end, th + (a + self._rr(-6, 6)) * DEG, s * self._rr(0.9, 1.25))

    def _bamboo(self, p0, p1, p2, w0, w1, amp, dur, scale):
        N = 48
        n = self._node(None, p0, amp, dur)
        pts = sample(lambda t: bez2(p0, p1, p2, t), N)
        self._shape(n, 'stem', pts, 'culm', (w0, w1))
        side, t = 1, 0.05
        while t < 0.97:                                # nodes up the culm, branches above 30%
            i = round(t * N)
            p, th = pts[i], angle_at(pts, i)
            k = (w0 + (w1 - w0) * t) / 2 + 1.4
            nx, ny = -math.sin(th) * k, math.cos(th) * k
            self._shape(n, 'line', [(p[0] + nx, p[1] + ny), (p[0] - nx, p[1] - ny)], 'node')
            if t > 0.3 and self._rng.random() < 0.85:
                self._branch(n, p, th + side * self._rr(40, 64) * DEG,
                             self._rr(70, 130) * scale * (1.15 - 0.6 * t), scale)
                side = -side
            t += 0.075
        th = angle_at(pts, N)
        for a in (-30, 0, 28):
            self._leaf(n, pts[N], th + (a + self._rr(-5, 5)) * DEG, scale * self._rr(1.0, 1.3))

    def _blossom(self, parent, x, y, s):
        n = self._node(parent, (x, y), self._rr(2, 5), self._rr(5, 8))
        rot0 = self._rr(0, 360)
        s *= BOOST * 1.1
        for outline, colour in ((PETAL, 'pink'), (PETAL_TIP, 'pink_hi')):
            for k in range(5):
                self._shape(n, 'poly', transform(outline, (rot0 + 72 * k) * DEG, s, x, y), colour)
        self._shape(n, 'dot', [(x, y)], 'pink_dk')
        self.blossom_spots.append((x, y))

    def _twig(self, parent, p0, ang, length, w, level):
        end = (p0[0] + math.cos(ang) * length, p0[1] + math.sin(ang) * length)
        ctrl = ((p0[0] + end[0]) / 2 + self._rr(-10, 10), (p0[1] + end[1]) / 2 + length * 0.18)
        pts = sample(lambda t: bez2(p0, ctrl, end, t), 6)
        n = self._node(parent, p0, self._rr(1.2, 2.4), self._rr(8, 12))
        self._shape(n, 'stem', pts, 'bark', (w, w * 0.35))
        if level == 0:
            for _ in range(2 if self._rng.random() < 0.6 else 1):
                i = round(self._rr(0.35, 0.7) * 6)
                side = -1 if self._rng.random() < .5 else 1
                self._twig(n, pts[i], angle_at(pts, i) + side * self._rr(30, 55) * DEG,
                           length * self._rr(0.4, 0.6), w * 0.6, 1)
        for k in range(3 if level == 0 else 2):        # first blossom at the tip, the rest along it
            i = round((1 if k == 0 else self._rr(0.55, 0.95)) * 6)
            j = 0.3 if k == 0 else 1
            self._blossom(n, pts[i][0] + self._rr(-8, 8) * j, pts[i][1] + self._rr(-8, 8) * j, self._rr(0.6, 1.0))

    def _cherry(self):
        P0, P1, P2, P3 = (-80, 490), (110, 520), (250, 330), (620, 250)
        N = 28
        pts = sample(lambda t: bez3(P0, P1, P2, P3, t), N)
        n = self._node(None, P0, 0.6, 14)
        self._shape(n, 'stem', pts, 'bark', (15, 3.5))
        for i, t in enumerate((0.2, 0.32, 0.45, 0.58, 0.7, 0.8, 0.9)):
            idx = round(t * N)
            side = -1 if i % 2 else 1
            self._twig(n, pts[idx], angle_at(pts, idx) + side * self._rr(35, 60) * DEG,
                       self._rr(80, 140) * (1.1 - t * 0.5), 4.4 - t * 1.6, 0)
        self._twig(n, pts[N], angle_at(pts, N) + self._rr(-10, 10) * DEG, 70, 3, 0)

    def _build(self):
        self._sway_k = BAMBOO_SWAY
        self._bamboo((1400, 980), (1405, 620), (1300, 230), 6.5, 2.8, 1.1, 11, 0.85)
        self._bamboo((1250, 980), (1215, 520), (1035, 95), 9, 3.5, 0.9, 13, 1)
        self._sway_k = 1.0
        self._cherry()

    # ---- size and palette -------------------------------------------------
    def resize(self, width, height):
        """Fit the virtual space to width x height pixels, covering it ('slice')."""
        self.W, self.H = width, height
        self.s = max(width / VW, height / VH)
        self.ox = (width - VW * self.s) / 2
        self.oy = (height - VH * self.s) / 2
        self._base = None

    def set_palette(self, name):
        self.pal = palettes.get(name)
        self._colours = [self.pal[sh.colour] for sh in self.shapes]
        self._base = None

    def _make_base(self):
        """Static backdrop: dithered halo, banded sun, ridges."""
        W, H, s, pal = self.W, self.H, self.s, self.pal
        iy, ix = np.mgrid[0:H, 0:W]
        vx = (ix + 0.5 - self.ox) / s
        vy = (iy + 0.5 - self.oy) / s
        r = np.hypot(vx - SUN_C[0], vy - SUN_C[1])
        img = np.zeros((H, W, 3), np.uint8)
        a = np.clip(1 - (r - HALO_R0) / (HALO_R1 - HALO_R0), 0, 1)
        halo = (r >= HALO_R0) & (r < HALO_R1) & (a > 0.15) & (a > BAYER4[iy % 4, ix % 4])
        img[halo] = [int(c * 0.30) for c in pal['s3']]
        sun = r < SUN_R
        for k, (top, key) in enumerate(SUN_BANDS):
            bottom = SUN_BANDS[k + 1][0] if k + 1 < len(SUN_BANDS) else math.inf
            img[sun & (vy >= top) & (vy < bottom)] = pal[key]
        im = Image.fromarray(img)
        d = ImageDraw.Draw(im)
        for ridge in RIDGES:
            pts = [(x * s + self.ox, y * s + self.oy) for x, y in ridge]
            d.polygon(pts + [(pts[-1][0], H), (pts[0][0], H)], fill=(0, 0, 0))
            d.line(pts, fill=pal['line'], width=1)
        self._base = im

    # ---- per frame ---------------------------------------------------------
    def _world(self, t):
        """All shape points in pixel coordinates at time t."""
        # affine (a, b, c, d, e, f): x' = a*x + c*y + e, y' = b*x + d*y + f
        root = (self.s, 0.0, 0.0, self.s, self.ox, self.oy)
        mats = []
        for parent, (px, py), amp, dur, phase in self.nodes:
            th = amp * math.sin(math.pi * t / dur + phase)
            c, s = math.cos(th), math.sin(th)
            e, f = px - c * px + s * py, py - s * px - c * py      # rotation about the pivot
            P = mats[parent] if parent is not None else root
            mats.append((P[0] * c + P[2] * s, P[1] * c + P[3] * s,
                         -P[0] * s + P[2] * c, -P[1] * s + P[3] * c,
                         P[0] * e + P[2] * f + P[4], P[1] * e + P[3] * f + P[5]))
        a, b, c, d, e, f = np.array(mats)[self._pn].T
        X = a * self._px + c * self._py + e
        Y = b * self._px + d * self._py + f
        return X.tolist(), Y.tolist()

    def render(self, t, dt):
        """The scene at time t: ((H, W, 3) uint8 image, (H, W) bool glyph mask)."""
        if self._base is None:
            self._make_base()
        im = self._base.copy()
        mask = Image.new('L', im.size, 0)
        draws = (ImageDraw.Draw(im), ImageDraw.Draw(mask))
        X, Y = self._world(t)
        for sh, colour in zip(self.shapes, self._colours):
            pts = list(zip(X[sh.start:sh.end], Y[sh.start:sh.end]))
            glyph = 255 if sh.colour in GLYPH_KEYS else 0   # non-glyph shapes erase the mask they cover
            for d, fill in zip(draws, (colour, glyph)):
                if sh.kind == 'poly':
                    d.polygon(pts, fill=fill)
                elif sh.kind == 'stem':
                    n = len(pts) - 1
                    w0, w1 = sh.widths
                    for i in range(n):
                        w = max(1, round((w0 + (w1 - w0) * i / n) * self.s))
                        d.line(pts[i:i + 2], fill=fill, width=w)
                elif sh.kind == 'line':
                    d.line(pts, fill=fill, width=1)
                else:
                    d.point(pts[0], fill=fill)
        self.petals.step(dt, t)
        self.petals.draw(draws[0], self)
        return np.asarray(im), np.asarray(mask) > 0


class Petal:
    __slots__ = ('x', 'y', 'depth', 'vy', 'phase', 'flip', 'flip_rate', 'age')


class FallingPetals:
    """Petals drifting on the wind, mostly shed from the blossoms. Virtual coords."""

    def __init__(self, spots, n=48, seed=7):
        self._spots = spots
        self._rng = random.Random(seed)
        self.petals = [self._reset(Petal(), initial=True) for _ in range(n)]

    def _reset(self, p, initial=False):
        R = self._rng
        p.depth = R.uniform(0.25, 1)
        if initial:                                  # scattered and already faded in
            p.x, p.y, p.age = R.uniform(-100, 1700), R.uniform(-40, 940), 99.0
        elif self._spots and R.random() < 0.6:       # shed from a blossom
            sx, sy = R.choice(self._spots)
            p.x, p.y, p.age = sx + R.uniform(-10, 10), sy + R.uniform(-6, 10), 0.0
        else:                                        # from above the screen
            p.x, p.y, p.age = R.uniform(-120, 1500), -40.0, 0.0
        p.vy = 14 + p.depth * 34 + R.uniform(0, 8)
        p.phase = R.uniform(0, math.tau)
        p.flip = R.uniform(0, math.tau)
        p.flip_rate = R.uniform(0.8, 2.4)
        return p

    def step(self, dt, t):
        wind = 14 + 10 * math.sin(t * 0.13) + 5 * math.sin(t * 0.37)
        for p in self.petals:
            p.x += (wind * (0.5 + p.depth * 0.7) + math.sin(t * 0.7 + p.phase) * 16) * dt
            p.y += (p.vy + math.sin(t * 1.1 + p.phase * 2) * 6) * dt
            p.flip += p.flip_rate * dt
            p.age += dt
            if p.y > 950 or p.x > 1750:
                self._reset(p)

    def draw(self, d, scene):
        pal = scene.pal
        for p in self.petals:
            x, y = p.x * scene.s + scene.ox, p.y * scene.s + scene.oy
            fade = (0.35 + 0.65 * p.depth) * min(1.0, p.age / 1.2)
            base = pal['pink_hi'] if fade > 0.75 else pal['pink']
            k = 0.45 + 0.55 * min(1.0, fade * 1.2)
            colour = tuple(int(c * k) for c in base)
            if p.depth > 0.6:                        # near petals are 1-2 pixels wide as they flip
                wide = abs(math.cos(p.flip)) > 0.5
                d.rectangle([x, y, x + (1 if wide else 0), y], fill=colour)
            else:
                d.point((x, y), fill=colour)
