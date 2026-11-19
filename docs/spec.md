# Sakura & Bamboo screensaver: implementation spec

The scene is inspired by the cover of Tycho's album *Back to Mine: Tycho*
(https://tycho.bandcamp.com/album/back-to-mine-tycho).

This spec is for porting the screensaver to other languages. The **Python
implementation in `python/saver/` is normative**: every constant, curve,
colour and timing below comes from it, and where this text and the code
disagree, the code wins. Read it alongside this document. A port must look and
behave the same, but does **not** need to match Python pixel for pixel. Its
random streams will differ, so the plants grow slightly differently.

Screenshots of the reference: `shots/py-live.png`, `shots/py-burn.png`
(rendered by `bin/saver --png ...` at 200x56 cells).

## 1. What it does

A full-screen terminal animation. A pixel image is drawn at 2 pixels per
character cell (cols x rows*2) and shown with truecolour ANSI. Most cells are
half-blocks `▀`; bamboo cells are ASCII glyphs (the "hybrid" look). The show loops:

| phase | length | what happens |
|---|---|---|
| grow  | until reveal finishes (~4.8 s) | scene flashes in from the centre outwards |
| live  | `--live` s (24) | scene sways, petals fall |
| burn  | fire crosses in `--burn` s (9), then ash/flakes clear | burn to ash |
| black | 1.2 s | black; then the next palette, back to grow |

The scene clock never stops: plants keep swaying during grow and burn, and the
burn is applied on top of the live animation every frame.

## 2. Modules (one per Python file; keep the same split)

| Python | role | must provide |
|---|---|---|
| `palettes.py` | 3 palettes (ember, moon, dusk); only sun bands `s1..s7` and `line` differ | name → colour table |
| `scene.py` | scene tree, rasterising, glyph mask, falling petals | `new(w, h)`, `resize`, `set_palette`, `render(t, dt) -> (image, mask)` |
| `burn.py` | `Burn` and `Grow` per-pixel effects | `new(w, h, rng, …)`, `apply(image, t)`, `end`/`done` |
| `show.py` | phase machine, palette rotation, resize | `step(dt) -> (image, mask)`, `resize`, `seek(phase, at)` |
| `render.py` | image+mask → cells; cells → ANSI diff | `to_cells`, `Emitter.frame`, `Emitter.reset` |
| `main.py` | CLI, terminal setup, frame loop | |
| `preview.py` | still frame to an image file | (see §8) |

Image = `h x w` RGB bytes; mask = `h x w` booleans.

## 3. Scene (`scene.py`)

**Coordinates.** Geometry lives in a 1600x900 virtual space. To fit a
`W x H` pixel image, scale `s = max(W/1600, H/900)` (cover; edges crop),
offset `ox = (W - 1600 s)/2`, `oy = (H - 900 s)/2`.

**Build once at startup.** The scene is built once with a seeded PRNG (Python
seed 20261118; use the language's own seeded generator). The build makes a
tree of *sway nodes*:

- A node has a parent (or none), a pivot, an amplitude, a duration and a
  random phase. Its local transform is a rotation about the pivot by
  `amp * sin(pi * t / dur + phase)`. Its world matrix is parent·local, and the
  root parent is the virtual→pixel scale/offset matrix.
- Every shape belongs to a node. Shapes are stored in **build order**, and
  that is the draw order. Kinds:
  - `poly`: a filled polygon.
  - `stem`: a polyline whose width tapers linearly from w0 to w1 (virtual
    units) along its segments. Each segment is drawn with width
    `max(1, round(w * s))` pixels.
  - `line`: a 1-pixel polyline.
  - `dot`: a single pixel.

  Each shape also has a colour key.

Builders, all in Python with exact numbers: `_bamboo` (two culms; nodes made
while `BAMBOO_SWAY=1.6` is active get 1.6x amplitude), `_branch`, `_leaf` (a
two-tone leaf from `LEAF_BODY`/`LEAF_TIP`, sized up by `BOOST=1.35`),
`_cherry` (a cubic-Bézier bough), `_twig` (recursive to one level),
`_blossom` (5 `PETAL` polys, 5 `PETAL_TIP` polys, a centre dot; sized up by
`BOOST*1.1`; its position is recorded in `blossom_spots`). Port these
function by function, keeping the call order of random draws within each
function.

**Backdrop.** Rebuild only on resize or palette change. Start from black. Draw
a halo ring where `236 <= r < 430` from the sun centre (800, 450), with
`a = clamp(1 - (r-236)/194, 0, 1)`. A pixel is on when
`a > 0.15 && a > bayer4[y%4][x%4]`, and is coloured `0.30 * s3`. The sun is a
disc of radius 250, banded by virtual y (`SUN_BANDS`). Then for each of the
3 `RIDGES`, fill the polygon closed down to the bottom edge in black and draw
the ridge as a 1-pixel `line` polyline in colour `line`. Pixel centres
(x+0.5, y+0.5) are what get mapped back to virtual coordinates.

**Each frame.**
1. Copy the backdrop. Clear the mask.
2. Evaluate all node matrices for time `t` (parents come before children in
   build order). Transform every shape point to pixels.
3. Draw each shape into the image in its colour. Also draw it into the
   **mask**: shapes whose colour key is in `GLYPH_KEYS` (culm, node, leaf_*)
   write 1, every other shape writes 0, so a blossom in front of bamboo
   clears the mask under it.
4. Step and draw the falling petals into the image only (`FallingPetals`:
   48 petals with their own PRNG, wind, a fade-in, 1-2 px wide when near).

**Rasterising** (replaces PIL; no antialiasing):
- Polygon fill: a scanline fill of pixels whose centre is inside (even-odd
  rule), plus the polygon's edges drawn as 1-pixel lines so tiny polygons
  never vanish. PIL also draws the outline.
- 1-pixel line: Bresenham between the rounded endpoints.
- Thick line (`width > 1`): fill the quad of that width centred on the
  segment.
- `point` and petal pixels: the pixel at `floor(x), floor(y)`. Clip
  everything to the image.

## 4. Burn and grow (`burn.py`)

Both use the show's PRNG (Python seeds it from `--seed`/None; any seeded
generator will do).

**Grow.** `reveal[y][x] = d/dmax * 4.0 + rand*0.9`, where d is the distance
from the image centre in pixels. Then `age = t - reveal`. Pixels with
`age < 0` are black. While `0 <= age < 0.8`, mix toward flash colour
(255,235,200) by `k = (1 - age/0.8)^2`. `end = max(reveal) + 0.8`.

**Burn setup.**
- Pick 2 or 3 ignition points, with x in [0.1, 0.9]·w and y in [0.55, 1.0]·h.
- `dist` is the minimum Euclidean distance to them. Add
  `(noise7 - .5) * 0.22 * max(w,h)` and `(noise2 - .5) * 0.04 * max(w,h)`,
  where noiseN is value noise: a random grid every N pixels, bilinearly
  interpolated (`_value_noise`).
- Shift so the minimum is 0, then
  `ignite = dist/max * duration + rand*0.25`. Also keep `grain = rand` per pixel.
- `end = max(ignite) + FLAME_T + CHAR_T + ASH_T + 3`. `done` is true once
  `t > end`.

**Burn apply(t)**, by pixel with `age = t - ignite` (constants in burn.py):

| age | colour |
|---|---|
| (-0.6, 0) | mix toward HEAT (255,120,30) by `(1 + age/0.6) * 0.55` |
| [0, 0.75) | flame gradient at `u = age/0.75*0.9 + (rand-.5)*0.5`, using 5-stop `FLAME` |
| [0.75, 1.85) | char: `c = (age-0.75)/1.1`; with probability `0.10*(1-c)` the pixel is EMBER*(1-c), otherwise the pixel*0.22*(1-c) |
| [1.85, 3.45) | ash: grey `112*(1-(age-1.85)/1.6)*(0.65+0.35*grain)` tinted by ASH (1, .97, .92) |
| ≥ 3.45 | black |

The random draws in the flame and char rows are fresh every frame (flicker).

**Flakes.** These are particles, emitted for pixels whose threshold fell in
`(t_prev, t]`:
- **Ash.** At `ash_at = ignite + 1.85`, with probability 0.45:
  vx ~ N(2.5, 3), vy = -U(2, 9), life U(1.5, 4.0).
- **Sparks.** At `ignite`, with probability 0.06:
  vx ~ N(2, 4), vy = -U(6, 18), life U(0.6, 1.8).

Each frame, every flake moves as follows: age += dt;
`x += (vx + 3 sin(3 age + y)) dt`; `y += vy dt`. Drop it when its age reaches
its life or when y < -2. Draw it at the integer pixel only where its colour
sum is brighter than the pixel under it. With `l = 1 - age/life`, ash is
`150 l * ASH`. A spark is `(255 l, 140 l², 30 l³)`.

## 5. Show (`show.py`)

- Phases are `grow → live → burn → black`, timed as in §1.
- A cycle starts by setting the palette: `--palette` if given, otherwise
  ember, moon, dusk in rotation.
- The scene clock `T += dt` every step, and the phase time is `t = T - t0`.
- In black, the image and mask are all zero.
- On resize, resize the scene. If in grow or burn, restart grow, since their
  per-pixel state is size-specific.
- `seek(phase, at)`: step at 1/20 s from the start until `at` seconds into
  `phase`, or until a later phase is reached. This is for stills and tests.

## 6. Cells and ANSI (`render.py`)

**to_cells.** Cell (r,c) takes the top pixel from row 2r and the bottom pixel
from row 2r+1. If neither pixel is masked, the cell is `▀` (U+2580) with
fg = top and bg = bottom. Otherwise it is a glyph cell:
- fg is the mean of the masked pixel(s).
- bg is `fg*0.18` if both are masked, else the unmasked pixel `*0.45`.
- The glyph is `RAMP = " .:-=+*#%@"` indexed by
  `clamp(lum^0.55 * 9 + 0.5, 0, 9)`, where
  `lum = (0.2126 R + 0.7152 G + 0.0722 B)/255` of fg. Use a space if
  max(fg) < 12.
- The ink is brightened: `fg *= clamp(225/max(fg), 1, 2.4)`.

**Emitter.frame.**
- The output is wrapped in `ESC[?2026h … ESC[0m ESC[?2026l` (synchronized
  update).
- On the first frame or a size change, emit `ESC[2J` and draw every cell.
  Otherwise, only for each row with changes, move to the first changed column
  (`ESC[r;cH`, 1-based) and redraw up to the last changed column.
- Emit `ESC[38;2;r;g;bm` / `ESC[48;2;r;g;bm` only when the colour differs
  from the last one emitted in this frame.
- `reset()` forces a full redraw.
- Build the whole frame in one buffer and write it in as few `write` calls as
  possible.

## 7. Terminal and main loop (`main.py`)

- **Setup.** Put stdin in cbreak mode (no ICANON, no ECHO). Write
  `ESC[?1049h ESC[?25l ESC[?7l` (alt screen, hide cursor, no autowrap).
  **Always** restore on exit, including on SIGINT, SIGTERM and SIGHUP: write
  `ESC[0m ESC[?7h ESC[?25h ESC[?1049l` and restore termios.
- **Size.** Read it with TIOCGWINSZ. The pixel size is `cols x rows*2`. On
  SIGWINCH, set a flag, and on the next frame resize the show and reset the
  emitter.
- **Loop.**
  1. `dt = min(0.1, now - last)` from a monotonic clock.
  2. Step, to_cells, emit.
  3. Wait for the rest of the frame (`1/fps`) with select/poll on stdin.
     **Any input byte quits.**
  4. Quit after `--max-seconds` if it is > 0.

**CLI (same flags as Python, `--still` instead of `--png`):**

```
--fps N (24)  --live S (24)  --burn S (9)  --palette ember|moon|dusk
--max-seconds S (0 = forever)
--still FILE --phase grow|live|burn (live) --at S (5) --size COLSxROWS (200x56)
```

`--still` writes one frame headless (no terminal needed; show seeded with a
fixed seed) and exits.

## 8. Stills

Python rasterises cells with a font (`preview.py`). Ports write a simpler
still: the cell frame drawn as an image with each cell 8x16 pixels.
- Half-block cells are drawn exactly: top 8x8 in fg, bottom 8x8 in bg.
- A glyph cell is filled with bg plus a centred fg square whose side is
  proportional to its RAMP index (0 → none, 9 → full cell).

Format:
- **Go**: PNG via `image/png`.
- **C**: binary PPM (P6). No image libraries. Convert for viewing with
  `python3 -c "from PIL import Image,sys; ..."` or ImageMagick `magick`.

## 9. Acceptance

1. Builds and runs with no warnings (see the language notes).
2. Unit tests cover the same things as `python/tests/test_show.py`:
   - The cycle visits every phase and the palette rotates.
   - A live frame has half-block and glyph cells.
   - Burn ends black.
   - The emitter's second identical frame is only the sync wrapper, and a
     single changed cell gives one cursor move to it.
   - Resize during burn restarts grow.
3. **Looks right.** Use
   `SAVER=<binary> SHOTS="4 14 22" tools/shoot.sh shots/<lang>-term --live 8`.
   It runs your binary in a real Alacritty on a private X display (`xctl`;
   never touches the live desktop). The script passes `--max-seconds 60`.
   Compare the PNGs by eye with `shots/py-live.png` / `shots/py-burn.png`.
   Expect to see:
   - a banded sun with a dithered halo,
   - ridges,
   - glyph bamboo swaying,
   - half-block blossoms,
   - falling petals,
   - a fire front, then ash.
4. **Performance.** At 240x134 pixels, a frame (step + to_cells + emit) takes
   well under Python's ~8 ms. Report the measured figure.
5. **Robustness.** Ctrl-C, a key press, and SIGTERM all leave the terminal
   restored. The program survives resizing to tiny sizes (e.g. 10x4) and
   back.

## 10. Language notes

**C** (`c/`)
- C11, libc + libm only, POSIX/Linux.
- `Makefile` with these targets:
  - `make`: `cc -std=c11 -Wall -Wextra -Wpedantic -O2`, zero warnings.
  - `make test`: build and run the tests.
  - `make asan`: `-fsanitize=address,undefined`.
- **Idioms.**
  - One `.c`/`.h` pair per module.
  - Structs with `x_new`/`x_free` (or init/fini) pairs, and caller-visible
    sizes.
  - `static` for anything internal; const-correct; `<stdint.h>` types.
  - Check every allocation.
  - No mutable globals except `volatile sig_atomic_t` signal flags.
  - Your own small PRNG (e.g. splitmix64/xoshiro), including normal and
    uniform helpers.
- The ASan build of the tests is clean.

**Go** (`go/`)
- Go 1.27 via mise: run as `mise exec -- go …` (versions are pinned in the
  root `mise.toml`). Module `saver`.
- **Layout.**
  - `cmd/saver/main.go`
  - `internal/scene` (palettes may live here or in their own package)
  - `internal/burn`, `internal/show`, `internal/render`, `internal/term`
- **Dependencies.** Prefer the standard library. `golang.org/x/term` and
  `golang.org/x/sys/unix` are acceptable for termios and ioctl.
- **Idioms.**
  - `math/rand/v2` with explicit seeded sources, passed in (no global rand).
  - Return errors, don't panic.
  - `gofmt`, `go vet ./...` and `go test ./...` all clean.
  - Table-driven tests where natural.
  - Small types with methods. Interfaces only where they are earned.

**Zig** (`zig/`)
- Zig 0.17.1 via mise: run as `mise exec -- zig …` (root `mise.toml`).
- `build.zig` provides:
  - `zig build` (installs `zig-out/bin/saver`)
  - `zig build test`
  - `zig build -Doptimize=ReleaseFast`
- Standard library only. The still is a binary PPM, as in C.
- **Idioms.**
  - Explicit allocators: the GPA/DebugAllocator in `main`, with leaks checked
    on exit; `std.testing.allocator` in tests.
  - `defer`/`errdefer` for every resource.
  - Error unions; no `catch unreachable` on fallible I/O.
  - `std.Random.DefaultPrng` seeded and passed in.
  - `std.posix` for termios, ioctl, poll and signals.
  - Slices, not pointer arithmetic.
  - One file per module (`src/scene.zig`, `src/burn.zig`, …), with tests in
    the same files.
  - `zig fmt` clean.
- Zig's std API changes between releases. Check names against the installed
  std source (`mise exec -- zig env` shows `lib_dir`) rather
  than memory.

**Odin** (`odin/`)
- Odin dev-2026-11a via mise: run as `mise exec -- odin …` (root `mise.toml`).
- One package `saver` in `odin/src/`, split one file per module
  (`scene.odin`, `burn.odin`, …). Tests use `@(test)` procs and
  `core:testing`; they can live in the same files or in `odin/tests/`.
- A `Makefile` (or `build.sh`) provides:
  - build: `odin build src -out:saver -o:speed -vet -strict-style`
  - `test`: `odin test …`
- Only `core:` and `base:`; no `vendor:`. The still is a binary PPM, as in C.
- **Idioms.**
  - Explicit allocators via `context.allocator`, with a tracking allocator
    in debug builds and tests that reports leaks.
  - `defer` for cleanup.
  - Multiple return values with errors or `ok` bools.
  - `core:math/rand` with an explicit seeded generator passed in.
  - `core:sys/posix` (or `core:sys/linux`) for termios, ioctl, poll and
    signals.
  - Slices and `[dynamic]` arrays; structs with procs.
  - `-vet -strict-style` clean.
- Odin's `core` changes between dev releases. Check names against the
  installed source (`odin root` → `core/`) rather than memory.

## 11. Out of scope

- Mouse input.
- Omarchy integration (wrapper script, cursor hiding via hyprctl, focus
  loss). That comes later and is common to all ports.
- Other scenes.
