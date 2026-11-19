"""Pixel buffer -> terminal cells -> ANSI.

The buffer is (rows*2, cols, 3): two square-ish pixels per character cell.
A cell is a half-block (top pixel = fg, bottom pixel = bg) unless either of
its pixels is in the glyph mask; then it is an ASCII glyph chosen by
brightness and tinted with the masked pixels' colour.
"""
import numpy as np

RAMP = np.array([ord(c) for c in " .:-=+*#%@"], np.int32)
HALF = ord('▀')   # upper half block


def _glyphs(top, bot, mt, mb):
    """Glyph cells: fg = mean colour of the masked pixel(s), bg = the other pixel dimmed."""
    top, bot = top.astype(np.float32), bot.astype(np.float32)
    mt3, mb3 = mt[..., None], mb[..., None]
    fg = (top * mt3 + bot * mb3) / np.maximum(mt3.astype(np.float32) + mb3, 1)
    bg = np.where(mt3 & mb3, fg * 0.18,
                  np.where(mt3, bot * 0.45, top * 0.45))
    lum = (fg @ np.array([0.2126, 0.7152, 0.0722], np.float32)) / 255.0
    idx = np.clip((lum ** 0.55) * (len(RAMP) - 1) + 0.5, 0, len(RAMP) - 1).astype(int)
    peak = fg.max(axis=2)
    ch = np.where(peak < 12, ord(' '), RAMP[idx])
    # brighten the ink toward full value so thin foliage stays vivid
    fg = fg * np.clip(225 / np.maximum(peak, 1), 1, 2.4)[..., None]
    return ch, np.clip(fg, 0, 255).astype(np.uint8), bg.astype(np.uint8)


def to_cells(buf, mask):
    """(codepoints (rows, cols) int32, fg (rows, cols, 3) uint8, bg (rows, cols, 3) uint8)."""
    top, bot = buf[0::2], buf[1::2]
    mt, mb = mask[0::2], mask[1::2]
    glyph = mt | mb
    gch, gfg, gbg = _glyphs(top, bot, mt, mb)
    g3 = glyph[..., None]
    return np.where(glyph, gch, HALF), np.where(g3, gfg, top), np.where(g3, gbg, bot)


class Emitter:
    """Turns successive cell frames into minimal ANSI updates (truecolour, synchronized)."""

    def __init__(self):
        self.prev = None

    def reset(self):
        self.prev = None

    def frame(self, ch, fg, bg):
        out = ['\x1b[?2026h']
        if self.prev is None or self.prev[0].shape != ch.shape:
            changed = np.ones(ch.shape, bool)
            out.append('\x1b[2J')
        else:
            pc, pf, pb = self.prev
            changed = (pc != ch) | (pf != fg).any(2) | (pb != bg).any(2)
        self.prev = (ch.copy(), fg.copy(), bg.copy())
        last_fg = last_bg = None
        for r in np.flatnonzero(changed.any(axis=1)):
            cols = np.flatnonzero(changed[r])
            a, b = cols[0], cols[-1] + 1             # one run per row: first to last change
            out.append('\x1b[%d;%dH' % (r + 1, a + 1))
            for c, f, g in zip(ch[r, a:b].tolist(), fg[r, a:b].tolist(), bg[r, a:b].tolist()):
                if f != last_fg:
                    out.append('\x1b[38;2;%d;%d;%dm' % tuple(f))
                    last_fg = f
                if g != last_bg:
                    out.append('\x1b[48;2;%d;%d;%dm' % tuple(g))
                    last_bg = g
                out.append(chr(c))
        out.append('\x1b[0m\x1b[?2026l')
        return ''.join(out)
