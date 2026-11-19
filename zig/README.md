# Sakura & Bamboo screensaver: Zig port

Port of the Python reference (`../python/saver/`), following `../docs/spec.md`.
Zig 0.17.1, standard library only.

## Build and run

    mise exec -- zig build -Doptimize=ReleaseFast
    zig-out/bin/saver                       # any key quits
    zig-out/bin/saver --live 6 --burn 6 --palette dusk
    zig-out/bin/saver --still out.ppm --phase burn --at 4 --size 200x56
    zig-out/bin/saver --bench 1200 --size 240x67
    mise exec -- zig build test
    mise exec -- zig fmt --check src build.zig

Flags (same as Python, `--still` instead of `--png`, plus `--bench N`):

    --fps N  --live S  --burn S  --max-seconds S
    --palette NAME          (ember, moon or dusk; default is to rotate)
    --still FILE            (binary PPM, 8x16 pixels per cell)
    --phase P  --at S       (P is grow, live or burn)
    --size COLSxROWS        (for --still and --bench)
    --bench N               (time N frames of step + to_cells + emit)

## Layout

All in `src/`, tests in the same files (`main.zig` pulls them in).

| file | role |
|---|---|
| `palettes.zig` | the 3 palettes as comptime `EnumArray(Key, Rgb)` |
| `rng.zig` | small helpers over `std.Random.DefaultPrng` (uniform, range, normal) |
| `raster.zig` | `Frame` (RGB plus glyph mask), `Brush`, polygon fill, Bresenham, thick lines |
| `scene.zig` | scene builders, sway tree, backdrop, falling petals, `Scene.render` |
| `burn.zig` | `Burn` (fire front, flakes) and `Grow` |
| `show.zig` | phase machine, palette rotation, resize, `seek` |
| `render.zig` | `toCells`, `Emitter` (ANSI diff), `toPpm` |
| `term.zig` | cbreak mode, signal flags, size, poll |
| `main.zig` | CLI, frame loop, still, bench |

Allocation: `main` uses `std.heap.DebugAllocator` and checks for leaks on
exit; tests use `std.testing.allocator`. Frame, cell and emitter buffers are
reused, so the steady state allocates only when flakes grow the list.

## Performance

ReleaseFast, 240x134 pixels (240x67 cells), 1200 frames at dt 1/24 through a
full cycle (`--bench 1200 --size 240x67`, step + to_cells + emit, output not
written to a terminal):

| phase | ms per frame | step | to_cells | emit |
|---|---|---|---|---|
| grow | 0.48 | 0.22 | 0.07 | 0.19 |
| live | 0.28 | 0.14 | 0.09 | 0.05 |
| burn | 0.61 | 0.33 | 0.08 | 0.20 |

Mean 0.42 ms, worst frame 2.4 ms (Python is about 8 ms).

## Deviations and notes

- Arithmetic is f32 (the sway clock is f64). Random streams differ from
  Python as the spec allows, so the plants grow slightly differently.
- Thick stem segments are filled quads without round joins, so sharp bends
  can show tiny notches. Leaves look a little sparser than the Python shot.
- `--still` glyph cells are drawn as an fg square sized by ramp index (spec
  section 8), so bamboo looks like blocks rather than text.
- Extra flag `--bench N`. Not a terminal: exits with a message
  if stdin is not a tty (use `--still`).
- Signal and key exit were checked under `script` (a pty): INT, TERM and a
  key press each emitted the restore sequence and exited 0. Resizing to
  10x4 was tried via `stty`; a live SIGWINCH resize loop was covered only by
  unit tests (`Show.resize` to 10x8 and 1x2 and back), not by hand.
