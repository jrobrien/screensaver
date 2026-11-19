package scene

import (
	"math"
	"sort"

	"saver/internal/pix"
)

// surface is the target of the rasteriser: an image and, optionally, a
// glyph mask written alongside it. Nothing is antialiased.
type surface struct {
	w, h  int
	pix   []uint8
	mask  []bool // nil: image only
	col   pix.RGB
	glyph bool // value written to the mask
	xs    []float64
}

func newSurface(img *pix.Image, mask []bool) *surface {
	return &surface{w: img.W, h: img.H, pix: img.Pix, mask: mask}
}

func (s *surface) ink(c pix.RGB, glyph bool) { s.col, s.glyph = c, glyph }

func (s *surface) set(x, y int) {
	if uint(x) >= uint(s.w) || uint(y) >= uint(s.h) {
		return
	}
	i := y*s.w + x
	s.pix[3*i], s.pix[3*i+1], s.pix[3*i+2] = s.col[0], s.col[1], s.col[2]
	if s.mask != nil {
		s.mask[i] = s.glyph
	}
}

// span fills x0..x1 inclusive on row y.
func (s *surface) span(y, x0, x1 int) {
	if uint(y) >= uint(s.h) {
		return
	}
	x0, x1 = max(x0, 0), min(x1, s.w-1)
	for x := x0; x <= x1; x++ {
		s.set(x, y)
	}
}

func rnd(v float64) int { return int(math.Floor(v + 0.5)) }

// line draws a 1-pixel Bresenham line between the rounded endpoints.
func (s *surface) line(x0f, y0f, x1f, y1f float64) {
	x0, y0, x1, y1 := rnd(x0f), rnd(y0f), rnd(x1f), rnd(y1f)
	dx, dy := abs(x1-x0), -abs(y1-y0)
	sx, sy := 1, 1
	if x0 > x1 {
		sx = -1
	}
	if y0 > y1 {
		sy = -1
	}
	err := dx + dy
	for {
		s.set(x0, y0)
		if x0 == x1 && y0 == y1 {
			return
		}
		e2 := 2 * err
		if e2 >= dy {
			err += dy
			x0 += sx
		}
		if e2 <= dx {
			err += dx
			y0 += sy
		}
	}
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}

// polyline draws connected 1-pixel lines.
func (s *surface) polyline(xs, ys []float64) {
	for i := 0; i+1 < len(xs); i++ {
		s.line(xs[i], ys[i], xs[i+1], ys[i+1])
	}
}

// fill scanline-fills the polygon (even-odd, pixel centres).
func (s *surface) fill(xs, ys []float64) {
	n := len(xs)
	if n == 0 {
		return
	}
	lo, hi := ys[0], ys[0]
	for _, y := range ys {
		lo, hi = math.Min(lo, y), math.Max(hi, y)
	}
	y0 := max(int(math.Floor(lo-0.5)), 0)
	y1 := min(int(math.Ceil(hi+0.5)), s.h-1)
	for y := y0; y <= y1; y++ {
		yc := float64(y) + 0.5
		s.xs = s.xs[:0]
		for i, j := 0, n-1; i < n; j, i = i, i+1 {
			if (ys[i] <= yc) != (ys[j] <= yc) {
				s.xs = append(s.xs, xs[i]+(yc-ys[i])*(xs[j]-xs[i])/(ys[j]-ys[i]))
			}
		}
		sort.Float64s(s.xs)
		for k := 0; k+1 < len(s.xs); k += 2 {
			a := int(math.Ceil(s.xs[k] - 0.5))
			b := int(math.Ceil(s.xs[k+1]-0.5)) - 1
			s.span(y, a, b)
		}
	}
}

// polygon fills the polygon and draws its outline, so tiny ones survive.
func (s *surface) polygon(xs, ys []float64) {
	s.fill(xs, ys)
	n := len(xs)
	for i := range n {
		j := (i + 1) % n
		s.line(xs[i], ys[i], xs[j], ys[j])
	}
}

// thickLine draws a segment w pixels wide by filling its quad.
func (s *surface) thickLine(x0, y0, x1, y1, w float64) {
	dx, dy := x1-x0, y1-y0
	l := math.Hypot(dx, dy)
	if l == 0 {
		s.set(int(math.Floor(x0)), int(math.Floor(y0)))
		return
	}
	nx, ny := -dy/l*w/2, dx/l*w/2
	s.fill([]float64{x0 + nx, x1 + nx, x1 - nx, x0 - nx}, []float64{y0 + ny, y1 + ny, y1 - ny, y0 - ny})
	s.line(x0, y0, x1, y1) // the quads of neighbouring segments can leave seams
}
