package saver

import "base:runtime"
import "core:math"
import "core:slice"

// A pixel buffer plus the glyph mask drawn alongside it. No antialiasing.
Canvas :: struct {
	w, h: int,
	pix:  []Rgb,
	mask: []bool,
}

canvas_make :: proc(w, h: int, allocator := context.allocator) -> (c: Canvas, err: runtime.Allocator_Error) {
	c.w, c.h = w, h
	c.pix = make([]Rgb, w * h, allocator) or_return
	c.mask, err = make([]bool, w * h, allocator)
	if err != nil {
		delete(c.pix, allocator)
		c.pix = nil
	}
	return
}

canvas_destroy :: proc(c: ^Canvas, allocator := context.allocator) {
	delete(c.pix, allocator)
	delete(c.mask, allocator)
	c^ = {}
}

// Plot one pixel (and its mask bit), clipped to the canvas.
put :: #force_inline proc(c: ^Canvas, x, y: int, col: Rgb, glyph: bool) {
	if x < 0 || y < 0 || x >= c.w || y >= c.h {
		return
	}
	i := y * c.w + x
	c.pix[i] = col
	c.mask[i] = glyph
}

// Bresenham line between integer pixels.
line :: proc(c: ^Canvas, x0, y0, x1, y1: int, col: Rgb, glyph: bool) {
	x, y := x0, y0
	dx, dy := abs(x1 - x0), -abs(y1 - y0)
	sx := 1 if x0 < x1 else -1
	sy := 1 if y0 < y1 else -1
	err := dx + dy
	for {
		put(c, x, y, col, glyph)
		if x == x1 && y == y1 {
			return
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x += sx
		}
		if e2 <= dx {
			err += dx
			y += sy
		}
	}
}

@(private = "file")
round_i :: #force_inline proc(v: f64) -> int {
	return int(math.floor(v + 0.5))
}

// 1-pixel segment between float points (rounded).
line_f :: proc(c: ^Canvas, a, b: [2]f64, col: Rgb, glyph: bool) {
	line(c, round_i(a.x), round_i(a.y), round_i(b.x), round_i(b.y), col, glyph)
}

// Even-odd scanline fill of the pixels whose centre lies inside `pts`.
fill_scan :: proc(c: ^Canvas, pts: [][2]f64, col: Rgb, glyph: bool) {
	if len(pts) < 3 {
		return
	}
	ymin, ymax := pts[0].y, pts[0].y
	for p in pts {
		ymin = min(ymin, p.y)
		ymax = max(ymax, p.y)
	}
	y0 := max(0, int(math.ceil(ymin - 0.5)))
	y1 := min(c.h - 1, int(math.floor(ymax - 0.5)))
	xs: [64]f64
	for y in y0 ..= y1 {
		yc := f64(y) + 0.5
		n := 0
		prev := pts[len(pts) - 1]
		for p in pts {
			if (prev.y <= yc) != (p.y <= yc) && n < len(xs) {
				xs[n] = prev.x + (yc - prev.y) * (p.x - prev.x) / (p.y - prev.y)
				n += 1
			}
			prev = p
		}
		span := xs[:n]
		slice.sort(span)
		for i := 0; i + 1 < n; i += 2 {
			xa := max(0, int(math.ceil(span[i] - 0.5)))
			xb := min(c.w, int(math.ceil(span[i + 1] - 0.5)))
			for x in xa ..< xb {
				put(c, x, y, col, glyph)
			}
		}
	}
}

// Filled polygon; its edges are also drawn so tiny polygons never vanish.
fill_poly :: proc(c: ^Canvas, pts: [][2]f64, col: Rgb, glyph: bool) {
	fill_scan(c, pts, col, glyph)
	prev := pts[len(pts) - 1]
	for p in pts {
		line_f(c, prev, p, col, glyph)
		prev = p
	}
}

// A segment `width` pixels wide: the quad of that width centred on it.
thick_line :: proc(c: ^Canvas, a, b: [2]f64, width: int, col: Rgb, glyph: bool) {
	if width <= 1 {
		line_f(c, a, b, col, glyph)
		return
	}
	d := b - a
	length := math.sqrt(d.x * d.x + d.y * d.y)
	if length < 1e-9 {
		put(c, int(math.floor(a.x)), int(math.floor(a.y)), col, glyph)
		return
	}
	n := [2]f64{-d.y, d.x} * (f64(width) / 2 / length)
	quad := [4][2]f64{a + n, b + n, b - n, a - n}
	fill_scan(c, quad[:], col, glyph)
}
