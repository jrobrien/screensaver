package saver

import "base:runtime"
import "core:math"
import "core:unicode/utf8"

// Pixel buffer -> terminal cells -> ANSI.
//
// The buffer is rows*2 x cols pixels: two square-ish pixels per character
// cell. A cell is a half-block (top pixel = fg, bottom pixel = bg) unless
// either of its pixels is in the glyph mask; then it is an ASCII glyph chosen
// by brightness and tinted with the masked pixels' colour.

RAMP :: " .:-=+*#%@"
HALF :: '▀' // upper half block

Cell :: struct {
	ch:     rune,
	fg, bg: Rgb,
}

Cells :: struct {
	cols, rows: int,
	data:       []Cell,
}

cells_make :: proc(cols, rows: int, allocator := context.allocator) -> (c: Cells, err: runtime.Allocator_Error) {
	c.cols, c.rows = cols, rows
	c.data, err = make([]Cell, cols * rows, allocator)
	return
}

cells_destroy :: proc(c: ^Cells, allocator := context.allocator) {
	delete(c.data, allocator)
	c^ = {}
}

// Index into RAMP for a glyph cell: brightness picks the character.
ramp_index :: proc(fg: Vec3) -> int {
	lum := (0.2126 * fg.r + 0.7152 * fg.g + 0.0722 * fg.b) / 255
	return int(clamp(math.pow(lum, 0.55) * f32(len(RAMP) - 1) + 0.5, 0, f32(len(RAMP) - 1)))
}

// Glyph cell: fg = mean colour of the masked pixel(s), bg = the other pixel dimmed.
@(private = "file")
glyph_cell :: proc(top, bot: Rgb, mt, mb: bool) -> Cell {
	t, b := to_vec(top), to_vec(bot)
	fg, bg: Vec3
	switch {
	case mt && mb:
		fg = (t + b) / 2
		bg = fg * 0.18
	case mt:
		fg = t
		bg = b * 0.45
	case:
		fg = b
		bg = t * 0.45
	}
	peak := max(fg.r, fg.g, fg.b)
	ramp := RAMP
	ch := ' ' if peak < 12 else rune(ramp[ramp_index(fg)])
	fg *= clamp(225 / max(peak, 1), 1, 2.4) // brighten the ink so thin foliage stays vivid
	return Cell{ch, to_rgb(fg), to_rgb(bg)}
}

// Fill `cells` (rows = canvas height / 2, cols = canvas width) from the canvas.
to_cells :: proc(c: ^Canvas, cells: ^Cells) {
	for r in 0 ..< cells.rows {
		for col in 0 ..< cells.cols {
			ti := (2 * r) * c.w + col
			bi := ti + c.w
			mt, mb := c.mask[ti], c.mask[bi]
			cell: Cell
			if mt || mb {
				cell = glyph_cell(c.pix[ti], c.pix[bi], mt, mb)
			} else {
				cell = Cell{HALF, c.pix[ti], c.pix[bi]}
			}
			cells.data[r * cells.cols + col] = cell
		}
	}
}

// Turns successive cell frames into minimal ANSI updates (truecolour, synchronized).
Emitter :: struct {
	prev:       []Cell, // empty until the first frame
	cols, rows: int,
	buf:        [dynamic]byte,
}

emitter_destroy :: proc(e: ^Emitter) {
	delete(e.prev)
	delete(e.buf)
	e^ = {}
}

// Force the next frame to redraw everything.
emitter_reset :: proc(e: ^Emitter) {
	delete(e.prev)
	e.prev = nil
}

@(private = "file")
put_uint :: proc(buf: ^[dynamic]byte, n: int) {
	digits: [20]byte
	i := len(digits)
	v := n
	for {
		i -= 1
		digits[i] = byte('0' + v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	append(buf, ..digits[i:])
}

@(private = "file")
put_colour :: proc(buf: ^[dynamic]byte, base: int, c: Rgb) {
	append(buf, "\x1b[")
	put_uint(buf, base)
	append(buf, ";2;")
	put_uint(buf, int(c.r))
	append(buf, ';')
	put_uint(buf, int(c.g))
	append(buf, ';')
	put_uint(buf, int(c.b))
	append(buf, 'm')
}

// ANSI for this frame. The returned bytes live in the emitter's buffer and
// are valid until the next call.
emitter_frame :: proc(e: ^Emitter, cells: Cells) -> (out: []byte, err: runtime.Allocator_Error) {
	clear(&e.buf)
	append(&e.buf, "\x1b[?2026h")
	full := len(e.prev) == 0 || e.cols != cells.cols || e.rows != cells.rows
	if full {
		append(&e.buf, "\x1b[2J")
		delete(e.prev)
		e.prev = make([]Cell, len(cells.data)) or_return
		e.cols, e.rows = cells.cols, cells.rows
	}
	last_fg, last_bg: Maybe(Rgb)
	for r in 0 ..< cells.rows {
		row := cells.data[r * cells.cols:][:cells.cols]
		old := e.prev[r * cells.cols:][:cells.cols]
		first, last := -1, -1
		for c in 0 ..< cells.cols {
			if full || row[c] != old[c] {
				if first < 0 {
					first = c
				}
				last = c
			}
		}
		if first < 0 {
			continue
		}
		append(&e.buf, "\x1b[")
		put_uint(&e.buf, r + 1)
		append(&e.buf, ';')
		put_uint(&e.buf, first + 1)
		append(&e.buf, 'H')
		for cell in row[first:last + 1] { 	// one run per row: first to last change
			if last_fg != cell.fg {
				put_colour(&e.buf, 38, cell.fg)
				last_fg = cell.fg
			}
			if last_bg != cell.bg {
				put_colour(&e.buf, 48, cell.bg)
				last_bg = cell.bg
			}
			enc, n := utf8.encode_rune(cell.ch)
			append(&e.buf, ..enc[:n])
		}
		copy(old, row)
	}
	append(&e.buf, "\x1b[0m\x1b[?2026l")
	return e.buf[:], nil
}
