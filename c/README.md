# Sakura & Bamboo screensaver: C11 port

Port of the Python reference (`../python/saver/`) following `../docs/spec.md`.
C11, libc + libm only, POSIX/Linux.

## Build and run

    make          # builds ./saver (cc -std=c11 -Wall -Wextra -Wpedantic -O2)
    make test     # builds and runs tests/test_show.c (848 checks)
    make asan     # ASan+UBSan build of the tests and of the binary, runs both
    make bench    # per-frame timing at 240x134 pixels
    make clean

    ./saver                                   # full screen, any key quits
    ./saver --live 6 --burn 6 --palette moon
    ./saver --still out.ppm --phase burn --at 4 --size 200x56   # headless PPM
    SAVER=$PWD/c/saver SHOTS="4 14 22" tools/shoot.sh shots/c-term --live 8   # from the repo root

Flags (`--seed` is an extra, for the show PRNG):

    --fps N (24)   --live S (24)   --burn S (9)   --palette ember, moon or dusk
    --max-seconds S (0 = forever)  --seed N
    --still FILE   --phase grow, live or burn (live)   --at S (5)   --size COLSxROWS (200x56)

## Layout (`src/`, one .c/.h pair per module)

| file | role |
|---|---|
| `rng` | xoshiro256** + splitmix64 seeding; uniform, normal, int helpers |
| `palettes` | 3 palettes, colour keys, glyph-key test |
| `raster` | `Canvas` drawing: pixel, Bresenham line, even-odd polygon fill, thick segment |
| `scene` | sway-node tree, backdrop, per-frame rasterising, glyph mask, falling petals |
| `burn` | `Burn` and `Grow` per-pixel effects, flakes |
| `show` | phase machine, palette rotation, resize, `show_seek` |
| `render` | `to_cells`, `Emitter` (ANSI diff) |
| `still` | cells to 8x16-per-cell PPM |
| `main` | CLI, termios, signals, frame loop |

Tests are in `tests/test_show.c` (the five cases from `python/tests/test_show.py`
plus tiny-size/resize survival); `tests/bench.c` is the timing harness.

## Performance

`make bench` at 240x134 pixels (240x67 cells), 24 fps step, gcc -O2, ms per frame
(step + to_cells + emit; emit only builds the byte buffer, no tty write):

| phase | step | to_cells | emit | total | worst |
|---|---|---|---|---|---|
| grow | 0.29 | 0.06 | 0.18 | 0.54 | 0.70 |
| live | 0.20 | 0.06 | 0.04 | 0.31 | 0.41 |
| burn | 0.47 | 0.06 | 0.27 | 0.80 | 1.74 |

Python is about 8 ms.

## Verification done

- Zero warnings with gcc and clang at `-Wall -Wextra -Wpedantic -O2`.
- `make asan` clean (tests and a `--still` burn run).
- Under a pty (ASan build): a key press, SIGINT, SIGTERM and SIGHUP each exit 0
  with the restore sequence written last; resizing 100x30 -> 10x4 -> 1x1 ->
  160x40 -> 10x4 survives.
- `shots/c-term-{4,14,22}.png` (alacritty via tools/shoot.sh): grow flash,
  live scene, burn front and ash. Stills: `shots/c-still-{live,burn,grow}.png`.

## Deviations and notes

- The random streams differ from Python (own PRNG), so the bamboo and branch
  leaves are laid out a little differently, as the spec allows.
- `--still` PPM glyph cells: a centred box scaled by RAMP index in both
  dimensions (8x16 box at index 9) rather than a strict square.
- Wide stem segments are a filled quad plus 1 px outline; there are no round
  joins, so very sharp bends can show a hairline notch.
- Float32 is used for the per-pixel burn/grow state; scene geometry is double.
- Terminal size below 1x1 is clamped to 1; pixel height is `rows*2`.
- If stdin reaches EOF/hangup the program quits like on a key press.
