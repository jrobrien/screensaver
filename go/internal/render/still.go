package render

import (
	"image"
	"image/color"
	"image/png"
	"io"
	"strings"
)

const (
	cellW, cellH = 8, 16
)

// WritePNG draws the cells as an image, each cell 8x16 pixels. Half-block
// cells are exact; a glyph cell is its background plus a centred square of
// foreground whose side grows with the glyph's Ramp index.
func WritePNG(w io.Writer, c *Cells) error {
	img := image.NewRGBA(image.Rect(0, 0, c.Cols*cellW, c.Rows*cellH))
	fill := func(x0, y0, x1, y1 int, col [3]uint8) {
		rgba := color.RGBA{col[0], col[1], col[2], 255}
		for y := y0; y < y1; y++ {
			for x := x0; x < x1; x++ {
				img.SetRGBA(x, y, rgba)
			}
		}
	}
	for r := 0; r < c.Rows; r++ {
		for col := 0; col < c.Cols; col++ {
			i := r*c.Cols + col
			x, y := col*cellW, r*cellH
			if c.Ch[i] == Half {
				fill(x, y, x+cellW, y+cellH/2, c.Fg[i])
				fill(x, y+cellH/2, x+cellW, y+cellH, c.Bg[i])
				continue
			}
			fill(x, y, x+cellW, y+cellH, c.Bg[i])
			if idx := strings.IndexRune(Ramp, c.Ch[i]); idx > 0 {
				side := (idx*cellW + len(Ramp) - 2) / (len(Ramp) - 1) // 9 -> 8: full width
				cx, cy := x+(cellW-side)/2, y+(cellH-side)/2
				fill(cx, cy, cx+side, cy+side, c.Fg[i])
			}
		}
	}
	return png.Encode(w, img)
}
