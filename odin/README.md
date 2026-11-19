# Sakura & Bamboo screensaver: Odin port

Port of the Python reference (`../python/saver/`) following `../docs/spec.md`.
Odin dev-2026-11a, `core:` and `base:` only.

## Build and run

    make            # odin build src -out:saver -o:speed -vet -strict-style
    make test       # odin test, leaks from the tracking allocator fail the run
    make debug      # -debug build; main reports leaks from a tracking allocator
    make clean

Odin is not on PATH here; the Makefile runs it as
`mise exec -- odin` (override with `ODIN=...`).

    ./saver                                  # full screen in this terminal, any key quits
    ./saver --live 6 --burn 6 --palette moon
    ./saver --still out.ppm --phase burn --at 4 --size 200x56   # headless PPM
    ./saver --bench 1000                     # time frames at 240x134 pixels

Flags: `--fps --live --burn --palette --max-seconds --still --phase --at
--size`, plus `--bench N`. Values go in a separate argument (`--live 8`).

## Layout (package `saver`, `src/`)

- `palettes.odin`: enum-indexed `Palette`, three sun palettes.
- `rng.odin`: `Rng`, a seeded `core:math/rand` generator passed by pointer.
- `raster.odin`: `Canvas` (image plus glyph mask), Bresenham, scanline polygon fill.
- `scene.odin`: sway-node tree, backdrop, per-frame render, falling petals.
- `burn.odin`: `Grow` and `Burn` per-pixel effects, ash and spark flakes.
- `show.odin`: phase machine, palette rotation, resize, `show_seek`.
- `render.odin`: `to_cells`, `Emitter` (ANSI diff, synchronized updates).
- `term.odin`: termios, TIOCGWINSZ, signals, poll on stdin.
- `still.odin`: PPM writer (8x16 pixels per cell).
- `main.odin`: CLI, frame loop, bench, leak report in debug builds.
- `show_test.odin`: tests (see below).

## Tests

Seven `@(test)` procs: the cycle visits every phase and rotates the palette;
a live frame has half-block and glyph cells; burn ends black; the emitter's
second identical frame is only the sync wrapper and one changed cell gives one
cursor move; resize during burn restarts grow; tiny sizes (1x2 up to 200x112)
do not crash; PPM size. `make test` passes
`-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true`, so any leak fails the run.

## Performance

Step + to_cells + emit at 240x134 pixels (240x67 cells), `-o:speed`, live
phase, no terminal write: about 0.44 ms per frame (about 24 KB of ANSI per
frame). Python is about 8 ms. Measured with `./saver --bench 1000`.

## Checked

- Screenshots via `tools/shoot.sh` (`shots/odin-term-*.png`) and stills
  (`shots/odin-still-*.png`) show the banded sun with dithered halo, ridges,
  glyph bamboo, half-block blossoms, falling petals, fire front then ash.
- Under a pty: a key press, SIGINT, SIGTERM and SIGHUP all exit 0 with the
  leave sequence written and termios (ICANON, ECHO) restored; repeated
  SIGWINCH down to 1x1, 3x2, 10x4 and back up does not crash. The same run
  against the debug build reports no leaks.

## Deviations and notes

- Random streams differ from Python (ChaCha8 via `core:math/rand`), as the
  spec allows. Scene seed is 20261118, petals 7, `--still` show seed 1.
- Polygon outline and 1-pixel lines round endpoints; PIL truncates, so edges
  can differ by a pixel from the Python shots.
- Cell frames are compared as whole cells, so a changed colour on an
  otherwise identical cell redraws it (same as Python).
- Signal flags are the only mutable globals (atomic, set from handlers).
- Still output is PPM only.
