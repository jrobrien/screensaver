# Sakura & Bamboo screensaver: Go port

Idiomatic Go port of the Python reference (`../python/saver`), following
`../docs/spec.md`. Standard library only (no x/term, no x/sys).

## Build and run

    mise exec -- go build -o saver ./cmd/saver
    ./saver                       # full screen in this terminal; any key quits
    ./saver --live 6 --burn 6 --palette moon
    ./saver --still out.png --phase burn --at 4 --size 200x56

Flags (defaults shown):

    --fps 24  --live 24  --burn 9  --palette ember, moon or dusk  --max-seconds 0
    --still FILE  --phase grow, live or burn  --at 5  --size 200x56

Test: `mise exec -- go test ./...`; benchmark:
`mise exec -- go test -run xxx -bench . -benchtime 250x ./internal/show`.

## Layout

- `cmd/saver`: flags, terminal loop, `--still`.
- `internal/pix`: RGB image type shared by the packages.
- `internal/scene`: palettes, scene tree builder (`build.go`), rasteriser
  (`raster.go`), backdrop and per-frame render, falling petals.
- `internal/burn`: `Burn` (with flakes) and `Grow`.
- `internal/show`: phase machine, palette rotation, resize, `Seek`.
- `internal/render`: image+mask to cells, ANSI `Emitter`, PNG still.
- `internal/term`: cbreak mode, alt screen, TIOCGWINSZ (via `syscall`).

All randomness uses `math/rand/v2` PCG sources passed in explicitly.

## Performance

Measured on an AMD Ryzen 7 8745HS, one frame = `Step` + `ToCells` +
`Emitter.Frame` at 240x134 pixels (240 cols x 67 rows):

| phase | time per frame |
|---|---|
| live | about 0.65 ms |
| burn | about 1.3 ms |

(Python reference: about 8 ms.) A handful of allocations per frame.

## Deviations and notes

- No random-stream match with Python (as the spec allows), so the plants
  grow differently. Draw order within each builder follows Python.
- Rasteriser is hand-written (scanline even-odd fill plus outline, Bresenham,
  quad for thick stems with a centre line to avoid seams).
- `--still` glyph cells: the foreground square's side is `ceil(8*idx/9)`
  pixels, so the largest glyph fills the cell width (8) but not its full
  8x16 height.
- Terminal handling uses `syscall` ioctls directly instead of x/term.
- Resize during Burn: Python restarts grow, and so does this port.
- Verified in a pty: SIGTERM, SIGINT (Ctrl-C), a key press, and a resize
  sequence (10x4, 1x1, 100x30) all exit 0 with the leave sequence written.
