// Package render turns pixel buffers into terminal cells, and cells into ANSI.
package render

import (
	"math"

	"saver/internal/pix"
)

// Ramp maps brightness to glyphs, dark to light.
const Ramp = " .:-=+*#%@"

// Half is the upper half block.
const Half = '▀'

// Cells is a rows x cols grid of characters with foreground and background.
type Cells struct {
	Rows, Cols int
	Ch         []rune
	Fg, Bg     []pix.RGB
}

// NewCells allocates an empty grid.
func NewCells(rows, cols int) *Cells {
	n := rows * cols
	return &Cells{Rows: rows, Cols: cols, Ch: make([]rune, n), Fg: make([]pix.RGB, n), Bg: make([]pix.RGB, n)}
}

func (c *Cells) clone() *Cells {
	d := NewCells(c.Rows, c.Cols)
	copy(d.Ch, c.Ch)
	copy(d.Fg, c.Fg)
	copy(d.Bg, c.Bg)
	return d
}

type fvec [3]float64

func toF(c pix.RGB) fvec { return fvec{float64(c[0]), float64(c[1]), float64(c[2])} }

func toRGB(v fvec) pix.RGB {
	var c pix.RGB
	for i, x := range v {
		c[i] = uint8(math.Min(math.Max(x, 0), 255))
	}
	return c
}

// RampIndex returns the Ramp index for a foreground colour.
func rampIndex(fg fvec) int {
	lum := (0.2126*fg[0] + 0.7152*fg[1] + 0.0722*fg[2]) / 255
	i := int(math.Pow(lum, 0.55)*float64(len(Ramp)-1) + 0.5)
	return min(max(i, 0), len(Ramp)-1)
}

// glyphCell computes a glyph cell: fg is the mean of the masked pixels, bg
// the other pixel dimmed.
func glyphCell(top, bot pix.RGB, mt, mb bool) (ch rune, fg, bg pix.RGB) {
	t, b := toF(top), toF(bot)
	var f, g fvec
	switch {
	case mt && mb:
		for i := range f {
			f[i] = (t[i] + b[i]) / 2
			g[i] = f[i] * 0.18
		}
	case mt:
		f = t
		for i := range g {
			g[i] = b[i] * 0.45
		}
	default:
		f = b
		for i := range g {
			g[i] = t[i] * 0.45
		}
	}
	peak := math.Max(f[0], math.Max(f[1], f[2]))
	ch = ' '
	if peak >= 12 {
		ch = rune(Ramp[rampIndex(f)])
	}
	// Brighten the ink toward full value so thin foliage stays vivid.
	k := math.Min(math.Max(225/math.Max(peak, 1), 1), 2.4)
	for i := range f {
		f[i] *= k
	}
	return ch, toRGB(f), toRGB(g)
}

// ToCells converts a pixel buffer (two pixels per cell, rows*2 pixel rows)
// and its glyph mask into cells, reusing dst when it has the right size.
func ToCells(img *pix.Image, mask []bool, dst *Cells) *Cells {
	rows, cols := img.H/2, img.W
	if dst == nil || dst.Rows != rows || dst.Cols != cols {
		dst = NewCells(rows, cols)
	}
	for r := 0; r < rows; r++ {
		for c := 0; c < cols; c++ {
			ti, bi := (2*r)*cols+c, (2*r+1)*cols+c
			top, bot := img.At(c, 2*r), img.At(c, 2*r+1)
			i := r*cols + c
			if mt, mb := mask[ti], mask[bi]; mt || mb {
				dst.Ch[i], dst.Fg[i], dst.Bg[i] = glyphCell(top, bot, mt, mb)
			} else {
				dst.Ch[i], dst.Fg[i], dst.Bg[i] = Half, top, bot
			}
		}
	}
	return dst
}
