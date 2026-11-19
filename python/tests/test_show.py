"""Smoke tests: the show runs through every phase and produces sane frames."""
import numpy as np
import pytest

from saver import render
from saver.show import PHASES, Show


def test_cycle_visits_every_phase_and_rotates_palette():
    show = Show(80, 48, live=0.5, burn=1.0, seed=0)
    first = show.scene.pal['s1']
    seen = set()
    for _ in range(20 * 60):
        img, mask = show.step(1 / 20)
        assert img.shape == (48, 80, 3) and img.dtype == np.uint8
        assert mask.shape == (48, 80) and mask.dtype == bool
        seen.add(show.phase)
        if show.cycle == 2:
            break
    assert seen == set(PHASES)
    assert show.scene.pal['s1'] != first


def test_live_frame_has_sun_bamboo_glyphs_and_blocks():
    show = Show(120, 70, seed=0)
    img, mask = show.seek('live', 1.0)
    assert img.any() and mask.any() and not mask.all()
    ch, fg, bg = render.to_cells(img, mask)
    assert ch.shape == (35, 120)
    assert (ch == render.HALF).any()                     # half-block cells
    assert np.isin(ch, render.RAMP[1:]).any()            # glyph cells


def test_burn_ends_black():
    show = Show(60, 40, live=0.1, burn=0.5, seed=0)
    img, _ = show.seek('burn', 1e9)                      # runs until the phase after burn
    assert show.phase == 'black' and not img.any()


def test_emitter_only_redraws_changes():
    em = render.Emitter()
    ch = np.full((2, 3), render.HALF, np.int32)
    fg = np.zeros((2, 3, 3), np.uint8)
    full = em.frame(ch, fg, fg)
    assert '\x1b[2J' in full
    assert em.frame(ch, fg, fg) == '\x1b[?2026h\x1b[0m\x1b[?2026l'
    fg2 = fg.copy(); fg2[1, 2] = 255
    assert '\x1b[2;3H' in em.frame(ch, fg2, fg)


def test_resize_restarts_size_dependent_phase():
    show = Show(60, 40, live=0.1, burn=2, seed=0)
    show.seek('burn', 0.2)
    show.resize(30, 20)
    assert show.phase == 'grow'
    img, _ = show.step(0.05)
    assert img.shape == (20, 30, 3)
